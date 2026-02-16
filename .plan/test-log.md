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

## T1（DoUDP context 传播与连接一致性）
- 命令：`rg -n "context.WithTimeout\(ctx, timeout\)|d\.conn\.Write\(|d\.conn\.Read\(" control/dns.go`
- 结果：命中 `DoUDP.ForwardDNS` 的 `context.WithTimeout(ctx, timeout)`，以及统一 `d.conn` 读写。
- 结论：通过（父级 context 可传播，连接生命周期与 `Close()` 一致）。

## T2（dialSend timeout 反馈闭环复核）
- 命令：`go test ./control -run 'TestIsTimeoutError|TestIsTimeoutErrorWrappedDeadline' -count=1`
- 结果：失败（环境限制），`proxy.golang.org` 拉取 `github.com/daeuniverse/outbound` 返回 403 Forbidden。
- 结论：自动化单测受限，改用静态路径校验。
- 命令：`rg -n "timeoutExceedCallback\(dialArgument|timeoutExceedCallback\(fallbackDialArgument|func isTimeoutError" control/dns_control.go`
- 结果：命中主路径 + fallback 路径 timeout 回调与超时识别函数。
- 结论：通过（失败路径健康反馈未回归）。

## T3（HTTP/Stream context+deadline 语义复核）
- 命令：`rg -n "NewRequestWithContext|func sendStreamDNS\(ctx|ctx\.Err\(\)|SetDeadline" control/dns.go`
- 结果：命中 `NewRequestWithContext`、`sendStreamDNS(ctx,...)`、`SetDeadline` 与多处 `ctx.Err()` 检查。
- 结论：通过（取消/超时语义可传递到 I/O 层）。

## T4（tcp+udp 同查询 fallback 复核）
- 命令：`rg -n "func tcpFallbackDialArgument|upstream\.Scheme != dns\.UpstreamScheme_TCP_UDP|dialArgument\.l4proto != consts\.L4ProtoStr_UDP|!isTimeoutError\(err\)" control/dns_control.go`
- 结果：命中 fallback 触发条件约束（仅 tcp+udp + UDP + timeout）。
- 结论：通过（一次性 fallback 约束保持有效）。

## T5（ipversion_prefer 优先+条件补查复核）
- 命令：`rg -n "Query preferred qtype first|cache2 == nil \|\| !cache2\.IncludeAnyIp\(\)|handle_\(dnsMessage2, req, false\)" control/dns_control.go`
- 结果：命中“先查首选，再在无有效 IP 时补查另一族”的控制流。
- 结论：通过（未回退到固定并发双查）。

## T6（dnsForwarderCache 淘汰策略）
- 命令：`rg -n "maxDnsForwarderCacheSize|dnsForwarderLastUse|evictDnsForwarderCacheOneLocked|delete\(c\.dnsForwarderCache" control/dns_control.go`
- 结果：命中缓存上限、last-use 记录、最旧项淘汰及删除逻辑。
- 结论：通过（缓存具备容量上限和回收路径）。

## 里程碑回归（v3）
- 命令：`go test ./control -run 'Test(IsTimeoutError|TcpFallbackDialArgument|SendStreamDNSRespectsContextCancelBeforeIO|EvictDnsForwarderCacheOneLocked)' -count=1`
- 结果：失败（环境限制），`proxy.golang.org` 拉取私有/受限依赖 `github.com/daeuniverse/outbound` 返回 403 Forbidden。
- 结论：在当前环境无法完成自动化回归编译；已保留任务级静态校验记录。
