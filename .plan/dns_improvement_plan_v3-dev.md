# dae DNS 改进计划 v3 - 开发执行文档

> 基于 `.plan/dns_improvement_plan_v3.md` 复核代码后，保持 v3 原始优先级与技术路线不变；本文件仅做可执行拆解与验收约束。

## 0. 执行总则（强制）
1. 严格串行：Tn 未通过任务级测试，不进入 Tn+1。
2. 每个任务都必须包含：代码实现 + 任务级测试 + 测试记录。
3. 每个里程碑在全部任务完成后，执行一次回归测试。
4. 任一测试失败，先修复并重测，直至通过。

## 1. 任务分解

### T1（P0-1）修复 DoUDP context 传播与连接关闭一致性
- 变更文件：`control/dns.go`
- 变更点：
  - `DoUDP.ForwardDNS` 中 `context.WithTimeout(context.TODO(), timeout)` 改为基于入参 `ctx`。
  - 读写统一使用 `d.conn`，确保与 `Close()` 生命周期一致。
- 验收：关键代码路径命中检查通过。

### T2（P0-2）dialSend 失败路径 timeout 反馈闭环复核
- 变更文件：`control/dns_control.go`
- 变更点：
  - 保持 `isTimeoutError` + `timeoutExceedCallback` 在主路径与 fallback 路径生效。
  - 保持 dead code 不回归。
- 验收：单元测试 `TestIsTimeoutError*` 与关键路径扫描通过。

### T3（P1-1/P1-2）统一 HTTP/Stream context+deadline 语义复核
- 变更文件：`control/dns.go`
- 变更点：
  - 保持 `sendHttpDNS` 使用 `http.NewRequestWithContext`。
  - 保持 `sendStreamDNS` 基于 `ctx` 设置 deadline 并在 I/O 前后检查 `ctx.Err()`。
- 验收：单元测试 `TestSendStreamDNSRespectsContextCancelBeforeIO` 与代码扫描通过。

### T4（P1-3）`tcp+udp` 同查询 fallback 复核
- 变更文件：`control/dns_control.go`
- 变更点：
  - 保持 `tcpFallbackDialArgument` 仅在 `tcp+udp + UDP + timeout` 触发。
  - fallback 只执行一次，避免放大。
- 验收：单元测试 `TestTcpFallbackDialArgument` 与关键路径扫描通过。

### T5（P2-4）`ipversion_prefer` 改为“优先+条件补查”复核
- 变更文件：`control/dns_control.go`
- 变更点：
  - 保持 `Handle_` 先查首选族；仅在首查无有效 IP 时补查另一族。
- 验收：控制流扫描通过（不回退到固定并发双查）。

### T6（P2-5）`dnsForwarderCache` 增加淘汰策略
- 变更文件：`control/dns_control.go`
- 变更点：
  - 新增 forwarder cache 上限（LRU 近似：按 last-use 时间淘汰最旧项）。
  - 淘汰时关闭被移除 forwarder，防止资源悬挂。
- 验收：新增单元测试覆盖淘汰行为并通过。

## 2. 里程碑回归
- 命令：
  - `go test ./control -run 'Test(IsTimeoutError|TcpFallbackDialArgument|SendStreamDNSRespectsContextCancelBeforeIO|EvictDnsForwarderCacheOneLocked)' -count=1`
  - `go test ./control -run TestIsTimeoutErrorWrappedDeadline -count=1`
- 通过标准：全部 PASS。
- 若受环境限制（依赖下载等）无法执行，需在 `.plan/test-log.md` 明确记录命令、失败原因和影响范围。
