# DNS Trace-Back 全覆盖修复开发任务书（执行版）

> 来源: `/Users/ouzy/Documents/DevProjects/dae/.plan/code_audit_trace-back.md`
> 分支: `dns_fix`
> 目标: 覆盖并关闭审计报告全部 5 条 finding（F1~F5）

## 0. 执行原则
1. 先根因后修复：先对照代码链路确认 F1~F5 根因，再改动。
2. 任务串行执行：Tn 未落地不进入 Tn+1。
3. 每个任务必须有“代码变更 + 可验证证据 + 记录”。
4. 若本机受平台限制无法完整跑测，必须记录限制与替代验证方式。

## 1. Finding 覆盖矩阵

| Finding | 位置 | 根因 | 对应任务 | 状态 |
|---|---|---|---|---|
| F1 | `control/control_plane.go:824` | DNS 分类在 `EmitTask` 内部，入口仍受 per-src 串行队列影响 | T1 | ✅ |
| F2 | `control/control_plane.go:865` | 队列内 `dnsAsyncSem` 满时回退同步处理，重新引入阻塞 | T2 | ✅ |
| F3 | `control/dns_improvement_test.go:148` | 测试未执行 `handle_ -> dialSend` 调用链 | T3 | ✅ |
| F4 | `control/dns_improvement_test.go:173` | DNS bypass 测试自证，未覆盖生产 dispatch 决策 | T4 | ✅ |
| F5 | `control/dns_improvement_test.go:120` | 未使用测试桩残留 | T5 | ✅ |

## 2. 任务分解与落地

### T1: DNS 分流前置（修复 F1）

**变更文件**: `control/control_plane.go`

**实现**:
- 在 UDP 入口读取后先解析 `pktDst` (`control/control_plane.go:877`)。
- 对 DNS 端口（53/5353）在 `EmitTask` 之前走专用分流 (`control/control_plane.go:879`)。
- 非 DNS 才进入 `dispatchDnsOrQueue -> emitUdpTask`（最终走 `EmitTask`）。

**关键点**:
- DNS 不再进入 per-src 串行队列。

### T2: 移除“满载同步回退”，替换为 DNS 专用有界 lane（修复 F2）

**变更文件**: `control/control_plane.go`

**实现**:
- 删除 `dnsAsyncSem` 模型。
- 新增 DNS 专用任务结构与队列:
  - `dnsIngressTask` (`control/control_plane.go:54`)
  - `dnsIngressQueue` (`control/control_plane.go:75`)
  - `dnsIngressWorkerCount=256`, `dnsIngressQueueLength=2048` (`control/control_plane.go:48`)
- 新增固定 worker (`startDnsIngressWorkers`, `control/control_plane.go:778`)。
- 新增统一分流 helper (`dispatchDnsOrQueue`, `control/control_plane.go:766`)。
- lane 满时阻塞等待队列可用槽位（保留 backpressure），不再回退 per-src 同步执行。

### T3: context 传播测试改为真实调用链验证（修复 F3）

**变更文件**: `control/dns_control.go`, `control/dns_improvement_test.go`

**实现**:
- `DnsController` 新增内部 seam:
  - `dialSendInvoker` 字段 (`control/dns_control.go:76`)
  - `invokeDialSend` helper (`control/dns_control.go:431`)
- `NewDnsController` 默认将 `dialSendInvoker` 指向 `c.dialSend` (`control/dns_control.go:126`)。
- `handle_` 末尾改为调用 `invokeDialSend` (`control/dns_control.go:517`)。
- 新增测试 `TestHandle_PropagatesDeadlineContextToDialSend` (`control/dns_improvement_test.go:199`)：
  - 实际执行 `handle_`。
  - 用 invoker stub 捕获 `ctx`。
  - 断言 `ctx` 含 deadline 且在 `DnsNatTimeout` 窗口内。

### T4: DNS bypass 测试改为生产分流决策验证（修复 F4）

**变更文件**: `control/dns_improvement_test.go`

**实现**:
- 删除旧 `TestDnsTasksDoNotBlockTaskQueue`（自证式测试）。
- 新增 3 个分流测试：
  - `TestUdpIngressDispatch_DnsBypassesTaskQueue` (`control/dns_improvement_test.go:241`)
  - `TestUdpIngressDispatch_NonDnsUsesTaskQueue` (`control/dns_improvement_test.go:267`)
  - `TestUdpIngressDispatch_NoSyncFallbackWhenDnsLaneBusy` (`control/dns_improvement_test.go:293`)
- 验证点覆盖:
  - DNS -> 专用 lane
  - 非 DNS -> emit/queue 路径
  - lane 忙时不会走同步 fallback

### T5: 清理无用测试桩（修复 F5）

**变更文件**: `control/dns_improvement_test.go`

**实现**:
- 删除未使用的 `fakeDnsForwarder` 类型与方法。

## 3. 执行验证

### 已执行命令

```bash
gofmt -w control/control_plane.go control/dns_control.go control/dns_improvement_test.go

go test ./control -run 'TestHandle_PropagatesDeadlineContextToDialSend|TestUdpIngressDispatch' -count=1
# 失败: go.work 外部模块缺失（../cloudpan189-go）

GOWORK=off go test ./control -run 'TestHandle_PropagatesDeadlineContextToDialSend|TestUdpIngressDispatch' -count=1
# 失败: macOS 缺失 Linux netlink/IP_TRANSPARENT 常量

GOWORK=off GOOS=linux GOARCH=amd64 go test ./control -run 'TestHandle_PropagatesDeadlineContextToDialSend|TestUdpIngressDispatch' -count=1
# 失败: BPF 生成类型缺失（bpfObjects/bpfRoutingResult），需 CI Linux+BPF 生成链路
```

### 结论
- 代码层面: F1~F5 对应改动已全部落地。
- 本机自动化测试: 受 `go.work` 外部模块与 Linux/BPF 环境限制，无法在当前机器完成完整编译回归。
- CI 要求: 需在 Linux runner 执行包含 BPF 生成步骤的工作流完成最终验证。

## 4. 交付清单

1. `control/control_plane.go` — DNS 入口分流前置 + 专用有界 worker lane。
2. `control/dns_control.go` — `dialSendInvoker` seam + `invokeDialSend`。
3. `control/dns_improvement_test.go` — 调用链 context 测试与 dispatch 决策测试重构。
4. `/Users/ouzy/Documents/DevProjects/dae/.plan/code_audit_trace-back-dev.md` — 本执行文档。

## 5. 风险与后续

1. 新 lane 当前参数为常量（worker/queue）；后续可按压测结果参数化。
2. 本地无法完成 Linux/BPF 编译闭环，需以 CI 结果作为准入依据。
3. 若 CI 回归暴露吞吐波动，优先调整 `dnsIngressWorkerCount` 与 `dnsIngressQueueLength`。
