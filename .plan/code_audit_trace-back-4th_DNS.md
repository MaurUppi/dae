# DNS 相关修复实施计划

> 分支: `dns_fix`
> 来源: `code_audit_trace-back-4th.md` 优先级 1（DNS 相关）
> 修复原则: 优先在 dns_fix 新引入的代码上改进

## 0. 执行策略

### 执行总则（强制）

1. **严格串行**: `Tn` 未测试通过，不允许开始 `Tn+1`
2. **三件套**: 每个任务的代码实现 + 任务级测试 + 测试记录，全部记入 `.plan/test-log.md`
3. **里程碑回归**: 全部任务通过后执行回归测试
4. **失败即停**: 任一测试失败立即停止，修复重测后才继续

### 背景

dns_fix 分支修复了 Scenario C（EPIPE 后继续写入）的 bug，但引入了 CLOSE-WAIT socket 堆积回归（max 从 7 增长到 111）。根因是每个 DNS 请求创建新 `DnsForwarder` + `defer Close()`，而 `Close()` 对底层 TCP 连接的释放可能不彻底。

同时，`enqueueDnsIngressTask` 已在 PR#9 中改为非阻塞（有 `default` 分支），F7 的核心修复已完成。但 handlePkt 错误日志无节流问题仍然通过 DNS worker 路径影响 DNS 功能。

## T1: 调查 forwarder.Close() → 底层 TCP 连接关闭路径

**目标**: 确定 CLOSE-WAIT 堆积的精确根因

**调查步骤**:

1. 追踪 `DoTCP.Close()` (`control/dns.go:322-326`):
   ```go
   func (d *DoTCP) Close() error {
       if d.conn != nil {
           return d.conn.Close()  // d.conn 是 netproxy.Conn
       }
       return nil
   }
   ```
   `d.conn` 来自 `d.dialArgument.bestDialer.DialContext()` (L309)。需要确认：
   - 当 `bestDialer` 是 direct dialer 时，`DialContext()` 返回的 `netproxy.Conn` 的 `Close()` 是否调用 `net.Conn.Close()` → `close()` 系统调用？
   - 当 `bestDialer` 是 proxy dialer（vmess/trojan/ss through IEPL）时，`DialContext()` 返回的连接是否来自连接池？`Close()` 是否归还到池而非真正关闭？

2. 检查 `github.com/daeuniverse/outbound` 库中 proxy dialer 的 `DialContext` 实现：
   - 搜索 `go.sum` 或 `go.mod` 中 `outbound` 的版本
   - 在 Go module cache 中查看 proxy 协议实现的 `Close()` 方法
   - 特别关注是否有 connection pool / multiplexing

3. 对比 `DoTCP.ForwardDNS()` (L308-319) 中 `d.conn = conn` 的赋值时机：
   - 如果 `ForwardDNS` 返回错误（如 broken pipe），`d.conn` 仍然被赋值，`defer Close()` 仍然执行
   - 但如果 `DialContext` 失败，`d.conn` 为 nil，`Close()` 是 no-op

**关键文件**:
- `control/dns.go:308-327` (DoTCP.ForwardDNS + Close)
- `control/dns_control.go:590-606` (dialSend 中的 forwarder 生命周期)
- `go.mod` (outbound 库版本)
- Go module cache: `~/go/pkg/mod/github.com/daeuniverse/outbound@.../` (proxy 实现)

**交付物**: 调查报告，记入 `.plan/test-log.md`，包含：
- `Close()` 是否真正触发 TCP socket close 的结论
- 如果是连接池问题，具体哪个库/哪个函数
- CLOSE-WAIT 堆积的精确机制

## T2: 修复 CLOSE-WAIT 堆积（针对 F6）

**前置**: T1 调查结果确定根因后，选择对应修复方案。

### 方案 A（如果 Close() 不触发真正关闭 — 连接池问题）

在 `dialSend()` 中，`forwarder.Close()` 之后显式关闭底层 TCP 连接：

**修改文件**: `control/dns_control.go`

```go
// L590-594 改为:
forwarder, err := newDnsForwarder(upstream, *dialArgument)
if err != nil {
    return err
}
defer func() {
    if err := forwarder.Close(); err != nil {
        c.log.Debugf("forwarder.Close error: %v", err)
    }
}()
```

如果 `forwarder.Close()` 只是归还到池，需要在 forwarder 的 `Close()` 方法中确保底层 TCP socket 被真正关闭。这可能需要修改 `DoTCP.Close()`:

```go
func (d *DoTCP) Close() error {
    if d.conn != nil {
        err := d.conn.Close()
        d.conn = nil  // 确保不被二次关闭
        return err
    }
    return nil
}
```

或者，如果底层是 `netproxy.Conn` 包装了连接池，需要获取裸 `net.Conn` 并调用 `Close()`。

