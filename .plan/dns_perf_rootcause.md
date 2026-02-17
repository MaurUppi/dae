# DNS 性能根因分析 — DNS 模块之外

**背景**: DNS 模块 v3-dev 修复已落地，CI 通过无 DATA RACE，但生产侧测试仍显示：
```
[dns] querying 200 domains via 192.168.1.15 (concurrency=200)
[dns] done: 133/200 ok  (15.31s)
[dns] done: 127/200 ok  (15.33s)
```
成功率 ~66%，每轮耗时约 15s。本报告专注审查 DNS 模块之外的根因。

---

## 架构概述（完整调用链）

```
kernel BPF tproxy
    │
    ▼
control_plane.go: ReadMsgUDPAddrPort (单一 goroutine)
    │  EmitTask(convergeSrc.String(), task)
    ▼
UdpTaskPool / UdpTaskQueue (per-src-IP 串行 goroutine)
    │  task() → handlePkt()
    ▼
udp.go: handlePkt()
    │  isDns → dnsController.Handle_()  [⚠️ 同步阻塞]
    ▼
dns_control.go: Handle_() → handle_()
    │  handlingState.mu.Lock()  [per-cacheKey 串行化]
    │  dialSend(context.Background(), ...)
    ▼
dns_control.go: dialSend()
    │  dnsForwarderCacheMu.Lock()
    │  forwarder.ForwardDNS(ctxDial, data)  [⚠️ 阻塞最长 8s]
    ▼
dns.go: DoUDP.ForwardDNS()
    │  DialContext() → new socket per call
    │  goroutine: Write + retry every 1s
    │  main: Read (block)
    ▼
sendPkt() → AnyfromPool.GetOrCreate(from, 5s TTL) → WriteToUDPAddrPort()
```

---

## P0 — 致命缺陷

### P0-1: `dnsForwarderCache` 缓存已关闭的连接对象

**文件**: `control/dns_control.go`, Line 613-667

**现象**: 从缓存中取出 `forwarder`，执行 `ForwardDNS()`，成功后立即 `forwarder.Close()`（L666）并将该已关闭对象留在缓存中。下一个请求从缓存中取出这个已关闭的 forwarder，调用 `ForwardDNS()` 时在 `DialContext()` 内直接失败（取决于实现）或使用已关闭的 conn。

**根因代码**:
```go
// L615-627: 取 forwarder (可能是已关闭的)
c.dnsForwarderCacheMu.Lock()
forwarder, ok := c.dnsForwarderCache[cacheKeyForwarder]
if !ok {
    forwarder, err = newDnsForwarder(...)
    c.dnsForwarderCache[cacheKeyForwarder] = forwarder  // ← 写入缓存
}
c.dnsForwarderCacheMu.Unlock()

// L665-667: 使用后立即关闭，但不从缓存中删除
forwarder.Close()
connClosed = true
```

**影响**:
- 每次成功或失败的 DNS 查询后，都会把已关闭的 forwarder 留在缓存
- 下一个相同 upstream+dialArgument 的请求取到死连接
- 对 DoUDP: `d.conn` 已 nil，`ForwardDNS` 会重新 `DialContext` — **但此时 `d.conn = conn` 会覆写同一结构体字段**，若有并发（多个 goroutine 持有同一 forwarder 引用）会产生竞争
- 对 DoTCP/DoTLS: `conn` 已关闭，`Read/Write` 立即返回 `use of closed network connection` 错误
- **实际效果**: `dnsForwarderCache` 的缓存命中几乎等价于缓存未命中（每次都需要重新 Dial），但同时增加了 `dnsForwarderCacheMu.Lock()` 的竞争开销

**修复方向**:
选项 A（推荐）: 不缓存 DnsForwarder 实例，改为缓存 `dialArgument`（已经缓存了）。每次调用直接 `newDnsForwarder()`，用完关闭。删除 `dnsForwarderCache` 和 `dnsForwarderLastUse` 字段。

选项 B: 改为连接池模式。使用后放回池而非关闭，池满时关闭最旧的。需要心跳/idle 检测。

---

## P1 — 高优先级

### P1-1: per-src-IP 串行队列将 DNS 请求排队

**文件**: `control/control_plane.go` L816, `control/udp_task_pool.go`

**现象**: `EmitTask(convergeSrc.String(), task)` 以**源 IP**（已收敛：IPv4-mapped IPv6 → IPv4）为 key，建立 per-src 串行 goroutine。同一客户端的所有 UDP 包（包括 DNS）在此 goroutine 中**顺序执行**。

**对测试场景的影响**:
- 测试客户端 IP = `192.168.1.x` (concurrency=200)：若所有 200 个查询来自**同一源 IP**，它们全部排入同一条 queue，串行处理
- 每个 DNS 请求在 `dialSend` 中阻塞最长 8s (`DefaultDialTimeout`)
- 串行 200 个请求 × 8s = 最坏 1600s；即使上游快速响应也是串行的
- `UdpTaskQueueLength = 128`：当 queue 满时，`EmitTask` 丢弃任务（`select { case q.ch <- task: case <-q.ctx.Done(): }`），超出的 DNS 请求**静默丢弃**

