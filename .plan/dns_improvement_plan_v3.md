# dae DNS 性能改进计划 - 代码分析与实施方案

## Context

dae 的 DNS 模块在压力测试中表现远逊于 mosDNS：成功率仅 60%（mosDNS 100%），中位延迟 58ms（mosDNS 39ms），总失败 799 次（mosDNS 64 次）。dae 同时存在**解析超时**（66.5%）和**连接超时**（33.5%）两类故障，而 mosDNS 仅有少量解析超时。

通过深入代码分析，我**完全同意**改进计划 v2 的根因诊断和优先级排序，并在此基础上补充了具体的实现细节和额外发现。

---

## 代码分析结果：确认的问题

### P0-1: DoUDP 连接泄漏 (确认 - 最关键)

**文件**: `control/dns.go:300-368`

`DoUDP.ForwardDNS` 创建了局部变量 `conn`（L308），在整个方法中使用该局部变量进行读写（L325, L352），但**从未赋值给 `d.conn`**。而 `Close()` 方法（L363-368）只关闭 `d.conn`，因此实际上是空操作。

对比其他 forwarder：
| Forwarder | d.conn 赋值 | Close() 生效 |
|-----------|-------------|-------------|
| DoUDP     | **缺失** ❌  | 空操作 ❌    |
| DoTCP     | L289 ✅      | 正常 ✅      |
| DoTLS     | L260 ✅      | 正常 ✅      |
| DoH       | 用 http.Client | 设计如此 ✅ |
| DoQ       | L174/184 ✅  | 设计如此 ✅  |

**额外发现**: DoUDP 内部用 `context.WithTimeout(context.TODO(), timeout)`（L319）而非传入的 `ctx`，导致父级 context 取消无法传播。

### P0-2: dialSend 失败路径未调用 timeoutExceedCallback (确认)

**文件**: `control/dns_control.go:603-605`

```go
respMsg, err = forwarder.ForwardDNS(ctxDial, data)
if err != nil {
    return err  // 直接返回，未调用 c.timeoutExceedCallback
}
```

`timeoutExceedCallback` 已正确注入（L120），其实现（`control_plane.go:455-461`）会调用 `ReportUnavailable` 标记坏路径。但 dialSend 失败时从未触发，导致坏路径持续被选中。

注意：`networkType` 变量已在 L564-568 创建但未被使用于错误报告。

### P1-1: sendHttpDNS 缺少 context (确认)

**文件**: `control/dns.go:387`

使用 `http.NewRequest` 而非 `http.NewRequestWithContext`。且函数签名不接受 `ctx` 参数，上层传入的 `ctxDial`（8s 超时）无法传递到 HTTP 请求。

### P1-2: sendStreamDNS 无 deadline/context (确认)

**文件**: `control/dns.go:409-442`

函数签名只接受 `io.ReadWriter`，无 context 参数。Write/ReadFull 操作（L415, L421, L434）无 deadline 设置，在上游卡顿时可能无限阻塞。

### P2: ipversion_prefer 固定双查 (确认)

**文件**: `control/dns_control.go:390-410`

启用 ipversion_prefer 时，每个 A/AAAA 查询都会并发触发对方类型查询，压测下请求量翻倍。

---

## 补充发现（计划 v2 未提及）

### 补充-1: DoUDP 重试发包设计存在风险

**文件**: `control/dns.go:322-346`

DoUDP 启动 goroutine 每秒重发 DNS 请求，直到收到响应或 5s 超时。这意味着：
- 单次查询最多发送 5 个 UDP 包
- 压测下可放大上游流量 5 倍
- 当 forwarder 被缓存复用时，旧的重发 goroutine 可能与新查询并发

### 补充-2: dnsForwarderCache 无淘汰机制

**文件**: `control/dns_control.go:580-591`

forwarder 按 `(upstream, dialArgument)` 缓存，但无 TTL/LRU/大小限制。当 dialArgument 频繁变化（如 dialer 切换），缓存会无限增长。

