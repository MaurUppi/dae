# dae Metrics Endpoint — Audit Report

**Date**: 2026-02-23
**Scope**: Phase 1 + Phase 2 metrics implementation (`feat/metrics-endpoint-phase1`, PR#941)
**Live endpoint verified**: `http://192.168.1.15:5556/metrics`
**Files reviewed**: metrics-related changes in `pkg/metrics/`, `control/`, `component/outbound/dialer/`, `cmd/run.go`

---

## Code Review Summary

**Overall assessment**: APPROVE (no blocking issue)

Notes:
- Previous `dae_dns_concurrency_in_use` inversion issue has been fixed in metrics branch (`fix(metrics): correct dns concurrency in-use gauge semantics`).
- Collector descriptor coverage has been strengthened by test (`test(metrics): verify all collector descriptors are exposed`).

---

## Findings

### P0 — Critical
*(none)*

### P1 — High
*(none)*

### P2 — Medium
*(none)*

### P3 — Low
*(none)*

---

## Endpoint Verification

All metrics from both phases are present at `http://192.168.1.15:5556/metrics`.

### Phase 1 Gauges — All present ✅
| Metric | Type | Status |
|--------|------|--------|
| `dae_dialer_alive` | gauge | ✅ Values: 0/1 per dialer×network |
| `dae_dialer_latency_last_seconds` | gauge | ✅ Real latency values (e.g., 0.0497s) |
| `dae_dialer_latency_avg10_seconds` | gauge | ✅ Real latency averages |
| `dae_dialer_latency_moving_avg_seconds` | gauge | ✅ EWMA values |
| `dae_group_alive_dialers_total` | gauge | ✅ Per group×network |
| `dae_dns_cache_entries` | gauge | ✅ (`0` — cache expired at scrape time) |
| `dae_dns_concurrency_in_use` | gauge | ✅ Synthesized from DNS handler in-flight count; typically `0` unless upstreams are slow or traffic is concurrent |
| `dae_dns_forwarder_cache_entries` | gauge | ✅ (`0` — no long-lived forwarders active) |
| `dae_dns_forwarder_in_flight{upstream}` | gauge | ✅ Synthesized per upstream; emits when an upstream has been observed and reports active forwards |
| `dae_tcp_connections_active` | gauge | ✅ |
| `dae_udp_endpoints_active` | gauge | ✅ |
| `dae_udp_task_queues_active` | gauge | ✅ |

### Phase 2 Counters / Histograms — All present ✅
| Metric | Type | Status |
|--------|------|--------|
| `dae_dns_query_total` | counter | ✅ `4` |
| `dae_dns_cache_hit_total` | counter | ✅ `1` |
| `dae_dns_cache_lazy_hit_total` | counter | ✅ Permanent `0` zero-stub until stale-while-revalidate is implemented |
| `dae_dns_upstream_query_total{upstream}` | counter | ✅ `tcp://192.168.1.8:5553` |
| `dae_dns_upstream_err_total{upstream}` | counter | ✅ |
| `dae_dns_rejected_total` | counter | ✅ `0` |
| `dae_dns_refused_total` | counter | ✅ `0` zero-stub until overload-protection refusal path is wired |
| `dae_dns_response_latency_seconds` | histogram | ✅ 12 buckets + sum + count |
| `dae_dns_upstream_latency_seconds{upstream}` | histogram | ✅ per upstream |
| `dae_health_check_total{group,dialer,network}` | counter | ✅ |
| `dae_health_check_failure_total{group,dialer,network}` | counter | ✅ |
| `dae_tcp_connections_total{protocol,group}` | counter | ✅ `tcp4/HK = 1` |
| `dae_udp_connections_total{protocol,group}` | counter | ✅ |

### Runtime / Node Metrics — Added by PR#968 rebase ✅
| Metric | Type | Status |
|--------|------|--------|
| `dae_runtime_upload_bytes_total` | counter | ✅ From runtime stats snapshot |
| `dae_runtime_download_bytes_total` | counter | ✅ From runtime stats snapshot |
| `dae_runtime_upload_rate_bytes_per_second` | gauge | ✅ From runtime stats snapshot |
| `dae_runtime_download_rate_bytes_per_second` | gauge | ✅ From runtime stats snapshot |
| `dae_node_latency_seconds{link}` | gauge | ✅ From node latency snapshot |
| `dae_node_alive{link}` | gauge | ✅ From node latency snapshot |

### Process / Go Runtime ✅
All standard `process_*` and `go_*` metrics are present.

---

## Architecture Assessment

| Concern | Status | Notes |
|---------|--------|-------|
| Dependency direction | ✅ | `pkg/metrics/` depends on `control/`; no reverse dependency |
| prometheus import isolation | ✅ | Metrics dependency remains in metrics package; domain structs expose snapshots/getters |
| Hot-path safety | ✅ | Counters use `atomic.Uint64`; collectors scrape snapshots |
| Thread safety — gauge reads | ✅ | Guarded by mutex/sync.Map/atomic in corresponding components |
| Thread safety — histogram | ✅ | Atomic bucket/counter/sum update and snapshot |
| Nil safety in collectors | ✅ | Collectors guard `state == nil`, `cp == nil`, `dc == nil` |
| Reload handling | ✅ | `metrics.State` swaps `ControlPlane` atomically |
| Deterministic output | ✅ | Key sorting is used for labeled DNS upstream metrics |

---

## Required Action Before Upstream PR

No blocking change required based on current audited state.

---

## Optional (Non-blocking)

- Keep dashboard and changelog text aligned with `dae/main` fallback semantics for DNS concurrency gauges (`0/0` until PR936-style limiter model is present).
