# DNS 改进测试记录

## T1（UDP 连接回收）
- 命令：`rg -n "d\.conn = conn|d\.conn = nil" control/dns.go`
- 结果：命中 `DoUDP.ForwardDNS` 的 `d.conn = conn` 与 `DoUDP.Close` 的 `d.conn = nil`。
- 结论：通过（实现与预期一致）。

## T2（超时反馈闭环）
- 命令：`rg -n "timeoutExceedCallback|isTimeoutError\(" control/dns_control.go`
- 结果：命中 `dialSend` 失败路径回调上报，以及 `isTimeoutError` 超时识别函数。
- 结论：通过（失败可反馈到健康度系统）。

## T3（tcp+udp 同查询 fallback）
- 命令：`rg -n "tcpFallbackDialArgument|fallbackForwarder" control/dns_control.go`
- 结果：命中 UDP 失败后 TCP fallback 逻辑及一次性 fallback 执行路径。
- 结论：通过（具备同查询协议兜底能力）。

## T4（上下文/超时语义统一）
- 命令：`rg -n "NewRequestWithContext|sendHttpDNS\(|sendStreamDNS\(ctx" control/dns.go`
- 结果：DoH 使用 `http.NewRequestWithContext`；stream DNS 调用与实现均带 `ctx`。
- 结论：通过（超时/取消语义已向协议层传递）。

## T5（ipversion_prefer 条件补查）
- 命令：`rg -n "Query preferred qtype first|handle_\(dnsMessage2|done := make\(chan" control/dns_control.go`
- 结果：命中“先查首选再条件补查”路径；未再出现旧版并发双查 `done` channel 逻辑。
- 结论：通过（请求放大被抑制）。

## 里程碑回归（代码级）
- 命令：`go test ./control -run 'Test(IsTimeoutError|TcpFallbackDialArgument|SendStreamDNSRespectsContextCancelBeforeIO)' -count=1`
- 结果：失败，原因是环境无法从 `proxy.golang.org` 拉取依赖（`github.com/daeuniverse/outbound` 403 Forbidden）。
- 结论：受环境限制，未完成自动化回归；本轮以静态实现校验作为替代。