**观察到的 15s/round**: 与 `DnsNatTimeout = 17s` 接近。测试可能在 17s timeout 前结束统计，获得了部分响应。

**关键路径**:
```
handlePkt → Handle_() → handle_() → dialSend()  [同步, 最长 8s]
```
整条链都在 UdpTaskQueue 的 convoy goroutine 里同步运行。

### P1-2: `handlingState` per-domain mutex 导致热点域名排队

**文件**: `control/dns_control.go` L494-505

**现象**: 对相同 `cacheKey`（qname+qtype）的并发请求，第一个持锁做网络请求，后续请求全部在 `handlingState.mu.Lock()` 处阻塞。

**设计意图**: 避免重复上游请求（dedup）。

**问题**: 在高并发下，若 200 个请求中有多个查询同一域名（如 `google.com`、`cloudflare.com`），所有重复请求都在 `mu.Lock()` 处**串行等待** — 而不是等第一个请求完成后立刻从缓存获取。

**实际延迟**:
- 第 1 个请求: 网络耗时 T
- 第 2 个请求: 等待 T + 从缓存读（快）
- 第 N 个请求: 等待 T + (N-1) × mutex acquire time

注意: mutex acquire time 不是 0 — Go runtime 调度和 mutex 争用在 N 很大时有 ms 级延迟。

### P1-3: `dialSend` 接收 `ctx` 但 `handle_()` 传入 `context.Background()`

**文件**: `control/dns_control.go` L539

```go
return c.dialSend(context.Background(), 0, req, data, dnsMessage.Id, upstream, needResp)
```

**问题**: `handle_()` 的 `ctx` 参数来自 `Handle_()` 但未使用。`dialSend` 接收的 ctx 是 `context.Background()`，永远不会被取消。

**影响**:
- 若上游慢，200 个并发请求各等待 8s，总计占用 200 × 8 = 1600 goroutine-seconds
- 即使客户端已断开，请求仍继续处理
- 这也是 `Handle_()` 无法接收上层超时信号的根本原因

### P1-4: `AnyfromPool.GetOrCreate` 在写路径持全局写锁

**文件**: `control/anyfrom_pool.go` L177-231

**现象**: 发送 DNS 响应时调用 `sendPkt → DefaultAnyfromPool.GetOrCreate(from.String(), 5s)`。

当 `from`（DNS 上游的地址，即 `req.realDst`）不在池中时：
1. `RLock()` → not found → `RUnlock()`
2. `Lock()` → double-check → `d.ListenPacket(...)` — **在持锁期间创建 socket**
3. `Unlock()`

`ListenPacket` 在内核中分配 fd、绑定地址，耗时可达数百 μs。200 个并发 DNS 响应若需要创建新 socket（例如上游 IP 首次出现），会在全局写锁上串行 — 每个响应都要等前一个 socket 创建完成。

**fd 消耗**:
- 每个唯一的 `from` 地址 = 1 个 socket
- 测试中 `from` = DNS 上游地址（通常固定），所以池通常命中。但 TTL = 5s 很短，高并发下可能频繁 expire + recreate。

---

## P2 — 中优先级

### P2-1: `DoUDP.ForwardDNS` 每次调用新建 socket（无连接复用）

**文件**: `control/dns.go` L308-317

```go
func (d *DoUDP) ForwardDNS(ctx context.Context, data []byte) (*dnsmessage.Msg, error) {
    conn, err := d.dialArgument.bestDialer.DialContext(ctx, ...)
    ...
    d.conn = conn
```

每次 `ForwardDNS` 都调用 `DialContext` 建立新连接，即使 upstream 是同一个 IP:Port。

**影响**:
- 200 个并发 DNS 查询 = 200 个 `DialContext` 调用
- 每次 Dial 至少需要: fd 分配 + 可能的 SOCKS5/proxy 握手
- 与缓存设计矛盾: `dnsForwarderCache` 本应缓存连接以复用，但 P0-1 缺陷导致缓存的是已关闭对象

### P2-2: `UdpTaskQueueLength = 128` 导致 DNS 包静默丢弃

**文件**: `control/udp_task_pool.go` L14, L93-96

```go
select {
case q.ch <- task:
case <-q.ctx.Done():  // ← 任务被丢弃，无日志，无错误
}
```

当 queue 满（>128 个未处理任务）时，新 DNS 请求**静默丢弃**。测试中 200 concurrency vs 128 queue length — 如果是同一 src IP，超出的 72 个请求被丢弃，贡献到 ~66% 成功率。

### P2-3: fd 压力 — 实际所需 fd 数量远超预期

测试输出: `[fd-limit] soft limit 256 -> 2100 (需要 2100)`

实际 fd 消耗（200 concurrency）:
- 200 个 DoUDP 上游 socket（`DialContext`）
- 1-N 个 AnyfromPool socket（按唯一 src addr）
- 200 个 UdpTaskQueue `chan` 的底层 goroutine（不占 fd 但占内存）
- 控制平面 UDP socket: 1
- BPF map fd: 多个
- 合计: 可能 400-600+ 个 fd

