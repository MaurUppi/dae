# dae DNS 改进代码审计报告

**审计日期**: 2026-02-16
**审计分支**: `dns_fix` (82dbd66)
**审计范围**: `control/dns.go`, `control/dns_control.go`, `control/dns_improvement_test.go`
**变更统计**: 3 个源文件，+293/-28 行

---

## Code Review Summary

**Files reviewed**: 3 source files, 293 lines added, 28 lines removed
**Overall assessment**: **REQUEST_CHANGES** (1 P0, 3 P1, 5 P2, 2 P3)

---

## 已实现任务与计划一致性确认

| 计划任务 | 实现状态 | 备注 |
|---------|---------|------|
| T1: DoUDP 连接回收 + context 传播 | ✅ 已实现 | `d.conn = conn`, `Close()` 置 nil, `context.WithTimeout(ctx, ...)` |
| T2: dialSend 超时反馈闭环 | ✅ 已实现 | `isTimeoutError` + `timeoutExceedCallback` 在主/fallback 路径 |
| T3: HTTP/Stream context+deadline | ✅ 已实现 | `NewRequestWithContext`, `sendStreamDNS(ctx, ...)`, `SetDeadline` |
| T4: tcp+udp 同查询 fallback | ✅ 已实现 | `tcpFallbackDialArgument` 条件触发，一次 fallback |
| T5: ipversion_prefer 条件补查 | ✅ 已实现 | 先查首选 → 按需补查 → 条件 reject |
| T6: dnsForwarderCache 淘汰 | ✅ 已实现 | `maxDnsForwarderCacheSize=128`, 按 last-use 淘汰 |

---

## Findings

### P0 - Critical

#### P0-1: DoUDP 并发数据竞争 — goroutine 写 `d.conn` 与主线程读 `d.conn` 无同步

**文件**: `control/dns.go:307-361`

DoUDP.ForwardDNS 在 L316 执行 `d.conn = conn`，然后启动一个 goroutine（L323-347）每秒通过 `d.conn.Write(data)` 重发 DNS 请求，同时主 goroutine 在 L353 调用 `d.conn.Read(respBuf)` 阻塞等待响应。

这里有两个并发风险：

1. **重入竞争**：由于 `DoUDP` 现在被缓存复用（forwarder cache），如果上一次查询的 goroutine 尚未退出（`dnsReqCtx` 未被取消），新一次 `ForwardDNS` 调用会在 L316 覆写 `d.conn`，导致旧 goroutine 向新连接写入旧请求数据。虽然 `dialSend` 在成功后调用 `forwarder.Close()`，但 Close 只关闭 `d.conn` 并置 nil，旧 goroutine 下一次 `d.conn.Write` 会 panic（nil pointer dereference）或产生不可预测行为。

2. **goroutine 泄漏**：如果 `ForwardDNS` 因读取错误提前返回（L354），`cancelDnsReqCtx` 会在 defer 中被调用，goroutine 应该在下一个 `dnsReqCtx.Done()` 检查时退出。但这依赖于 goroutine 当前正好在 `select` 等待而非 `d.conn.Write` 阻塞中。如果 Write 因连接已关闭而阻塞（某些实现），goroutine 会泄漏。

**建议修复**：
- 方案 A（推荐）：`ForwardDNS` 使用局部变量 `conn` 传递给 goroutine（via closure capture），而非通过 `d.conn` 共享状态。仍在函数开头赋值 `d.conn = conn` 以支持 `Close()`，但 goroutine 内部使用捕获的局部变量：
  ```go
  d.conn = conn
  localConn := conn // goroutine 使用 localConn
  go func() {
      for {
          _, _ = localConn.Write(data)
          ...
      }
  }()
  n, err := localConn.Read(respBuf)
  ```
- 方案 B：在 `ForwardDNS` 入口处检查并关闭旧连接 + 等待旧 goroutine 退出（通过 done channel）。

---

### P1 - High

#### P1-1: `dialSend` 残留 dead code（L635-637）

**文件**: `control/dns_control.go:635-637`

```go
if err != nil {
    return err
}
```

此处 `err` 来自 `newDnsForwarder`（L619），但该错误已在 L620-622 处理并返回。到达 L635 时，`err` 一定为 nil（cache hit 时 `err` 未被重新赋值，cache miss 时错误已在 L620 返回）。这段代码是 dead code，降低了可读性，且增加了维护者误解控制流的风险。

**建议**: 删除 L635-637。

#### P1-2: fallback 失败时返回原始 `err` 而非 `fallbackErr`

