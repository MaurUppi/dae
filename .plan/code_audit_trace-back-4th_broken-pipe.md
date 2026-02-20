# 非 DNS 相关修复实施计划（Broken Pipe）

> 分支: `main` → 创建新分支 `broken-pipe-fix`
> 来源: `code_audit_trace-back-4th.md` 优先级 1（F6/S5 归属迁移后）
> 修复原则: 根因在 dae 原始代码，在 main 上创建分支修复

## 0. 执行策略

### 执行总则（强制）

1. **严格串行**: `Tn` 未测试通过，不允许开始 `Tn+1`
2. **三件套**: 每个任务的代码实现 + 任务级测试 + 测试记录，全部记入 `.plan/test-log.md`
3. **里程碑回归**: 全部任务通过后执行回归测试
4. **失败即停**: 任一测试失败立即停止，修复重测后才继续

### 背景

非 DNS 的 UDP 代理流量（routing 匹配 `fallback: HK`）通过 IEPL TCP 隧道转发。当 IEPL 节点主动关闭 TCP 连接（FIN）后，dae 仍持续向已断裂隧道写入，导致大量 broken pipe 错误。5 次 triage 采集共 183 个 Scenario A（FIN→RST）事件证实了此问题。

核心缺陷：
- `ue.WriteTo()` 失败后有重试（`goto getNew`, MaxRetry=2），但重试时 `dialerGroup.Select()` 仍可能选中同一个断裂节点
- broken pipe 信息未反馈到 dialer 健康模型
- 同一源端口最多反复报错 8 次

### F6/S5 归属迁移结论（2026-02-20）

依据 `.plan/test-log.md` `code_audit_trace-back-4th_DNS: T1`（L636-L689）：
- `DoTCP.Close()` 路径已确认会执行真实 `net.TCPConn.Close()`，非 DNS forwarder 关闭逻辑问题
- CLOSE-WAIT remote 实测为 `163.177.58.13:*`（IEPL 节点），不是 DNS upstream `192.168.1.8:5553`
- 因此 **F6**（CLOSE-WAIT 堆积）及其修复项 **S5** 归属 `main -> broken-pipe-fix`，不再归属 `dns_fix`

### 关键代码路径

```
handlePkt() (udp.go:64)
  L149: routingResult.Must > 0 → isDns=false
  L171: retry := 0
  L191: getNew: 标签
  L192: if retry > MaxRetry → 返回错误
  L201: ue, isNew, err := DefaultUdpEndpointPool.GetOrCreate(realSrc, ...)
  L266: if !isNew && !ue.Dialer.MustGetAlive(networkType) → Remove + retry（已有健康检查！）
  L285: _, err = ue.WriteTo(data, dialTarget)
  L286-303: if err → Debug log + Remove + retry++ + goto getNew
  L308-326: if isNew → print routing log
```

**已有的健康检查机制**（L266）: 如果 endpoint 不是新建的，且其 dialer `MustGetAlive()` 返回 false，则移除并重试。这意味着只要我们在 WriteTo 失败时将 dialer 标记为 not alive，下次重试时 L266 的检查就能避开它。

**已有的 `ReportUnavailable` API** (`component/outbound/dialer/connectivity_check.go:564`):
```go
func (d *Dialer) ReportUnavailable(typ *NetworkType, err error) {
    collection := d.mustGetCollection(typ)
    d.logUnavailable(collection, typ, err)      // Alive=false, append Timeout latency
    d.informDialerGroupUpdate(collection)        // 通知所有 AliveDialerSet 更新
}
```

调用 `ReportUnavailable` 后：
- `collection.Alive = false`
- `collection.Latencies10.AppendLatency(Timeout)`
- `AliveDialerSet.NotifyLatencyChange(d, alive=false)` → 从 `inorderedAliveDialerSet` 移除
- 后续 `dialerGroup.Select()` 不会选中该 dialer（除非是 FixedPolicy 或只有 1 个 dialer）
- 定时健康检查成功后自动恢复 `Alive=true`

## T1: broken pipe 后调用 ReportUnavailable 标记 dialer 不健康

**目标**: 解决 F1 和 F2 — broken pipe 后 dialer 应被标记为不健康，重试时避开

**修改文件**: `control/udp.go`

**实现**:

在 L285-303 的 WriteTo 失败处理中，增加 `ReportUnavailable` 调用：

