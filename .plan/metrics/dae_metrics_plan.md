# Plan: Add `/metrics` HTTP Endpoint with Prometheus to dae

## Context

dae is a Go eBPF-based transparent proxy daemon with **no existing metrics/observability infrastructure** beyond optional pprof and logrus logging. The codebase already tracks rich internal state (dialer latencies, alive status, DNS cache, connection counts) but none of it is exposed via a metrics interface. This plan adds a `/metrics` HTTP endpoint using the Prometheus client library, designed for extensibility. Reference: mosDNS metrics patterns (`.plan/mosDNS_metrics.txt`).

### Code Base

**Development target: `dae/main` + PR#936**. PR#936 ([feat(control): improve DNS fallback reliability and harden connection lifecycle](https://github.com/daeuniverse/dae/pull/936)) is OPEN and MERGEABLE, about to be merged. It introduces significant DNS infrastructure that the metrics DNS gauges depend on (`concurrencyLimiter`, `cachedDnsForwarder` with `inFlight`, `dnsForwarderCache` as `sync.Map`). The effective code base is represented by the `eval/pr936-base` branch (verified at commit `de65f12`).

**Branch strategy**: Create the metrics feature branch on top of PR#936's head. Once PR#936 merges into `dae/main`, rebase the metrics branch onto `dae/main`. See [Git Workflow](#git-workflow-upstream-pr) for details.