### 方案 B（如果 Close() 确实关闭但 GC 延迟导致 fd 不及时释放）

在 `dialSend()` 中立即 `Close()` 而非依赖 `defer`：

**修改文件**: `control/dns_control.go`

```go
// L590-620 重构: 将 forwarder 的生命周期限制在最小范围
forwarder, err := newDnsForwarder(upstream, *dialArgument)
if err != nil {
    return err
}
respMsg, err = forwarder.ForwardDNS(ctxDial, data)
forwarder.Close()  // 立即关闭，不等 defer
if err != nil {
    // ... fallback 逻辑
}
```

注意: fallback 路径 (L601-606) 也创建了 `fallbackForwarder`，同样需要立即 Close。

### 方案 C（如果 CLOSE-WAIT 来自非 DNS 代理路径而非 DNS forwarder）

需要 T1 排除此可能性。triage 数据中 CLOSE-WAIT 的 peer 是 `163.177.58.13:11108`（IEPL 节点），而 DNS upstream 走 direct 到 `192.168.1.8:5553`。**如果 CLOSE-WAIT 连接的 remote 地址是 IEPL 节点，说明 CLOSE-WAIT 来自非 DNS 代理路径**，那么 F6 的修复归属应转移到 broken-pipe 分支。

**调查方法（T1 中执行）**:
```bash
# 在 dae 运行实例上检查 CLOSE-WAIT 连接的 remote 地址
ss -tnp state close-wait | grep dae
# 如果 remote 是 163.177.58.13 → 非 DNS 代理路径
# 如果 remote 是 192.168.1.8:5553 → DNS forwarder 路径
```

**关键文件**:
- `control/dns_control.go:570-620` (dialSend)
- `control/dns.go:301-327` (DoTCP)

**测试方法**:
1. 部署修复后运行 `dae_triage_unified_v5.sh --service dae --enable-tcpdump --enable-strace --peer-ip 163.177.58.13`
2. 持续采集 30 分钟
3. **成功标准**: `ss -tnp state close-wait | grep dae | wc -l` 持续 ≤10
4. **回归检查**: Scenario C 仍为 0

## T3: DNS worker 路径 handlePkt 错误日志节流

**目标**: 减少 DNS worker 路径的日志风暴（F4 的 DNS 部分）

**修改文件**: `control/control_plane.go`

**实现**:

在 `ControlPlane` struct 中新增 atomic 计数器（约 L102 附近）:
```go
// handlePktDnsErrTotal tracks DNS worker handlePkt errors for log throttling.
handlePktDnsErrTotal uint64
```

修改 L858-860:
```go
// 现有代码:
if e := c.handlePkt(udpConn, task.data, task.convergeSrc, task.pktDst, task.realDst, task.routingResult, false); e != nil {
    c.log.Warnln("handlePkt(dns):", e)
}

// 改为:
if e := c.handlePkt(udpConn, task.data, task.convergeSrc, task.pktDst, task.realDst, task.routingResult, false); e != nil {
    total := atomic.AddUint64(&c.handlePktDnsErrTotal, 1)
    if total == 1 || total%dnsIngressQueueLogEvery == 0 {
        c.log.WithFields(logrus.Fields{
            "total": total,
        }).Warnln("handlePkt(dns):", e)
    }
}
```

复用已有常量 `dnsIngressQueueLogEvery = 100` (L51)。

**测试方法**:
1. 触发 broken pipe 高峰期
2. 观察 `journalctl -u dae | grep "handlePkt(dns)" | wc -l` 一分钟内的行数
3. **成功标准**: 从 250 条/分钟降至 ≤5 条/分钟，日志包含 `total` 字段

**关键文件**:
- `control/control_plane.go:51` (常量)
- `control/control_plane.go:102` (struct 字段)
- `control/control_plane.go:858-860` (日志调用点)

## M1: 本地验证

```bash
gofmt -l ./control/
GOWORK=off GOOS=linux GOARCH=amd64 go vet ./control/
go test -race ./control/ -run TestDnsForwarder  # 如果有相关测试
```

## 任务依赖图

```
T1 (调查) → T2 (修复 CLOSE-WAIT)
                                    → M1 (验证)
T3 (日志节流，独立)                → M1 (验证)
```

## 交付清单

| 文件 | 改动 |
|---|---|
| `control/dns_control.go:590-620` | T2: forwarder 关闭方式改进 |
| `control/dns.go:322-327` | T2: DoTCP.Close() 可能需要增强 |
| `control/control_plane.go:102` | T3: 新增 `handlePktDnsErrTotal` 字段 |
| `control/control_plane.go:858-860` | T3: handlePkt(dns) 日志节流 |

## CI 要求

- `gofmt` 无差异
- `go vet` 通过
- `go test -race ./control/` 通过
- 编译成功 (GOOS=linux GOARCH=amd64)