```go
// 现有代码 (L285-303):
_, err = ue.WriteTo(data, dialTarget)
if err != nil {
    if c.log.IsLevelEnabled(logrus.DebugLevel) {
        c.log.WithFields(logrus.Fields{
            // ... debug fields ...
        }).Debugln("Failed to write UDP packet request. Try to remove old UDP endpoint and retry.")
    }
    _ = DefaultUdpEndpointPool.Remove(realSrc, ue)
    retry++
    goto getNew
}

// 改为:
_, err = ue.WriteTo(data, dialTarget)
if err != nil {
    if c.log.IsLevelEnabled(logrus.DebugLevel) {
        c.log.WithFields(logrus.Fields{
            // ... debug fields ...
        }).Debugln("Failed to write UDP packet request. Try to remove old UDP endpoint and retry.")
    }
    // 将 broken pipe / connection reset 等错误反馈到 dialer 健康状态
    ue.Dialer.ReportUnavailable(networkType, err)
    _ = DefaultUdpEndpointPool.Remove(realSrc, ue)
    retry++
    goto getNew
}
```

**注意事项**:
1. `ReportUnavailable` 对**所有**写入错误都调用（不仅限 broken pipe），因为 connection refused/timeout 等也说明 dialer 不可用
2. 这不需要 `isBrokenPipe()` helper — `ReportUnavailable` 接受任意 error
3. `networkType` 已在 L172-176 定义: `&dialer.NetworkType{L4Proto: "udp", IpVersion: ..., IsDns: false}`
4. 调用后 `Alive=false`，下次 `getNew` 时 L266 的 `!ue.Dialer.MustGetAlive(networkType)` 会生效（对于已有 endpoint）
5. 对于新建 endpoint（`isNew=true`），L266 检查不触发，但 `dialerGroup.Select()` 内部也会避开 not-alive dialer
6. **风险评估**: `ReportUnavailable` 会将 dialer 的 `Alive` 设为 false 并 append `Timeout` 延迟。如果仅一次偶发网络抖动就标记 dialer 为 not alive，可能导致流量不必要地切换。但考虑到：(a) 定时健康检查会快速恢复; (b) 当前的问题是**完全不反馈**导致 15 分钟持续写入断裂隧道，过度反馈远好于不反馈。

**关键文件**:
- `control/udp.go:285-303` (WriteTo 失败处理)
- `component/outbound/dialer/connectivity_check.go:564-568` (ReportUnavailable, 只读引用)
- `component/outbound/dialer/alive_dialer_set.go:144-204` (NotifyLatencyChange, 只读引用)

**测试方法**:
1. 部署修复后，运行 `dae_triage_unified_v5.sh --service dae --enable-tcpdump --enable-strace --peer-ip 163.177.58.13`
2. 等待自然 IEPL 断连（或手动关闭一个 IEPL 节点）
3. **预期**:
   - broken pipe 后日志显示 `[ALIVE → NOT ALIVE]`（来自 NotifyLatencyChange L186-189）
   - 重试时选择其他健康节点
   - 同一源端口的 broken pipe 次数 ≤2（MaxRetry 内）
4. **成功标准**:
   - triage 中同一源端口重复事件从 8 次降至 ≤2
   - IEPL 节点断连后恢复时间 ≈ check_interval（而非持续 15+ 分钟）
5. **回归检查**: 正常代理流量不受影响，健康 dialer 不被误标记

## T2: handlePkt 非 DNS 路径错误日志节流

**目标**: 解决 F4 — handlePkt 错误日志的日志风暴

**修改文件**: `control/control_plane.go`

**实现**:

1. 在 `ControlPlane` struct 中新增 atomic 计数器（约 L104 附近）:
```go
// handlePktErrTotal tracks non-DNS handlePkt errors for log throttling.
handlePktErrTotal uint64
```

2. 新增节流常量（L51 附近，与 `dnsIngressQueueLogEvery` 相邻）:
```go
const (
    dnsIngressQueueLogEvery = 100
    handlePktLogEvery       = 100  // 新增
)
```

3. 修改 L994（非 DNS 路径的 handlePkt 日志）:
```go
// 现有代码:
if e := c.handlePkt(udpConn, data, convergeSrc, common.ConvergeAddrPort(pktDst), common.ConvergeAddrPort(realDst), routingResult, false); e != nil {
    c.log.Warnln("handlePkt:", e)
}

// 改为:
if e := c.handlePkt(udpConn, data, convergeSrc, common.ConvergeAddrPort(pktDst), common.ConvergeAddrPort(realDst), routingResult, false); e != nil {
    total := atomic.AddUint64(&c.handlePktErrTotal, 1)
    if total == 1 || total%handlePktLogEvery == 0 {
        c.log.WithFields(logrus.Fields{
            "total": total,
        }).Warnln("handlePkt:", e)
    }
}
```

