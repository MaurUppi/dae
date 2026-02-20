# DNS Ingress 设计审计与优化方案

> 文档目标：对 `dns_ingress` 相关改动做基线对照、必要性说明、保留理由与可配置化方案设计，供后续是否继续演进做决策。
> 
> 对照基线：`bc7e4642`（你定义的 upstream `main/tag v1.0.0` 状态）
> 当前分支：`dns_fix`

---

## 1. 上游基线情况（bc7e4642）

### 1.1 基线结构
在 `bc7e4642` 的 `control/control_plane.go` 中：
1. UDP 入站统一先进入 `DefaultUdpTaskPool.EmitTask(...)`（per-src 串行队列）。
2. 不存在 DNS 专用 ingress lane（无 `dnsIngressQueue`、无 DNS 专用 worker）。
3. 不存在 `dnsIngressWorkerCount`、`dnsIngressQueueLength` 常量。
4. 不存在 `dns_ingress_queue_full_total` / `dns_ingress_drop_total` 计数观测。

### 1.2 基线风险点
1. DNS 分类发生在 per-src 队列之后，热点源地址流量容易形成 convoy（排队拖慢 DNS）。
2. 当上游 DNS 变慢时，DNS 与其他 UDP 任务争用相同串行入口，导致成功率与延迟退化风险上升。
3. 长跑场景下难以快速判别“是入口排队导致，还是上游 DNS 变慢导致”，缺少直接观测量。

---

## 2. 引入的原因与作用边界

### 2.1 引入项（dns_fix）
当前分支在 `control/control_plane.go` 引入：
1. `dnsIngressWorkerCount = 256`
2. `dnsIngressQueueLength = 2048`
3. DNS 专用 `dnsIngressQueue` + 固定 worker lane
4. 队列满时 drop，并累加：
   - `dnsIngressQueueFullTotal`
   - `dnsIngressDropTotal`

### 2.2 引入原因
1. 把 DNS 从 per-src 串行队列入口前置分流，降低 F1（入口 convoy）复发概率。
2. 通过有界队列 + 固定 worker 实现“可控背压”，避免无界积压。
3. 用计数器与 warn 日志提供现场证据，缩短定位路径。

### 2.3 作用边界（非常重要）
该设计只改变“UDP 入站分流与排队模型”，不改变：
1. DNS 协议处理语义（A/AAAA、缓存策略、fallback 逻辑）。
2. 上游 DNS 选择与 dialer 策略。
3. 非 DNS 流量的默认处理语义（仍经 `EmitTask`）。
4. `dns.routing` 与全局 `routing` 的职责边界：前者选“查哪个 DNS 上游”，后者决定“到该上游的连接是否走代理/走哪组节点”。

同时，当前计数器是“观测型副产物”：
1. 只在队列满时递增并打日志。
2. 不直接驱动策略调节（不是控制回路）。

补充说明（来自 `.plan/dae_DNS_feature_workflow.md`）：
1. 该工作流文档含历史实现描述（如 `dnsForwarderCache`），与当前 `dns_fix`“每次请求创建 forwarder”的实现不完全一致。
2. 因此该文档更适合作为“功能流程参考”，不应直接当作当前代码行为的唯一证据。

---

## 3. 需要保留的原因

### 3.1 保留 DNS 专用 lane 的理由
1. 结构性隔离：避免 DNS 继续被 per-src 串行队列拖累。
2. 资源可控：有界队列可防止慢上游把系统拖入长尾排队。
3. 稳定性优先：宁可在极端压力下明确丢弃部分请求，也不让整个 UDP 入口读循环被连带阻塞。

### 3.2 保留“硬上限思想”的理由
1. 无上限扩容会把短时峰值转为长期排队，尾延迟可能更差。
2. 对高并发 DNS 代理来说，“有界 + 可观测 + 快速失败”通常比“无界堆积”更可运维。
3. 你当前关心的是“运行一段时间后不退化”；可控上限是防退化基础设施，不应撤销。

### 3.3 保留计数器的理由
1. 这两个计数器直接回答“是否曾经队列打满并发生丢弃”。
2. 可将“感觉变慢”转为“可量化证据”，便于对比不同版本和不同上游环境。
3. 在后续做自适应调优前，它们是最小可行观测面。

---

## 4. Unbound 的参考设计（可借鉴点）

> 参考方向：Unbound 的并发/线程/队列容量都不是无界，而是显式参数 + 资源约束思路。

### 4.1 可借鉴原则
1. 明确并发上限（线程、每线程查询上限）。
2. 明确外发并发与 socket 资源上限（如 outgoing range 概念）。
3. 在“吞吐、延迟、内存”三者间做可配置折中，而非单一追求吞吐。
4. 通过统计项判断是否触顶，再决定调参，不做盲目放大。

### 4.2 对 dae 的映射
1. `workers` 对应处理并发上限（类似 worker/thread 数）。
2. `queue_len` 对应缓冲吸收能力（类似待处理请求池上限）。
3. `queue_full/drop` 计数对应“触顶告警信号”。

说明：Unbound 与 dae 架构不同，不能直接照抄参数值，但“有界并发 + 有界队列 + 观测驱动调参”的方法论一致。

---

## 5. "分级性能等级 + manual 模式" 方案细节

### 5.1 配置项设计（放 `global`）

采用**语义化分级**代替直接暴露 workers/queue 参数，降低用户理解门槛。

#### 主配置项
```
dns_performance_level: balanced
```
可选值：`lean` / `balanced`（默认）/ `aggressive` / `manual`。

#### 性能等级映射表