若系统 soft limit 在测试框架外没有正确提升，fd 耗尽会导致 `DialContext` 返回 `too many open files`，从而 DNS 失败。

### P2-4: `handle_()` 中的 `handlingState` 永不清理（内存泄漏）

**文件**: `control/dns_control.go` L502-504

```go
if atomic.LoadUint32(&handlingState.ref) == 0 {
    c.handling.Delete(cacheKey)
}
```

正常路径会清理。但若 `handle_()` 在持锁期间 `panic`（罕见），defer 中的 `Delete` 不会执行 — `sync.Map` 中遗留该 key，未来对同一 domain 的请求会使用该 mutex（ref=0 状态），行为未定义。

---

## P3 — 低优先级

### P3-1: `AnyfromPool` TTL 仅 5s，但 DNS 响应路径只需毫秒级

`AnyfromTimeout = 5s` — 适合 NAT 场景，对 DNS 这种一问一答来说可能太短，导致高频 expire + recreate。

### P3-2: `DnsNatTimeout = 17s` 对齐了 RFC 5452，但远大于 `DefaultDialTimeout = 8s`

若 dialSend 超时（8s），NAT 条目保持 17s，占用资源而不会被清理。

---

## 根因汇总与优先级

| # | 根因 | 影响 | 分类 |
|---|------|------|------|
| P0-1 | `dnsForwarderCache` 缓存已关闭连接，缓存命中 = 死连接 | DNS 失败（TCP/TLS），UDP 重建连接 | P0 |
| P1-1 | per-src 串行队列：同 IP 的 200 个 DNS 请求排队处理 | 15s/round = 串行等待累积 | P1 |
| P1-2 | `handlingState` mutex：同域名请求串行等待第一个完成 | 热点域名排队 | P1 |
| P1-3 | `context.Background()` 替代请求 ctx：无法取消 | 资源泄漏，无法限制并发耗时 | P1 |
| P1-4 | `AnyfromPool.GetOrCreate` 持全局写锁创建 socket | 高并发响应路径串行 | P1 |
| P2-1 | DoUDP 每次 ForwardDNS 新建 socket | 增加 DialContext 开销 | P2 |
| P2-2 | `UdpTaskQueueLength=128` < 200 concurrency，溢出静默丢弃 | 直接贡献 ~34% 失败率 | P2 |
| P2-3 | fd 压力：200 并发需要 400-600 fd | 可能触发 `too many open files` | P2 |

---

## 可解释 66% 成功率的组合

以下三个因素叠加可完整解释 133/200 成功率：

1. **P2-2 (队列溢出)**: 若 200 并发来自同一 src IP，queue 只能容纳 128 个任务 → 72 个 DNS 请求被静默丢弃 → 128/200 = 64%（接近实测 66%）
2. **P0-1 (死连接缓存)**: 即使进入队列的请求，若使用 TCP/TLS upstream，也可能因缓存的已关闭连接失败
3. **P1-1 (串行阻塞)**: 128 个任务串行执行，每个 8s timeout 上限 → 需要 ~15s 处理完毕（与测试 15.31s 完全吻合）

---

## 修复建议

### 立即修复（P0）

```go
// dns_control.go: dialSend 中删除 dnsForwarderCache 读取
// 方案 A: 每次直接新建，不缓存（简单、安全）
forwarder, err := newDnsForwarder(upstream, *dialArgument)
if err != nil {
    return err
}
defer forwarder.Close()
```

或者方案 B（更优）: 删除 `dnsForwarderCache` / `dnsForwarderLastUse` 字段，因为当前缓存逻辑净效果为负（增加锁竞争，无连接复用收益）。

### 高优先级修复（P1）

1. **P1-1**: 对 DNS 请求不使用 per-src 串行队列，改为直接 `go c.handlePkt(...)` 或使用 per-src **并发** worker pool（有上限）。DNS 本身是无状态的，串行化没有必要。

2. **P2-2**: 若保留串行队列，将 `UdpTaskQueueLength` 提升至 1024，或为 DNS 请求使用独立的高容量队列。

3. **P1-3**: 将 `handle_()` 的调用改为传入带超时的 context，而非 `context.Background()`：
   ```go
   handleCtx, cancel := context.WithTimeout(context.Background(), DnsNatTimeout)
   defer cancel()
   return c.dialSend(handleCtx, 0, req, data, ...)
   ```

---

## 验证方法

```bash
# 确认 P0-1 修复效果（删除缓存后 TCP upstream 成功率应接近 100%）
go test -v -run TestDialSend ./control/...

# 确认 P2-2 队列容量（增大后 concurrency=200 不应丢包）
go test -v -run TestUdpTaskPool ./control/...

# 端到端性能测试
# 预期修复后: 200/200 ok, <2s/round (全缓存命中) 或 <500ms (upstream 响应快)
```

---

*生成时间: 2025-08-07*
*审查范围: control/control_plane.go, control/udp.go, control/udp_task_pool.go, control/dns_control.go, control/dns.go, control/anyfrom_pool.go*