### 补充-3: dialSend 中 dead code

**文件**: `control/dns_control.go:599-601`

```go
if err != nil {
    return err
}
```

这段代码在 `newDnsForwarder` 错误已在 L585-588 处理后，检查的是同一个 `err`，此时 `err` 一定为 nil（否则已经 return 了），属于 dead code。

---

## 实施方案

### Phase 1: P0 - 立即止血 (1 个迭代)

#### 1.1 修复 DoUDP 连接泄漏
**文件**: `control/dns.go`

修改 `DoUDP.ForwardDNS`：
- 在 dial 成功后赋值 `d.conn = conn`
- 使用 `d.conn` 替代局部 `conn` 进行读写
- `Close()` 中关闭后置 `d.conn = nil`（幂等）
- 将 L319 的 `context.TODO()` 改为传入的 `ctx`

#### 1.2 dialSend 失败路径接入超时反馈
**文件**: `control/dns_control.go`

在 `ForwardDNS` 错误返回前（L604-605 之间）：
- 检测 timeout 类错误（`errors.Is(err, context.DeadlineExceeded)` 或 `net.Error.Timeout()`）
- 调用 `c.timeoutExceedCallback(dialArgument, err)`
- 移除 dead code（L599-601）

### Phase 2: P1 - 成功率提升 (1-2 个迭代)

#### 2.1 tcp+udp 同查询 fallback
**文件**: `control/dns_control.go` 的 `dialSend`

当 upstream scheme 为 `tcp+udp` 且当前 l4proto 为 UDP 时：
- 设置 UDP 短预算（如 1.5s）
- UDP 超时或可重试错误后，自动切换 TCP forwarder 重试一次
- 仅 retry 一次，避免放大

#### 2.2 统一 context/timeout 语义
**文件**: `control/dns.go`

- `sendHttpDNS`: 增加 `ctx` 参数，改用 `http.NewRequestWithContext(ctx, ...)`
- `sendStreamDNS`: 增加 `ctx` 参数，在 Write/ReadFull 前通过 `conn.SetDeadline` 设置 deadline（需要上层传入 `net.Conn` 或实现 deadline 接口）
- `DoH.ForwardDNS`: 将 `ctx` 透传到 `sendHttpDNS`
- `DoUDP.ForwardDNS`: 已在 1.1 中修复 context 传递

### Phase 3: P2 - 延迟与弹性优化 (2-3 个迭代)

#### 3.1 优化 ipversion_prefer 为"优先+条件补查"
**文件**: `control/dns_control.go` 的 `Handle_`

- 默认先查 prefer qtype
- 仅在首查结果为空/失败/无 IP 时补查另一族
- 减少压测下的请求放大

#### 3.2 dnsForwarderCache 增加淘汰策略
**文件**: `control/dns_control.go`

- 增加缓存大小上限或 TTL
- 定期清理不活跃的 forwarder

---

## 关键文件清单

| 文件 | 修改内容 |
|------|---------|
| `control/dns.go` | DoUDP 连接修复、sendHttpDNS/sendStreamDNS context 支持 |
| `control/dns_control.go` | dialSend 超时反馈、tcp+udp fallback、ipversion_prefer 优化 |
| `control/dns_cache.go` | 可能需要配合缓存调整 |
| `component/dns/upstream.go` | SupportedNetworks() 参考（不需修改） |

## 验证方案

1. **单元测试**: 为 DoUDP 连接生命周期、timeout callback 触发编写单测
2. **压力测试复现**: 使用与 baseline 相同的测试条件（2000 请求，100 轮，每轮 20 次）对比修复前后
3. **协议覆盖**: 分别测试 `udp`、`tcp`、`tcp+udp`、`tls`、`https`、`quic`、`h3` 协议
4. **网络扰动**: 正常、10% 丢包、仅 UDP 阻断、仅 TCP 阻断
5. **验收标准**: 成功率 >95%，连接超时占比接近 0，P50 接近 39ms