| Level | Workers | Queue | 理论 QPS 峰值 | 目标场景 |
|---|---|---|---|---|
| `lean` | 32 | 128 | ~600 | 轻量/嵌入式：单人使用、低功耗路由、树莓派 |
| `balanced` | 256 | 2048 | ~5,000 | 标准家用/小型办公：典型家庭环境（50+ 设备） |
| `aggressive` | 1024 | 4096 | ~20,000 | 高负载/园区级：中大型办公室、公共热点、网吧 |
| `manual` | 自定义 | 自定义 | 视配置 | 专家调优：针对特定硬件极限压测 |

#### Manual 子配置（仅 `manual` 时生效）
```
dns_ingress_manual {
    workers: 512
    queue: 2048
}
```
非 `manual` 等级时，`dns_ingress_manual` 整节被忽略。

#### 内部常量（不暴露给用户）
`dnsIngressQueueLogEvery = 100`：每累计 100 次队列打满事件打印一次 warn 日志（第 1 次也会打印）。该值为纯日志节流参数，用户无修改理由——改大丢失可见性，改小触发日志风暴。

### 5.2 校验规则

#### level 校验
1. 不区分大小写（`Balanced` 等同 `balanced`）。
2. 未配置或空值 → 回落 `balanced`。
3. 不合法值 → warn + 回落 `balanced`。

#### manual 参数校验
仅当 `level == "manual"` 时执行：
- `workers`: 范围 `[32, 1024]`，`0` 或未配置 → 回落 256。超出范围 → clamp + warn。
- `queue`: 范围 `[128, 16384]`，`0` 或未配置 → 回落 2048。超出范围 → clamp + warn。
- 不设交叉约束（`queue >= 4 * workers` 之类）：manual 模式信任专家判断。

#### 非法值处理
不做启动失败；一律 clamp + warn，保证可用性优先。

### 5.3 生命周期语义
1. 仅"启动时生效"。channel 与 worker 在 `NewControlPlane` 中创建。
2. `dae reload`（SIGUSR1）会销毁旧 ControlPlane 并创建新的（`cmd/run.go:263,298`），新 config 中的 level/manual 值自然生效。**无需专门的热更新机制。**

### 5.4 观测与告警建议
1. 保留现有 throttled warn 日志：`DNS ingress queue full, dropping packet`（首次 + 每 100 次）。
2. 每条 warn 携带结构化字段 `dns_ingress_queue_full_total` 和 `dns_ingress_drop_total` 累积值。
3. 启动时输出 info 日志：`DNS ingress: level=balanced, workers=256, queue_len=2048`。
4. **不引入 metrics endpoint**：dae 当前无 prometheus 基础设施，引入是独立特性，不捆绑本次改动。

### 5.5 用户调参指导
1. 大多数用户使用默认 `balanced` 即可。
2. 若日志中出现 `DNS ingress queue full` 警告且 CPU 余量充足 → 切换至 `aggressive`。
3. 低功耗设备（树莓派、嵌入式路由）可选 `lean` 节省资源。
4. 仅在上述预设不满足时使用 `manual`，需结合日志中的累积计数做针对性调整。

### 5.6 配置联动约束
1. 调整 `dns_performance_level` 时，应同步检查全局 `routing` 是否让 DNS 上游走了高时延路径；否则会把"路径慢"误判为"lane 容量不足"。
2. 对使用 `tcp+udp` 上游的场景，要预留 fallback 开销（UDP 超时后再尝试 TCP）；在同样并发下其 worker 占用时间通常高于纯 UDP/纯 TCP 上游。
3. 如使用 `asis`，必须避免将客户端 DNS 指回 `dae:53` 导致回环；否则调大等级也只能放大错误流量。

---

## 6. 其它需要补充的内容

### 6.1 为什么不建议“动态无上限扩容”
1. 容易隐藏上游退化，延迟从秒级抖动演化为长尾排队。
2. 可能造成内存峰值不可控，最终反噬整体稳定性。
3. 不利于问题定位，现场只看到“慢”，看不到“哪里触顶”。

### 6.2 与你当前目标的关系
你的目标是：
1. 冷启动 200 或者更高的并发，可保持低延迟（当前有 3.x 秒样本）。
2. 长跑后不再出现 F1 类退化。

分级方案对目标的贡献：
1. 结构上保持 DNS 与 per-src 队列隔离（防止回到旧路径）。
2. 通过语义化 level 可按部署场景快速适配，不要求用户理解 worker/queue 内部机制。
3. `balanced`（默认）与当前硬编码行为完全一致，升级零风险。
4. 通过观测计数能快速判断是否"lane 触顶"导致退化，再据此切换 level。

### 6.3 建议的落地顺序（最小风险）
1. 分级配置 + 启动时校验（不改默认行为）。
2. metrics 导出为独立特性，不捆绑 DNS ingress 改动。

### 6.4 来自 DNS 工作流文档的关键补充（新增）
1. 域名分流成立前提：DNS 请求必须经过 dae。若终端绕开 dae 直连 DNS，上述 ingress 计数与真实域名分流效果会脱钩。
2. `dns.routing` 仅决定“查谁”，不决定“如何到达谁”；上游可达性与时延受全局路由和组策略影响。
3. 污染重查（response routing 触发重查）会放大单请求处理耗时，进而提高 DNS lane 触顶概率，应纳入压测用例。

---

## 结论
1. `dnsIngressWorkerCount=256` 与 `dnsIngressQueueLength=2048` 不是上游 v1.0.0 原生设计，是 dns_fix 为解决 F1/F4 风险引入的有界 ingress 机制。
2. 这套机制建议保留；不建议回退到无专用 lane 或无上限模型。
3. 下一步：把当前硬编码升级为"分级性能等级（lean/balanced/aggressive/manual）+ 启动时校验"，默认 `balanced` 与现行为完全一致。
4. 计数器输出保持 throttled warn log，metrics endpoint 作为独立特性另行评估。
