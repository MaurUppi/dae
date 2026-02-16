# dae DNS 改进代码审计报告 - 开发执行文档

> 来源：`.plan/code_audit_report.md`
> 目标：按 `Removal/Iteration Plan` 严格串行落实变更、验证与记录。

## 0. 执行总则（强制）
1. 所有任务严格串行执行：`Tn` 未测试通过，不开始 `Tn+1`。
2. 每个任务必须包含：代码实现、任务级测试、测试记录。
3. 每个里程碑必须在全部任务通过后执行一次回归测试。
4. 任一测试失败，先修复并重测，直至通过。

## 1. 任务拆解（对应 Removal/Iteration Plan）

### T1：删除 dead code（P1-1）
- 目标：删除 `control/dns_control.go` 中无效分支 `if err != nil { return err }`。
- 影响：仅清理控制流，不改变业务行为。
- 验收：代码扫描确认该 dead code 不存在。

### T2：修复 DoUDP 并发竞争（P0-1）
- 目标：`DoUDP.ForwardDNS` 中 goroutine 与读取路径不再共享可变 `d.conn` 引用。
- 实施：使用局部连接变量进行读写，避免复用实例时写错连接；重试计时改为 ticker。
- 验收：代码扫描确认 goroutine/read 均使用局部连接变量。

### T3：修复 fallback 错误返回语义（P1-2）
- 目标：TCP fallback forwarder 创建失败时返回 `fallbackErr` 包装错误，而非原始 UDP 超时错误。
- 验收：代码扫描确认返回错误包含 fallback 创建失败信息与原始错误上下文。

### T4：dialSend context 传播（P1-3）
- 目标：`dialSend` 不再使用 `context.TODO()`，改为接收上层 context 并在递归路径透传。
- 验收：代码扫描确认 `context.WithTimeout(ctx, ...)`，且递归调用透传 `ctx`。

### T5：CI 增加 race detector 检查
- 目标：新增工作流执行 `go test -race ./control/...`。
- 验收：工作流文件存在且命令准确。

## 2. 里程碑回归
- 命令：
  - `go test ./control -run 'Test(IsTimeoutError|TcpFallbackDialArgument|SendStreamDNSRespectsContextCancelBeforeIO|EvictDnsForwarderCacheOneLocked)' -count=1`
  - `go test -race ./control/...`
- 说明：如受依赖拉取限制，需记录失败原因与影响范围到 `.plan/test-log.md`。