**注意**: `import "sync/atomic"` 已存在（`atomic.AddUint64` 在 L797 已使用），无需额外导入。

**关键文件**:
- `control/control_plane.go:51` (常量区域)
- `control/control_plane.go:~104` (struct 字段)
- `control/control_plane.go:994` (非 DNS 日志调用点)

**测试方法**:
1. 触发 broken pipe 高峰期
2. 观察 `journalctl -u dae | grep "handlePkt:" | wc -l` 一分钟内行数
3. **成功标准**: 从 250 条/分钟降至 ≤5 条/分钟，日志中包含 `total` 字段

## T3: sendPkt 对自身监听地址的特殊处理

**目标**: 解决 F3 — `sendPkt` 绑定 dae 自身 :53 端口失败

**修改文件**: `control/udp.go`

**实现**:

当前 `sendPkt` (L54-62):
```go
func sendPkt(log *logrus.Logger, data []byte, from netip.AddrPort, realTo, to netip.AddrPort, lConn *net.UDPConn) (err error) {
    uConn, _, err := DefaultAnyfromPool.GetOrCreate(from.String(), AnyfromTimeout)
    if err != nil {
        return
    }
    _, err = uConn.WriteToUDPAddrPort(data, realTo)
    return err
}
```

改为:
```go
func sendPkt(log *logrus.Logger, data []byte, from netip.AddrPort, realTo, to netip.AddrPort, lConn *net.UDPConn) (err error) {
    uConn, _, err := DefaultAnyfromPool.GetOrCreate(from.String(), AnyfromTimeout)
    if err != nil {
        // Fallback: if bind fails (e.g., address already in use when from == dae's own
        // DNS listen address), use the main UDP listener to send the response.
        if lConn != nil {
            _, err = lConn.WriteToUDPAddrPort(data, realTo)
            return err
        }
        return
    }
    _, err = uConn.WriteToUDPAddrPort(data, realTo)
    return err
}
```

**注意事项**:
1. fallback 使用 `lConn`（主 UDP listener）回写。源地址将是 dae 的监听地址（即 `from`），因为 `lConn` 绑定在该地址上
2. 需要确认 `lConn.WriteToUDPAddrPort` 是否需要 `SO_TRANSPARENT` 权限（`lConn` 已设置，应该可以）
3. 这是一个 graceful degradation：首选 AnyfromPool（精确源地址匹配），失败时 fallback 到主 listener

**关键文件**:
- `control/udp.go:54-62` (sendPkt)

**测试方法**:
1. 部署修复后，监控 `journalctl -u dae | grep "address already in use"` 30 分钟
2. **成功标准**: 30 分钟内零 bind 错误
3. **回归检查**: DNS 响应正常到达客户端（检查 `dig` 成功率不下降）

## T4: UdpEndpoint.start() 静默退出改进

**目标**: 解决 F5 — endpoint 失效时主动从池中清除（不等 NAT 超时）

**修改文件**: `control/udp_endpoint_pool.go`

**实现**:

当前 `start()` (L40-58):
```go
func (ue *UdpEndpoint) start() {
    buf := pool.GetFullCap(consts.EthernetMtu)
    defer pool.Put(buf)
    for {
        n, from, err := ue.conn.ReadFrom(buf[:])
        if err != nil {
            break
        }
        ue.mu.Lock()
        ue.deadlineTimer.Reset(ue.NatTimeout)
        ue.mu.Unlock()
        if err = ue.handler(buf[:n], from); err != nil {
            break
        }
    }
    ue.mu.Lock()
    ue.deadlineTimer.Stop()
    ue.mu.Unlock()
}
```

