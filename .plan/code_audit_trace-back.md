# DNS 修复 Trace-Back 审查报告（`bc7e4642..27c7699`）

## Code Review Summary

- 审查范围：从 `bc7e4642` 到当前 `dns_fix` 分支 `27c7699`。
- 重点代码：`control/dns_control.go`、`control/dns.go`、`control/control_plane.go`、`control/anyfrom_pool.go`、`control/dns_improvement_test.go`、`control/packet_sniffer_pool_test.go`、`.github/workflows/dns-race.yml`。
- 需求链路已对齐：`dns_improvement_plan_v2* -> dns_improvement_plan_v3* -> code_audit_report* -> dns_perf_rootcause*`。
- 本地验证：`GOWORK=off go test ./control -run TestIsTimeoutError -count=1` 在当前 macOS 环境失败（Linux netlink/IP_TRANSPARENT 依赖），本次结论基于静态审查 + 现有测试/压测记录。

**Overall assessment**: **REQUEST_CHANGES**

---

## 三个问题结论（针对本次范围）

1. **解析成功率低**：**未修复（核心根因仍在）**
- 现象：你给出的复测仍约 `132~138 / 200`。
- 根因：DNS 仍然先进入 per-src 串行队列，再在队列任务里做异步分流，导致 ingress 阶段的同源拥塞未消除。

2. **延迟高**：**部分修复**
- 现象：每轮从约 `15.3s` 降到约 `10.3s`（约 33% 改善）。
- 解释：队列内异步化减少了单 task 执行时间，但未消除“先排队再分流”的结构性等待。

3. **运行一段时间后 DNS 无响应**：**部分修复，仍有阻塞回退路径**
- 已修复：DoH/DoQ 清理、DNS 异步并发上限（防止无限 goroutine 增长）。
- 未闭环：并发闸门打满时会回退到队列内同步处理，重新触发串行阻塞链路，长跑场景仍可能表现为“无响应”。

---

## Findings

### P1 - High

- **[`control/control_plane.go:824`] DNS 仍先入队，绕过改造不完整**
  - 当前结构是 `DefaultUdpTaskPool.EmitTask(...)` 后，才在任务内部按 `53/5353` 分支（`control/control_plane.go:846`）。
  - 这意味着同源突发仍先受 `UdpTaskPool` 串行/背压影响，无法达到 `dns_perf_rootcause-dev.md` 中“DNS 请求绕过 per-src 串行队列”的目标。
  - 直接影响：成功率改善有限（与你复测一致），核心瓶颈仍在 ingress 前半段。
  - 建议修复：把 DNS 识别/分流前置到 `EmitTask` 之前，或引入独立 DNS lane（独立队列 + worker），确保 DNS 不进入 per-src convoy。

- **[`control/control_plane.go:865`] 并发闸门饱和时回退同步，重新引入 convoy 风险**
  - 当 `dnsAsyncSem` 满时，代码在队列任务中同步调用 `handlePkt`。
  - 在上游慢/超时场景下（`DefaultDialTimeout=8s`, `DnsNatTimeout=17s`），该回退路径会放大队列阻塞，长时间运行可演化为“服务无响应”体验。
  - 建议修复：饱和时不要回退到 per-src 队列内同步执行；改为独立 DNS 队列等待或可观测的限流策略（并打点）。

### P2 - Medium

- **[`control/dns_improvement_test.go:148`] context 传播回归未被真实覆盖**
  - `TestHandle_ContextHasBoundedTimeout` 仅验证常量关系与本地 `WithTimeout`，并未执行 `handle_`/`dialSend` 调用链。
  - 若生产代码回退成 `context.Background()`，该测试仍会通过。
  - 建议修复：增加可注入 hook/stub，断言 `handle_` 传给 `dialSend` 的 ctx 带 deadline。

- **[`control/dns_improvement_test.go:173`] DNS bypass 测试是自证式，未覆盖生产分流路径**
  - `TestDnsTasksDoNotBlockTaskQueue` 在测试 task 内自行 `go`，验证的是 `UdpTaskPool` 行为，不是 `control_plane.go` 的真实 DNS 分类/分流逻辑。
  - 建议修复：增加 dispatch 层集成测试，或把“是否 bypass”判定提炼为可单测函数并直接测生产逻辑。

### P3 - Low

- **[`control/dns_improvement_test.go:120`] 未使用测试桩可清理**
  - `fakeDnsForwarder` 未被使用，建议删除减少噪音。

---

## Root Cause Trace（为何“耗时下降但成功率几乎不变”）

1. 这轮实现把 DNS 的并发化放在“队列消费阶段”，而不是“入队阶段”。
2. 因此优化的是“队列内单任务执行时长”，不是“队列拥塞本身”。
3. 结果就是：
   - 延迟下降（15s -> 10s）
   - 成功率仅小幅波动（仍约 66% 左右）
4. 长跑时若并发闸门饱和，回退同步路径会再次放大队列阻塞，表现为无响应。

---

## Removal/Iteration Plan

### Safe to Remove Now

- **Item**: 未使用测试桩 `fakeDnsForwarder`
- **Location**: `control/dns_improvement_test.go:120`
- **Rationale**: 无调用、无断言价值。
- **Verification**: 删除后跑 `go test`（Linux CI 环境）。

### Defer But Must Do Next Iteration

- **Item**: DNS 真正前置绕过 per-src 队列
- **Location**: `control/control_plane.go:824` 附近
- **Why defer**: 需要调整 dispatch 边界与回归测试。
- **Plan**:
  1. 将 DNS 分类前置到 `EmitTask` 之前。
  2. 增加独立 DNS lane（有界队列/worker）并加指标：`dns_inflight`、`dns_queue_len`、`dns_sem_saturated_total`。
  3. 去掉“闸门满 -> 队列内同步处理”路径。
  4. 增加集成测试覆盖真实 dispatch。
- **Validation**: 复跑 endurance（`concurrency=200`）目标至少 >95% 成功率，且无长跑无响应。

---

## Additional Suggestions

- 把 `maxAsyncDnsInFlight` 变为可配置项，并暴露运行时指标；固定常量 512 在不同硬件/上游条件下不可移植。
- 在压测脚本中增加“连续 30 分钟 + 半开/全慢上游”场景，专门验证“不会进入长期无响应状态”。

---

## Next Steps

我发现 **5 个问题**（P1: 2, P2: 2, P3: 1）。

建议下一步优先：
1. 先修 `control_plane` 的前置绕过与饱和回退路径（P1）。
2. 同步补上两条测试（P2），避免回归再次漏检。
3. 再做长跑回归并更新 `.plan/test-log.md` 验证数据。