Key data structures verified on `eval/pr936-base` (`dae/main` + PR#936):

| Structure | Location | Type |
|-----------|----------|------|
| `DnsController.concurrencyLimiter` | `control/dns_control.go:86` | `chan struct{}` (capacity default 16384; 0 = no limit) |
| `DnsController.dnsCache` | `control/dns_control.go` | `map[string]*DnsCache` + `dnsCacheMu sync.Mutex` |
| `DnsController.dnsForwarderCache` | `control/dns_control.go:106` | `sync.Map` (key: `dnsForwarderKey`, value: `*cachedDnsForwarder`) |
| `cachedDnsForwarder.inFlight` | `control/dns_control.go:782` | `atomic.Int32` (per-forwarder in-flight counter) |
| `ControlPlane.inConnections` | `control/control_plane.go:57` | `sync.Map` |
| `UdpEndpointPool.pool` | `control/udp_endpoint_pool.go:75` | `sync.Map` |
| `UdpTaskPool` (queues) | `control/udp_task_pool.go:42` | struct with internal map |
| `collection` (Dialer) | `component/outbound/dialer/connectivity_check.go:56` | plain struct, protected externally by `collectionFineMu` |
| `LatenciesN` | `component/outbound/dialer/latencies_n.go` | has internal `sync.Mutex`; `LastLatency()` and `AvgLatency()` are thread-safe |

> **Rebase note for PR#968 base**: PR#936's limiter/cache-forwarder model did not land upstream. On the rebased branch, DNS concurrency is synthesized as a saturation gauge around `HandleWithResponseWriter_`, per-upstream in-flight is tracked on the metrics snapshot, `dae_dns_concurrency_limit` is removed until a real limiter exists, and cache misses are derived in PromQL from `sum(rate(dae_dns_upstream_query_total[…]))`.

## Design Decisions

### 1. Endpoint Configuration: Full `Endpoint` section in Global

Replace the simple `HttpPort` idea with a comprehensive endpoint configuration block inside `config.Global`:

```dae
global {
    # ... existing fields ...

    # Endpoint configuration for metrics and diagnostics
    endpoint_listen_address = "0.0.0.0:5556"

    # Basic authentication (empty = disabled)
    endpoint_username = ""
    endpoint_password = ""

    # TLS (empty = plain HTTP)
    endpoint_tls_certificate = ""
    endpoint_tls_key = ""

    # Prometheus metrics
    endpoint_prometheus_enabled = true
    endpoint_prometheus_path = "/metrics"
}
```

In Go config struct:
```go
type Global struct {
    // ... existing fields ...

    // Endpoint (metrics + diagnostics)
    EndpointListenAddress     string `mapstructure:"endpoint_listen_address" default:""`
    EndpointUsername           string `mapstructure:"endpoint_username" default:""`
    EndpointPassword           string `mapstructure:"endpoint_password" default:""`
    EndpointTlsCertificate    string `mapstructure:"endpoint_tls_certificate" default:""`
    EndpointTlsKey            string `mapstructure:"endpoint_tls_key" default:""`
    EndpointPrometheusEnabled bool   `mapstructure:"endpoint_prometheus_enabled" default:"false"`
    EndpointPrometheusPath    string `mapstructure:"endpoint_prometheus_path" default:"/metrics"`
}
```

**Security features:**
- **Basic Auth**: Middleware wraps all handlers. If username+password set, reject unauthenticated requests with 401.
- **TLS**: If cert+key provided, use `httpServer.ListenAndServeTLS()` instead of `ListenAndServe()`.
- **TLS file permission policy**:
  - `endpoint_tls_certificate` must be `0640` or `0644`.
  - `endpoint_tls_key` must be `0600` (private key stricter than config file).
  - Validation is executed before initial endpoint startup and before applying reload config.
- **Default off**: `EndpointListenAddress` defaults to `""` (disabled). Must be explicitly configured.
- **Backward compat**: If `PprofPort != 0` and no endpoint configured, serve pprof on legacy port with deprecation warning.

**Permission check implementation notes:**
- Extract file permission checks into common helpers (shared by config include/subscription and metrics endpoint TLS checks).
- Keep existing config/subscription rule semantics (`not too open`: group not writable + others inaccessible).
- Add explicit mode whitelist checks for endpoint TLS files (cert/key different policy).

### 2. Custom Prometheus Registry (not global)

Use `prometheus.NewRegistry()` — avoids polluting global registry, clean testability.

### 3. Two-Phase Implementation Strategy

- **Phase 1 (gauges)**: Lazy `prometheus.Collector` — reads existing data at scrape time. Zero hot-path changes.
- **Phase 2 (counters/histograms)**: `atomic.Int64` counters + histogram observations in hot paths.

### 4. Reload Handling: Full Metrics Refresh on SIGUSR1

On reload (SIGUSR1), dae creates a new `ControlPlane`. The metrics system handles this as follows:

1. **`metrics.State`** holds an `atomic.Pointer[control.ControlPlane]` — swapped atomically.
2. **HTTP server lifecycle**: On reload, compare old vs new endpoint config. If changed (address, TLS, auth), shut down old server and create new one. If unchanged, server persists — only the ControlPlane reference is swapped.
3. **Gauges (Phase 1)**: Automatically fresh — collectors read from the new ControlPlane's data structures at next scrape.
4. **Counters (Phase 2)**: Reset to zero on reload since they live on `DnsController`/`Dialer`/`ControlPlane` structs which are recreated. Prometheus handles counter resets natively via `rate()` and `increase()`.
5. **Registry**: Persists across reloads. Collectors reference `metrics.State`, not the ControlPlane directly.

**Reload sequence in `cmd/run.go`:**
```
SIGUSR1 →
  1. newC = newControlPlane(...)
  2. metricsState.SetControlPlane(newC)  // atomic swap
  3. oldC.Close()
  4. if endpoint config changed:
       endpointServer.Shutdown()
       endpointServer = createNewServer(newConf)
       go endpointServer.ListenAndServe[TLS]()
```

### 5. Extensibility Architecture

Adding new metrics requires **only** these steps:

1. **Create a new collector file** in `pkg/metrics/` implementing `prometheus.Collector`
2. **Register it** in `registry.go`'s `NewRegistry()` — one line addition
3. **Add getter methods** to domain types if needed (or use existing ones)

The extensibility is built on three pillars:
- **`prometheus.Collector` interface**: Each collector is self-contained. New collectors don't affect existing ones.
- **`metrics.State`**: Provides thread-safe access to the ControlPlane. New collectors use the same `State` instance.
- **Explicit `http.ServeMux`**: New HTTP paths (e.g., `/healthz`, `/ready`) can be added alongside `/metrics` without restructuring.

No changes needed to `cmd/run.go`, the HTTP server, or auth middleware when adding new metrics.

## Architecture Overview

```
cmd/run.go
  |
  |-- Creates metrics.State (atomic ControlPlane ref)
  |-- Creates prometheus.Registry (custom)
  |-- Registers all collectors with Registry
  |-- Creates endpoint HTTP server:
  |     /<prometheus_path>  -> [auth middleware] -> promhttp.HandlerFor(registry)
  |     /debug/pprof/*      -> [auth middleware] -> net/http/pprof handlers
  |-- On reload: swaps ControlPlane ref + recreates server if config changed
  |
pkg/metrics/
  |-- state.go              -- State: thread-safe ControlPlane ref holder
  |-- registry.go           -- NewRegistry(), NewHTTPHandler()
  |-- collector_dialer.go   -- Dialer health + health check stats
  |-- collector_dns.go      -- DNS cache, concurrency, forwarder stats
  |-- collector_conn.go     -- Connection pools + connection rate counters
pkg/metricshttp/
  |-- server.go             -- NewEndpointServer() with auth + TLS support
  |-- auth.go               -- BasicAuth middleware
```

Dependency direction: `pkg/metrics/` → `control/`, `component/outbound/` (infrastructure → domain).

---

## Phase 1: Gauge Metrics (Lazy Collection)

No hot-path changes needed. Collectors read existing state at scrape time.

### `pkg/metrics/collector_dialer.go`

| Metric | Type | Labels | Source |
|--------|------|--------|--------|
| `dae_dialer_alive` | Gauge | group, dialer, network | `collection.Alive` via `Dialer.GetCollectionState()` |
| `dae_dialer_latency_last_seconds` | Gauge | group, dialer, network | `Latencies10.LastLatency()` (thread-safe, has internal mutex) |
| `dae_dialer_latency_avg10_seconds` | Gauge | group, dialer, network | `Latencies10.AvgLatency()` (thread-safe, has internal mutex) |
| `dae_dialer_latency_moving_avg_seconds` | Gauge | group, dialer, network | `collection.MovingAverage` via `Dialer.GetCollectionState()` |
| `dae_group_alive_dialers_total` | Gauge | group, network | `AliveDialerSet.AliveCount()` (new method) |

**Thread-safety for `GetCollectionState()`**: The `collection` struct fields (`Alive`, `MovingAverage`) are plain values without internal synchronization. They are protected externally by `Dialer.collectionFineMu`. The new getter must acquire this lock:
```go
func (d *Dialer) GetCollectionState(typ *NetworkType) (alive bool, lastLatency, avg10, movingAvg time.Duration) {
    d.collectionFineMu.RLock()
    defer d.collectionFineMu.RUnlock()
    col := d.collections[*typ]
    // col.Latencies10.LastLatency() and .AvgLatency() have their own internal mutex
    // col.Alive and col.MovingAverage are read under collectionFineMu
    ...
}
```

### `pkg/metrics/collector_dns.go` (Phase 1 portion)

| Metric | Type | Labels | Source |
|--------|------|--------|--------|
| `dae_dns_cache_entries` | Gauge | — | `DnsController.CacheSize()` (reads `dnsCache` sync.Map) |
| `dae_dns_concurrency_in_use` | Gauge | — | `dnsConcurrencyInFlight` atomic around `HandleWithResponseWriter_` |
| `dae_dns_forwarder_cache_entries` | Gauge | — | `ForwarderCacheInfo()` ranges `dnsForwarderCache` |
| `dae_dns_forwarder_in_flight` | Gauge | upstream | `upstreamMetric.inFlight.Load()` per upstream via `dnsUpstreamMetrics` sync.Map |

### `pkg/metrics/collector_conn.go` (Phase 1 portion)

| Metric | Type | Labels | Source |
|--------|------|--------|--------|
| `dae_tcp_connections_active` | Gauge | — | `ControlPlane.CountTcpConnections()` (new; `inConnections.Range()` count) |
| `dae_udp_endpoints_active` | Gauge | — | `UdpEndpointPool.Count()` (new; `pool.Range()` count) |
| `dae_udp_task_queues_active` | Gauge | — | `UdpTaskPool.Count()` (new; iterate internal map) |

**Note on `sync.Map.Range()` cost**: These counts iterate the full map on each scrape. At typical scrape intervals (15-30s) and expected map sizes (hundreds to low thousands), this is negligible.

### Process / Go Runtime (free from prometheus standard collectors)

| Metric | Type | Notes |
|--------|------|-------|
| `process_cpu_seconds_total` | Counter | CPU utilization (`rate()` in Grafana) |
| `process_resident_memory_bytes` | Gauge | RSS memory |
| `process_virtual_memory_bytes` | Gauge | Virtual memory |
| `process_open_fds` / `process_max_fds` | Gauge | File descriptor usage |
| `go_goroutines` | Gauge | Goroutine count |
| `go_memstats_alloc_bytes` | Gauge | Heap allocation |
| `go_memstats_heap_inuse_bytes` | Gauge | Heap in-use |
| `go_gc_duration_seconds` | Summary | GC pause distribution |

From `prometheus.NewProcessCollector()` and `prometheus.NewGoCollector()` — zero code needed.

---

## Phase 2: Counter & Histogram Metrics (Hot-Path Instrumentation)

### DNS Metrics (inspired by mosDNS)

Add counters to `DnsController` struct:

| Metric | Type | Labels | Instrumentation Point |
|--------|------|--------|----------------------|
| `dae_dns_query_total` | Counter | — | `Handle_()` entry |
| `dae_dns_cache_hit_total` | Counter | — | `LookupDnsRespCache_()` returns fresh hit |
| `dae_dns_cache_lazy_hit_total` | Counter | — | `needRefresh` path (stale-while-revalidate, real wiring in v3) |
| `dae_dns_upstream_query_total` | Counter | upstream | `dialSend()` entry |
| `dae_dns_upstream_err_total` | Counter | upstream | `forwardWithDialArg()` error path |
| `dae_dns_rejected_total` | Counter | — | Reject response path |
| `dae_dns_refused_total` | Counter | — | Refused response path |
| `dae_dns_response_latency_seconds` | Histogram | — | End-to-end in `Handle_()` |
| `dae_dns_upstream_latency_seconds` | Histogram | upstream | Around `ForwardDNS()` |

### Health Check Metrics

Add to `collection` struct (per Dialer, per NetworkType):

| Metric | Type | Labels | Instrumentation Point |
|--------|------|--------|----------------------|
| `dae_health_check_total` | Counter | group, dialer, network | `Check()` entry |
| `dae_health_check_failure_total` | Counter | group, dialer, network | `Check()` `err != nil` |

### Connection Rate Metrics

Add to `ControlPlane` struct:

| Metric | Type | Labels | Instrumentation Point |
|--------|------|--------|----------------------|
| `dae_tcp_connections_total` | Counter | protocol, group | `handleConn()` after routing |
| `dae_udp_connections_total` | Counter | protocol, group | `handlePkt()` on new endpoint |

---

## Files to Create

### `pkg/metrics/state.go`
```go
type State struct {
    cp atomic.Pointer[control.ControlPlane]
}
func NewState() *State
func (s *State) SetControlPlane(cp *control.ControlPlane)
func (s *State) GetControlPlane() *control.ControlPlane  // nil-safe
```

### `pkg/metricshttp/auth.go`
```go
// BasicAuthMiddleware wraps an http.Handler with optional basic auth.
func BasicAuthMiddleware(handler http.Handler, username, password string) http.Handler
```
If username is empty, passes through. Otherwise checks `Authorization` header, returns 401 on failure.

### `pkg/metricshttp/server.go`
```go
type EndpointConfig struct {
    ListenAddress     string
    Username          string
    Password          string
    TlsCertificate    string
    TlsKey            string
    PrometheusEnabled bool
    PrometheusPath    string
}

// NewEndpointServer creates an HTTP(S) server with auth middleware, prometheus, and pprof.
func NewEndpointServer(cfg EndpointConfig, registry *prometheus.Registry) (*http.Server, error)

// StartEndpointServer starts the server (HTTP or HTTPS based on TLS config).
func StartEndpointServer(server *http.Server, cfg EndpointConfig) error
```

### `pkg/metrics/registry.go`
- `NewRegistry(state *State) *prometheus.Registry`
- Registers Go/Process collectors + all dae collectors

### `pkg/metrics/collector_dialer.go`
Phase 1 gauges + Phase 2 health check counters.

### `pkg/metrics/collector_dns.go`
Phase 1 gauges + Phase 2 counters/histograms.

### `pkg/metrics/collector_conn.go`
Phase 1 gauges + Phase 2 connection counters.

---

## Files to Modify

### `go.mod`
```
go get github.com/prometheus/client_golang@latest
```

### `config/config.go` — Add endpoint fields to Global struct
```go
EndpointListenAddress     string `mapstructure:"endpoint_listen_address" default:""`
EndpointUsername           string `mapstructure:"endpoint_username" default:""`
EndpointPassword           string `mapstructure:"endpoint_password" default:""`
EndpointTlsCertificate    string `mapstructure:"endpoint_tls_certificate" default:""`
EndpointTlsKey            string `mapstructure:"endpoint_tls_key" default:""`
EndpointPrometheusEnabled bool   `mapstructure:"endpoint_prometheus_enabled" default:"false"`
EndpointPrometheusPath    string `mapstructure:"endpoint_prometheus_path" default:"/metrics"`
```

### `cmd/run.go` — Wire endpoint server, replace pprof setup
1. After `newControlPlane()`: create `metrics.State`, `metrics.NewRegistry()`, set ControlPlane ref
2. Replace pprof block with `metrics.NewEndpointServer()` + `StartEndpointServer()`
3. Validate TLS file permissions before endpoint startup:
   - `endpoint_tls_certificate`: `0640` or `0644`
   - `endpoint_tls_key`: `0600`
4. During reload:
   - Re-validate TLS file permissions before accepting new endpoint config
   - `metricsState.SetControlPlane(newC)` — atomic swap, gauges auto-refresh
   - If endpoint config changed: `endpointServer.Shutdown()` + create/start new server
5. At shutdown: `endpointServer.Shutdown()`
6. Backward compat: if `PprofPort != 0` and no endpoint configured, create legacy pprof-only server with deprecation log

### `common/file_permission.go` — Shared permission validators
```go
func ValidateFilePermissionNotTooOpen(path string, fi os.FileInfo) error
func ValidateFilePermissionAllowed(path string, fi os.FileInfo, allowedModes ...os.FileMode) error
```
Used by:
- `config/config_merger.go`
- `common/subscription/subscription.go`
- `cmd/run.go` (endpoint TLS files)

### `control/control_plane.go` — Getters + Phase 2 counters
```go
func (c *ControlPlane) Outbounds() []*outbound.DialerGroup
func (c *ControlPlane) DnsController() *DnsController
func (c *ControlPlane) CountTcpConnections() int  // inConnections.Range() count
// Phase 2: ConnCounters struct with TcpTotal/UdpTotal atomic.Int64
```

### `control/tcp.go` — Phase 2: increment counter in `handleConn()`
### `control/udp.go` — Phase 2: increment counter in `handlePkt()`

### `control/dns_control.go` — Getters + Phase 2 DnsCounters
```go
func (c *DnsController) CacheSize() int
func (c *DnsController) ConcurrencyInfo() (current, limit int)    // cap/len of concurrencyLimiter
func (c *DnsController) ForwarderCacheInfo() (count int, inFlightByUpstream map[string]int32)
// Phase 2: DnsCounters struct embedded in DnsController
```

### `component/outbound/dialer/connectivity_check.go`
```go
// GetCollectionState reads collection fields under collectionFineMu.
// Latencies10 methods (LastLatency, AvgLatency) have their own internal mutex.
func (d *Dialer) GetCollectionState(typ *NetworkType) (alive bool, lastLatency, avg10, movingAvg time.Duration)
// Phase 2: CheckTotal/FailureTotal atomic.Int64 in collection struct
```

### `component/outbound/dialer/alive_dialer_set.go`
```go
func (a *AliveDialerSet) AliveCount() int  // len(inorderedAliveDialerSet) under mu
```

### `component/outbound/dialer_group.go`
```go
func (g *DialerGroup) AliveDialerSets() [6]*dialer.AliveDialerSet
func (g *DialerGroup) SelectionPolicyName() string
```

### `control/udp_endpoint_pool.go` + `control/udp_task_pool.go`
```go
func (p *UdpEndpointPool) Count() int  // pool.Range() count
func (p *UdpTaskPool) Count() int
```

### `example.dae` — Add endpoint config example in global section

---

## Implementation Sequence

### Phase 1 (Gauges + Infrastructure)
1. `go get github.com/prometheus/client_golang@latest`
2. Add endpoint config fields to `config/config.go`
3. Create `pkg/metricshttp/auth.go` (basic auth middleware)
4. Create `pkg/metricshttp/server.go` (endpoint server with TLS + auth)
5. Create `pkg/metrics/state.go`
6. Add getter methods to existing types (with thread-safety notes above)
7. Create `pkg/metrics/collector_dialer.go` (Phase 1 gauges)
8. Create `pkg/metrics/collector_dns.go` (Phase 1 gauges)
9. Create `pkg/metrics/collector_conn.go` (Phase 1 gauges)
10. Create `pkg/metrics/registry.go` (Go/Process + dae collectors)
11. Modify `cmd/run.go` (wire endpoint server, reload handling)
12. Update `example.dae`

### Phase 2 (Counters/Histograms)
13. Add `DnsCounters` to `DnsController` + instrument hot paths
14. Add DNS latency histograms
15. Add `CheckTotal`/`FailureTotal` to `collection` + instrument `Check()`
16. Add connection counters to `ControlPlane` + instrument `handleConn()`/`handlePkt()`
17. Update collectors to read Phase 2 counters

---

## Git Workflow (Upstream PR)

This section defines the recommended git workflow for submitting this plan to upstream with minimal review noise.

### Repository and Base Branch

- Develop in `/Users/ouzy/Documents/DevProjects/dae` (the main repo clone intended for upstream PRs).
- `origin/main` is kept in sync with `dae/main` (upstream). `.plan/` directory is backed up; `origin/main` can be force-synced safely.
- **Base: PR#936 head**. Since DNS metrics depend on PR#936 structures, branch from PR#936's head (`optimize/code-quality-fixes`). Once PR#936 merges into `dae/main`, rebase onto `dae/main`.
- Do not branch from `eval/pr936-base` directly — it may contain local evaluation commits not in the upstream PR.

### Phase 1 Branch Creation

```bash
cd /Users/ouzy/Documents/DevProjects/dae
git fetch dae
# Branch from PR#936's upstream head
git switch -c feat/metrics-endpoint-phase1 dae/optimize/code-quality-fixes
```

**After PR#936 merges**:
```bash
git fetch dae
git rebase dae/main feat/metrics-endpoint-phase1
```

### Local Noise Exclusion (do not commit)

Do not include local-only files/folders in commits, such as `.DS_Store` and `.plan/`.

```bash
cat >> .git/info/exclude <<'EOF'
.DS_Store
.plan/
**/.DS_Store
EOF
```

If needed, also enforce at commit time with explicit path selection (`git add <paths>`) instead of `git add .`.

### Phase 2 Branch Strategy

Choose one of the following based on merge status of Phase 1:

1. **Stacked PR (Phase 1 not merged yet)**
   Branch Phase 2 from Phase 1:
   ```bash
   git switch -c feat/metrics-endpoint-phase2 feat/metrics-endpoint-phase1
   ```

2. **Independent PR (Phase 1 already merged)**
   Branch Phase 2 from updated upstream main:
   ```bash
   git fetch dae
   git switch -c feat/metrics-endpoint-phase2 dae/main
   ```

### Commit Boundary Recommendation

- **Phase 1 PR scope**: endpoint config, endpoint server/auth/TLS wiring, metrics state/registry/collectors (gauges), reload lifecycle integration, docs/example updates.
- **Phase 2 PR scope**: hot-path counters/histograms and collector extension for Phase 2 metrics.
- Keep PRs small and reviewable; avoid mixing unrelated cleanup/refactors.

### Optional: Separate Working Tree

To isolate from existing local branches/worktrees:

```bash
cd /Users/ouzy/Documents/DevProjects/dae
git fetch dae
git worktree add /Users/ouzy/Documents/DevProjects/dae-metrics-phase1 -b feat/metrics-endpoint-phase1 dae/optimize/code-quality-fixes
```

---

## Complete Metrics Summary

### Dialer / Health Check
| Metric | Type | Labels | Phase |
|--------|------|--------|-------|
| `dae_dialer_alive` | Gauge | group, dialer, network | 1 |
| `dae_dialer_latency_last_seconds` | Gauge | group, dialer, network | 1 |
| `dae_dialer_latency_avg10_seconds` | Gauge | group, dialer, network | 1 |
| `dae_dialer_latency_moving_avg_seconds` | Gauge | group, dialer, network | 1 |
| `dae_group_alive_dialers_total` | Gauge | group, network | 1 |
| `dae_health_check_total` | Counter | group, dialer, network | 2 |
| `dae_health_check_failure_total` | Counter | group, dialer, network | 2 |

### DNS
| Metric | Type | Labels | Phase |
|--------|------|--------|-------|
| `dae_dns_cache_entries` | Gauge | — | 1 |
| `dae_dns_concurrency_in_use` | Gauge | — | 1 |
| `dae_dns_forwarder_cache_entries` | Gauge | — | 1 |
| `dae_dns_forwarder_in_flight` | Gauge | upstream | 1 |
| `dae_dns_query_total` | Counter | — | 2 |
| `dae_dns_cache_hit_total` | Counter | — | 2 |
| `dae_dns_cache_lazy_hit_total` | Counter | — | 2 (real wiring, needRefresh path in v3) |
| `dae_dns_upstream_query_total` | Counter | upstream | 2 |
| `dae_dns_upstream_err_total` | Counter | upstream | 2 |
| `dae_dns_rejected_total` | Counter | — | 2 |
| `dae_dns_refused_total` | Counter | — | 2 |
| `dae_dns_response_latency_seconds` | Histogram | — | 2 |
| `dae_dns_upstream_latency_seconds` | Histogram | upstream | 2 |

### Connections
| Metric | Type | Labels | Phase |
|--------|------|--------|-------|
| `dae_tcp_connections_active` | Gauge | — | 1 |
| `dae_udp_endpoints_active` | Gauge | — | 1 |
| `dae_udp_task_queues_active` | Gauge | — | 1 |
| `dae_tcp_connections_total` | Counter | protocol, group | 2 |
| `dae_udp_connections_total` | Counter | protocol, group | 2 |

### Runtime / Node
| Metric | Type | Labels | Phase |
|--------|------|--------|-------|
| `dae_runtime_upload_bytes_total` | Counter | — | PR#968 runtime |
| `dae_runtime_download_bytes_total` | Counter | — | PR#968 runtime |
| `dae_runtime_upload_rate_bytes_per_second` | Gauge | — | PR#968 runtime |
| `dae_runtime_download_rate_bytes_per_second` | Gauge | — | PR#968 runtime |
| `dae_node_latency_seconds` | Gauge | link | PR#968 runtime |
| `dae_node_alive` | Gauge | link | PR#968 runtime |

### Process / Runtime (automatic)
| Metric | Type | Phase |
|--------|------|-------|
| `process_cpu_seconds_total` | Counter | 1 |
| `process_resident_memory_bytes` | Gauge | 1 |
| `process_virtual_memory_bytes` | Gauge | 1 |
| `process_open_fds` / `process_max_fds` | Gauge | 1 |
| `go_goroutines` | Gauge | 1 |
| `go_memstats_*` | Various | 1 |
| `go_gc_duration_seconds` | Summary | 1 |

---

## Verification

1. `go build ./...` — compilation
2. `go vet ./...` — static analysis
3. **Basic functionality**: `curl http://localhost:5556/metrics` — verify gauge metrics + process/runtime metrics
4. **Pprof co-hosting**: `curl http://localhost:5556/debug/pprof/` — verify pprof
5. **Auth**: Set username/password, verify `curl` without auth returns 401, with auth returns 200
6. **TLS**: Set cert/key, verify `curl -k https://localhost:5556/metrics` works
7. **Custom path**: Set `endpoint_prometheus_path = "/custom"`, verify `/custom` works and `/metrics` returns 404
8. **Reload (SIGUSR1)**: Verify metrics endpoint survives, gauges reflect new ControlPlane state
9. **Reload with config change**: Change `endpoint_listen_address` port, send SIGUSR1, verify old port stops and new port serves
10. **Backward compat**: Set only `pprof_port`, verify deprecation warning + pprof works
11. (Phase 2) Generate DNS traffic, verify counters and histograms
12. (Phase 2) Verify `rate(dae_tcp_connections_total[5m])` in Prometheus

---

## Appendix: PR#968 Rebase DNS Metric Disposition

The rebased branch intentionally no longer depends on the abandoned PR#936 DNS limiter/cache-forwarder internals:

| Former plan item | Rebased disposition |
|------------------|---------------------|
| `dae_dns_concurrency_limit` | Removed until a real upstream limiter exists. |
| `dae_dns_concurrency_in_use` | Synthesized with an atomic in-flight count around `HandleWithResponseWriter_`. |
| `dae_dns_forwarder_in_flight` | Synthesized per upstream on `dnsUpstreamMetric`. |
| `dae_dns_cache_miss_total` | Removed; dashboard derives miss rate from `sum(rate(dae_dns_upstream_query_total[…]))`. |
| `dae_dns_cache_lazy_hit_total` | Real wiring in v3 via the `needRefresh` (stale-while-revalidate) path. |