改为（通过 `Reset(0)` 触发立即清理）:
```go
func (ue *UdpEndpoint) start() {
    buf := pool.GetFullCap(consts.EthernetMtu)
    defer pool.Put(buf)
    for {
        n, from, err := ue.conn.ReadFrom(buf[:])
        if err != nil {
            break
        }
        ue.mu.Lock()
        ue.deadlineTimer.Reset(ue.NatTimeout)
        ue.mu.Unlock()
        if err = ue.handler(buf[:n], from); err != nil {
            break
        }
    }
    // Trigger immediate cleanup: Reset(0) fires the deadline timer callback
    // which calls pool.LoadAndDelete + ue.Close(), removing this endpoint
    // from the pool immediately instead of waiting for NatTimeout.
    ue.mu.Lock()
    if ue.deadlineTimer != nil {
        ue.deadlineTimer.Reset(0)
    }
    ue.mu.Unlock()
}
```

**原理**: deadline timer 的回调（在 `GetOrCreate` L155-160 中定义）会从池中移除 endpoint 并关闭连接：
```go
ue.deadlineTimer = time.AfterFunc(createOption.NatTimeout, func() {
    if _ue, ok := p.pool.LoadAndDelete(lAddr); ok {
        if _ue == ue {
            ue.Close()
        }
    }
})
```

`Reset(0)` 替代原来的 `Stop()` 会立即触发此回调，无需为 `start()` 额外引用 log 或 pool key。

**关键文件**:
- `control/udp_endpoint_pool.go:40-58` (start)
- `control/udp_endpoint_pool.go:146-160` (deadline timer 回调)

**测试方法**:
1. 部署后在 broken pipe 场景观察 endpoint 是否被立即清除
2. **成功标准**: endpoint 错误后立即从池中消失（不等 NatTimeout）
3. **回归检查**: 正常 UDP 流量不受影响

## T5（承接主报告 S5）: CLOSE-WAIT 堆积治理与验收

**目标**: 以 non-DNS 代理路径修复承接 F6/S5，验证 CLOSE-WAIT 显著下降。

**实施方式**:
1. 以 T1（`ReportUnavailable`）+ T4（endpoint 及时清理）作为 CLOSE-WAIT 治理主路径。
2. 不修改 dns_fix 的 `DoTCP.Close()`/`newDnsForwarder` 路径，避免误修复。
3. 将 CLOSE-WAIT 指标纳入 broken-pipe 分支验收门禁。

**测试方法**:
1. 部署 T1-T4 后运行 `dae_triage_unified_v5.sh --service dae --enable-tcpdump --enable-strace --peer-ip 163.177.58.13`
2. 采集期间执行 `ss -tnp state close-wait | grep dae`
3. **成功标准**:
   - CLOSE-WAIT max 从 111 降至 ≤10
   - CLOSE-WAIT remote 仍仅为 IEPL 节点地址（验证归属不漂移）
   - Scenario C 维持 0（不回退 dns_fix 已修复项）
4. 测试记录写入 `.plan/test-log.md`（标题建议：`code_audit_trace-back-4th_broken-pipe: T5 — F6/S5 迁移验收`）

## M1: 本地验证

```bash
gofmt -l ./control/ ./component/outbound/
GOWORK=off GOOS=linux GOARCH=amd64 go vet ./control/ ./component/outbound/...
go test -race ./control/ ./component/outbound/...
```

## 任务依赖图

```
T1 (dialer 健康反馈) ─┐
T2 (日志节流)         ├→ T5 (F6/S5 验收)
T3 (sendPkt fallback) ┤
T4 (endpoint 清理)   ─┘
                            ↓
                        M1 (总验证)
```

T1-T4 互不依赖，可并行开发但需串行测试。建议按 `T1→T2→T3→T4→T5` 顺序执行（T1 与 T5 影响最大）。

## 交付清单

| 文件 | 改动 | 任务 |
|---|---|---|
| `control/udp.go:285-303` | WriteTo 失败后调用 ReportUnavailable | T1 |
| `control/control_plane.go:~51` | 新增 `handlePktLogEvery` 常量 | T2 |
| `control/control_plane.go:~104` | 新增 `handlePktErrTotal` 字段 | T2 |
| `control/control_plane.go:994` | handlePkt 非 DNS 日志节流 | T2 |
| `control/udp.go:54-62` | sendPkt fallback 到 lConn | T3 |
| `control/udp_endpoint_pool.go:40-58` | start() 退出后立即触发清理 | T4 |
| `.plan/test-log.md` | 新增 F6/S5 迁移验收记录 | T5 |

## CI 要求

- `gofmt` 无差异
- `go vet` 通过
- `go test -race ./control/ ./component/outbound/...` 通过
- 编译成功 (GOOS=linux GOARCH=amd64)
