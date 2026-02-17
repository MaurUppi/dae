# DNS 性能修复开发计划 (dns-perf-fix)

**基于**: `.plan/dns_perf_rootcause.md`
**分支**: `dns_fix`
**目标**: 将 DNS 并发 200 的成功率从 ~66% / 15s 提升至 ~100% / <2s

---

## 执行总则

1. 所有任务**严格串行**：Tn 未通过，不开始 Tn+1
2. 每个任务必须：代码实现 + 任务级测试 + 测试记录
3. 每个里程碑（M1/M2）全部任务通过后，执行里程碑回归测试
4. 任一测试失败：立即停止，修复重测，直至通过

---

## 里程碑 M1 — 正确性修复 (P0 + P1)

### T1: 删除 dnsForwarderCache（P0-1）

**文件**: `control/dns_control.go`
**问题**: 缓存已关闭的 DnsForwarder 对象；下次命中缓存即使用死连接

**变更**:
1. 删除 `DnsController` 结构体中的 `dnsForwarderCacheMu`, `dnsForwarderCache`, `dnsForwarderLastUse` 字段
2. 删除常量 `maxDnsForwarderCacheSize = 128`（仅在 evict 函数中使用）
3. 删除 `evictDnsForwarderCacheOneLocked()` 方法
4. 删除 `dnsForwarderKey` 类型（仅用于缓存 key）
5. 删除构造函数中对这三个字段的初始化
6. 改写 `dialSend()` 中的缓存逻辑 → 直接 `newDnsForwarder()` + `defer forwarder.Close()`
7. 删除 `var connClosed bool` 变量及相关的 `defer` 和 `connClosed = true` 赋值

**修改后 dialSend 关键代码**:
```go
forwarder, err := newDnsForwarder(upstream, *dialArgument)
if err != nil {
    return err
}
defer forwarder.Close()

respMsg, err = forwarder.ForwardDNS(ctxDial, data)
// ... 错误处理 / fallback 不变
```

**测试**:
- 更新 `TestEvictDnsForwarderCacheOneLocked` → 改为 `TestDialSendCreatesNewForwarder`，验证每次 dialSend 都创建新 forwarder
- 运行 `go test -race -v -run 'TestIsTimeoutError|TestTcpFallback|TestEvict|TestSendStream|TestDialSend' $(go list ./control/... | grep -v kern/tests)`
- 预期: PASS, 无 DATA RACE

---

### T2: DNS 请求绕过 per-src 串行队列（P1-1 + P2-2）

**文件**: `control/control_plane.go`
**问题**:
- DNS 请求在 per-src-IP 串行队列中顺序处理，同源 IP 的 200 个请求排队
- `UdpTaskQueueLength=128` 溢出时静默丢弃，200 并发 → 72 个请求丢失

**变更**:
在 `control_plane.go` 的 UDP 读循环中，对 DNS 包（`isDns == true`）改为 `go` goroutine 直接处理，不经过 `EmitTask`：

```go
// 在 EmitTask 的 task 函数内部，handlePkt 返回 dnsController.Handle_() 之前
// handlePkt 已经区分 isDns，直接调用 dnsController.Handle_()
// 因此只需在 control_plane.go 中识别 DNS 包并 go handlePkt 即可
```

**实现策略**: 由于 `handlePkt` 在 task 内部才能解析 DNS，最简单的方案是：

**方案**: 在 `EmitTask` 的 lambda 中，先快速检查 port == 53 / isDns，若是 DNS 则 `go c.handlePkt(...)` 而非在当前 queue goroutine 中同步处理。

```go
DefaultUdpTaskPool.EmitTask(convergeSrc.String(), func() {
    // ... setup ...
    if pktDst.Port() == 53 || pktDst.Port() == 5353 {
        // DNS: do not block the task queue, handle concurrently
        go func() {
            if e := c.handlePkt(...); e != nil {
                c.log.Warnln("handlePkt(dns):", e)
            }
        }()
        return
    }
    if e := c.handlePkt(...); e != nil {
        c.log.Warnln("handlePkt:", e)
    }
})
```

注意：`RetrieveOriginalDest` 需要在 goroutine 外调用（已在 task 内），所以 `pktDst` 需要先解析再判断。

**测试**:
- 新增 `TestUdpTaskPoolDNSBypass` 单元测试：构造 100 个并发 DNS 任务（模拟同一 src IP），验证全部执行而非被丢弃
- 运行 `go test -race -v -run 'TestUdpTask' $(go list ./control/... | grep -v kern/tests)`
- 预期: PASS, 无 DATA RACE

---