**文件**: `control/dns_control.go:646-647`

```go
if fallbackErr != nil {
    return err  // 这里返回的是原始 UDP 错误，而非 fallback 创建失败的错误
}
```

当 `newDnsForwarder` 为 TCP fallback 创建失败时，返回的是原始 UDP 超时错误 `err`，而非 fallback 构造错误 `fallbackErr`。这会让调试时误以为是 UDP 超时，实际是 TCP forwarder 创建失败。应返回 `fallbackErr` 或包含两者的 wrapped error。

**建议**: `return fmt.Errorf("tcp fallback forwarder creation failed: %w (original: %v)", fallbackErr, err)`

#### P1-3: `dialSend` 中 `ctxDial` 使用 `context.TODO()` 而非调用链 context

**文件**: `control/dns_control.go:610`

```go
ctxDial, cancel := context.WithTimeout(context.TODO(), consts.DefaultDialTimeout)
```

v3 计划要求统一 context 传播，但 `dialSend` 的顶层 context 仍然是 `context.TODO()`。这意味着：
- 即使上层取消（如 client 断开），`dialSend` 不会感知取消，继续等待 8s 超时
- 在高并发场景下，已被客户端放弃的请求仍会占用上游连接资源

**现实影响评估**: 这是既有代码而非本次引入的问题，且 `dialSend` 当前无调用者能传入有意义的 context（来自 eBPF 层的 UDP 请求天然无 context）。优先级为 P1 是因为它与本次改进的 context 统一目标不一致，但不阻塞合并。

**建议**: 在后续迭代中为 `dialSend` 增加 `ctx` 参数，替换 `context.TODO()`。

---

### P2 - Medium

#### P2-1: 缓存的 forwarder 在每次 `dialSend` 返回后被 Close()，使缓存失去意义

**文件**: `control/dns_control.go:629-633, 670-671`

```go
defer func() {
    if !connClosed {
        forwarder.Close()
    }
}()
// ...
forwarder.Close()
connClosed = true
```

forwarder 从 cache 取出后，无论成功还是失败，都会在 `dialSend` 返回前被 `Close()` 关闭。这意味着 **缓存中的 forwarder 在下次被取出时已经处于关闭状态**，但对于 DoTCP/DoTLS/DoUDP，`ForwardDNS` 总是重新拨号（不检查旧连接状态），所以不会直接出错。然而这使得 forwarder cache 实质退化为"forwarder 工厂缓存"——缓存的不是连接，而是配置。

对于 DoH（复用 `http.Client`）和 DoQ（复用 `quic.EarlyConnection`），`Close()` 是空操作，所以缓存对它们确实有连接复用价值。但对 TCP/TLS/UDP 类型，每次 dialSend 都是"创建→使用→关闭"的完整生命周期，cache 只是避免了重复创建 `DnsForwarder` struct（开销极低）。

**建议**: 这是一个架构层面的问题，不阻塞当前 PR。但如果要实现真正的 TCP/TLS 连接池复用，需要重新设计 forwarder 的生命周期管理。

#### P2-2: `evictDnsForwarderCacheOneLocked` 的 O(n) 扫描

**文件**: `control/dns_control.go:134-158`

淘汰策略通过遍历整个 `dnsForwarderLastUse` map 找到最旧项，时间复杂度 O(n)，其中 n = maxDnsForwarderCacheSize = 128。

**影响**: 在 `dialSend` 的 hot path 上（持有 `dnsForwarderCacheMu` 锁期间），128 次迭代不是性能问题。但如果未来增大缓存容量，应考虑使用 `container/heap` 或链表实现 O(1) 淘汰。

**建议**: 当前 n=128 可接受，添加注释说明复杂度和限制。

#### P2-3: `dnsForwarderKey` 包含指针字段，map key 比较语义依赖指针相等

**文件**: `control/dns_control.go:385-388, 375-383`

`dnsForwarderKey` 嵌入了 `dialArgument`，而 `dialArgument` 包含 `*dialer.Dialer` 和 `*outbound.DialerGroup` 指针字段。Go 的 map key 比较指针时使用指针值（地址），不比较指向的内容。

**影响**: 如果同一个逻辑 dialer 由不同指针表示（例如 reload 后），cache 会未命中。这不会导致正确性问题（只是 cache miss），但可能导致 cache 膨胀。考虑到 reload 后整个 `DnsController` 会被重建，这个问题在实践中不太可能触发。

**建议**: 可接受，但如果 cache miss 率高于预期，应排查此原因。

