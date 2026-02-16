# dae DNS 改进计划 v2 - 开发执行文档

> baseline: mosDNS（`.plan/dae_vs_mosdns_table.csv` / `.plan/dae_vs_mosDNS_findings.md`）

## 执行原则
1. 严格串行：Tn 完成实现并完成任务级测试记录后，才进入 Tn+1。
2. 每个任务必须包含：代码变更、任务级测试、测试结论。
3. 里程碑回归：阶段任务全部完成后进行一次回归测试。

## 任务拆解与落地

### T1（P0-1）：修复 UDP forwarder 连接回收
- 变更点：
  - `DoUDP.ForwardDNS` 拨号成功后保存 `d.conn`。
  - `DoUDP.Close` 关闭后置 `d.conn=nil`，确保幂等回收。
- 目标：降低 UDP 连接泄漏导致的 FD/端口压力。

### T2（P1-1）：失败路径接入 timeout 健康反馈
- 变更点：
  - `dialSend` 在 forwarder 返回 timeout 错误时调用 `timeoutExceedCallback`。
  - 新增 `isTimeoutError` 统一识别 `context deadline exceeded` / `net.Error.Timeout()`。
- 目标：让健康度系统尽快降权不健康路径。

### T3（P1-3）：tcp+udp 增加同查询 UDP→TCP fallback
- 变更点：
  - 新增 `tcpFallbackDialArgument`：仅在 upstream 为 `tcp+udp` 且首发 UDP timeout 时切换 TCP。
  - `dialSend` 在一次查询内执行一次 fallback 重试，避免无限重试放大。
- 目标：降低 UDP 瞬时抖动造成的直接失败。

### T4（P1-4）：统一上下文/超时语义
- 变更点：
  - DoH 请求改为 `http.NewRequestWithContext`。
  - `sendStreamDNS` 增加 `ctx` 入参，优先使用 `ctx.Deadline()` 设置 stream deadline，并在 I/O 前后检查 `ctx`。
- 目标：提升取消及时性，降低尾延迟。

### T5（P2-5）：ipversion_prefer 从固定并发双查改为“优先+条件补查”
- 变更点：
  - `Handle_` 对 A/AAAA 请求改为先查首选 qtype；仅当需要时再补查另一族。
- 目标：降低上游请求放大与高压下 timeout 叠加。

## 本轮范围说明
- 本轮完成 T1~T5。
- P2-6（DNS 维度指标与自适应）需要较大横切改造（指标面板+选择器反馈回路），建议下一迭代单独实施。