### T3: 传播 context（带超时）从 handle_() 到 dialSend（P1-3）

**文件**: `control/dns_control.go`
**问题**: `handle_()` 传递 `context.Background()` 给 `dialSend()`，导致：
1. 请求无法被外部取消
2. 200 个并发请求各持有独立的不可取消 8s timeout，累积资源消耗

**变更**:
在 `handle_()` 中，为 `dialSend` 调用添加超时 context：

```go
// handle_() 末尾，替换原 dialSend 调用
dialCtx, dialCancel := context.WithTimeout(context.Background(), DnsNatTimeout)
defer dialCancel()
return c.dialSend(dialCtx, 0, req, data, dnsMessage.Id, upstream, needResp)
```

`DnsNatTimeout = 17s` 是当前 DNS 请求的最长生命周期，作为 dialSend 的外层 deadline 合适。`dialSend` 内部再用 `context.WithTimeout(ctx, DefaultDialTimeout=8s)` 作为上游连接超时，这是正确的嵌套关系。

**测试**:
- 新增 `TestHandle_ContextPropagatesToDialSend`：验证当 ctx 带短超时时，dialSend 能感知并提前返回
- 运行相关测试

---

### T4: AnyfromPool — 将 socket 创建移出全局写锁（P1-4）

**文件**: `control/anyfrom_pool.go`
**问题**: `ListenPacket` 在持有全局 write lock 期间执行，高并发响应串行化

**变更**:
"先创建，再锁定写入，若竞争则关闭多余的" 模式（optimistic create）：

```go
func (p *AnyfromPool) GetOrCreate(lAddr string, ttl time.Duration) (conn *Anyfrom, isNew bool, err error) {
    p.mu.RLock()
    af, ok := p.pool[lAddr]
    if ok {
        af.RefreshTtl()
        p.mu.RUnlock()
        return af, false, nil
    }
    p.mu.RUnlock()

    // Create socket OUTSIDE the lock (parallel creation is ok; we'll deduplicate)
    newAf, createErr := p.createAnyfrom(lAddr, ttl)
    if createErr != nil {
        return nil, true, createErr
    }

    p.mu.Lock()
    if af, ok = p.pool[lAddr]; ok {
        // Lost the race; close what we just created
        p.mu.Unlock()
        _ = newAf.UDPConn.Close()
        return af, false, nil
    }
    p.pool[lAddr] = newAf
    p.mu.Unlock()
    return newAf, true, nil
}
```

**注意**: 这会在竞争时多创建一个 socket 然后立即关闭，但消除了持锁 ListenPacket 的串行化。

**测试**:
- 并发调用 `GetOrCreate` 相同地址 N 次，验证只有一个 socket 存活，无 data race
- `go test -race -v -run 'TestAnyfromPool' $(go list ./control/... | grep -v kern/tests)`

---

### Milestone M1 回归测试

```bash
go test -race -v -run '.' $(go list ./control/... | grep -v 'control/kern/tests')
```

预期: 所有测试 PASS，`ok github.com/daeuniverse/dae/control`, 无 DATA RACE

---

## 里程碑 M2 — 测试覆盖补全

### T5: 为删除的 evictDnsForwarderCacheOneLocked 补充替代测试

**变更**: T1 删除了 `evictDnsForwarderCacheOneLocked`，相关测试也需同步删除/替换。
新增 `TestNewForwarderCreatedEachCall` 验证每次 `dialSend` 都是新建对象（通过 mock forwarder 工厂计数）。

### T6: UdpTaskPool — 验证 DNS 不阻塞非 DNS 任务

验证 DNS 任务绕过队列后，同一 src IP 的后续非 DNS 包仍然按序处理。

---

## 文件变更清单

| 文件 | 变更类型 | 任务 |
|------|----------|------|
| `control/dns_control.go` | 删除缓存字段/方法，改写 dialSend，修复 ctx 传播 | T1, T3 |
| `control/control_plane.go` | DNS 包 go-dispatch | T2 |
| `control/anyfrom_pool.go` | optimistic socket creation | T4 |
| `control/dns_improvement_test.go` | 删除/替换旧 evict 测试，新增 T1/T3/T4 测试 | T1,T3,T4 |

---

## 预期指标（修复后）

| 指标 | 修复前 | 修复后预期 |
|------|--------|-----------|
| 成功率 (concurrency=200) | ~66% | ~100% |
| 响应时间/round | ~15s | <500ms（缓存命中）/ <2s（上游正常）|
| DATA RACE | 0（已验证） | 0 |
| 队列溢出丢包 | 72/200 | 0 |

---

*创建时间: 2026-02-17*