#### P2-4: `ipversion_prefer` 条件补查路径可能产生不一致的响应

**文件**: `control/dns_control.go:453-463`

```go
cache2 := c.LookupDnsRespCache(c.cacheKey(qname, qtype2), true)
if cache2 == nil || !cache2.IncludeAnyIp() {
    if err = c.handle_(dnsMessage2, req, false); err != nil {
        return err
    }
    cache2 = c.LookupDnsRespCache(c.cacheKey(qname, qtype2), true)
}
if cache2 != nil && cache2.IncludeAnyIp() {
    return c.sendReject_(dnsMessage, req)
}
return sendPkt(c.log, resp, req.realDst, req.realSrc, req.src, req.lConn)
```

逻辑分析：
- 当 `qtype != c.qtypePrefer` 时（即当前请求的类型不是首选类型），代码会查询首选类型的缓存
- 如果首选类型的结果有 IP，则 reject 当前请求（让客户端使用首选类型的结果）
- 否则放行当前请求

但 `c.handle_(dnsMessage2, req, false)` 中 `needResp=false`，这意味着补查的结果只会写入 cache，不会直接回复客户端。如果补查失败（上游超时），`cache2` 仍为 nil，当前请求被放行——这是正确的降级行为。

但有一个边缘场景：`handle_` 内部有 dedup 锁（`handlingState`），如果另一个并发请求正在处理相同的 `qtype2` 查询，`handle_` 会阻塞等待。这可能增加非首选类型查询的延迟，但不影响正确性。

**建议**: 可接受，但应在代码中添加注释解释这个条件补查的意图和边缘行为。

#### P2-5: 测试覆盖不足 — 缺少 DoUDP 连接生命周期测试

**文件**: `control/dns_improvement_test.go`

当前测试覆盖了：
- `isTimeoutError` 各种输入
- `tcpFallbackDialArgument` 条件判断
- `sendStreamDNS` 的 context 取消
- `evictDnsForwarderCacheOneLocked` 淘汰行为

缺少：
- DoUDP 连接生命周期测试（`d.conn` 赋值、Close 幂等性）
- `dialSend` 超时回调触发的集成测试
- forwarder cache hit/miss 路径测试
- ipversion_prefer 条件补查路径测试

**建议**: 补充上述测试用例。鉴于环境限制（依赖 `github.com/daeuniverse/outbound` 无法从 proxy.golang.org 拉取），可考虑使用 mock/interface 抽象降低测试对外部依赖的耦合。

---

### P3 - Low

#### P3-1: 注释格式不一致

**文件**: `control/dns.go:1-4`

```go
/*
*  SPDX-License-Identifier: AGPL-3.0-only
*  Copyright (c) 2022-2025, daeuniverse Organization <dae@v2raya.org>
 */
```

diff 显示 `*/` 行的格式从 `*/` 改为 ` */`（添加了前导空格），使得闭合注释与其他行不对齐。这是一个纯格式变更，不影响功能。

**建议**: 保持与项目其他文件一致的注释格式。

#### P3-2: `DoUDP.ForwardDNS` 重试间隔硬编码

**文件**: `control/dns.go:344`

```go
case <-time.After(1 * time.Second):
```

UDP 重试间隔固定为 1 秒，超时固定为 5 秒（L318）。在低延迟网络中，1 秒重试间隔过长；在高延迟网络中可能过于激进。这是既有代码，不是本次引入。

**建议**: 后续迭代可考虑指数退避或可配置的重试策略。

---

## Removal/Iteration Plan

I found **11 issues** (P0: **1**, P1: **3**, P2: **5**, P3: **2**).

### 1. 可立即删除
- `control/dns_control.go:635-637`: dead code（`if err != nil { return err }`），`err` 在此处一定为 nil。

## 2. Action now
0. MUST-FIX **Fix P0 + P1** — 修复并发竞争 + dead code + fallback 错误返回
1. **Go race detector 验证**: 在 CI 中增加 `go test -race ./control/...` 以检测 P0-1 所述的数据竞争。

### 2. 后续迭代建议
1. **DoUDP 并发安全修复** (P0-1): 优先修复 goroutine 与 `d.conn` 的竞争问题。
2. **dialSend context 传播** (P1-3): 将 `context.TODO()` 替换为调用链 context。
3. **forwarder 连接池化** (P2-1): 如果需要真正的连接复用，需重新设计 forwarder 生命周期。
4. **测试补充** (P2-5): 补充连接生命周期和集成测试。