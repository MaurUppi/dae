# DNS Fix 分支系统性代码审计报告

## Context

基于 main 分支 tag v1.0.0，dns_fix 分支完成了以下改造：
1. DNS 请求绕过 per-src 串行队列，走专用有界 lane（dnsIngressQueue + 固定 worker）
2. 移除 DnsForwarder 缓存，每次 dialSend 创建新 forwarder + defer close
3. AnyfromPool 锁优化（ListenPacket 移出写锁）
4. DoH/DoQ transport 清理
5. Context 传播修复
6. DoUDP 竞态修复

初始测试曾出现“成功率 100%、低延迟”的正向结果；但新增四小时后观测显示存在明显退化（见 F4）。

本审计基于静态代码审查，排除注释不清/死代码/无关紧要项，仅报告危急/高/中风险问题。

---

## 审计结论

**共发现 4 个需要立即关注的问题（3 高 + 1 中）。无危急问题。**

多个 agent 报告的其他问题经验证为误报（详见下方"排除项"）。

---

## 发现清单

### F1 — HIGH: DNS 入队阻塞可堵死 UDP 读循环

**位置**: `control/control_plane.go:756-763`

**问题**: `enqueueDnsIngressTask` 只有两个 select 分支 — 上下文取消 或 入队成功。当 `dnsIngressQueue`（容量 2048）满时，发送操作阻塞。由于调用者是 UDP 读循环（`:864`），阻塞意味着 **所有 UDP 包（包括非 DNS）都无法被读取**，形成全局 backpressure。

```go
func (c *ControlPlane) enqueueDnsIngressTask(task dnsIngressTask) bool {
    select {
    case <-c.ctx.Done():
        task.data.Put()
        return false
    case c.dnsIngressQueue <- task:  // 队列满时阻塞
        return true
    }
}
```

**触发条件**: 上游 DNS 服务器大面积慢响应（如 8s 超时），256 worker 全部卡在 `handlePkt` → `dialSend`，2048 队列也被填满。

**影响**: UDP 读循环被堵死，所有入站 UDP 流量停滞，表现为全面无响应（不仅是 DNS）。

**自愈分析**: 当上游恢复后，被卡住的 worker 会在 DefaultDialTimeout（8s）到期后释放，系统在 8-10 秒内可自愈。但自愈窗口内新 DNS 请求会被丢弃，且 **`udp+tcp://` 配置会加重问题**——每个请求先尝试 UDP（~5s），再 fallback TCP（共享同一 8s ctxDial，剩余~3s），虽然总超时不变，但队列消费速率降低约 50%，更容易填满。

**修复建议**:
```go
func (c *ControlPlane) enqueueDnsIngressTask(task dnsIngressTask) bool {
    select {
    case <-c.ctx.Done():
        task.data.Put()
        return false
    case c.dnsIngressQueue <- task:
        return true
    default:  // 队列满，丢弃并释放 buffer
        task.data.Put()
        c.log.Warnln("DNS ingress queue full, dropping packet")
        return false
    }
}
```

同时 `dispatchDnsOrQueue` 中应检查返回值并记录日志（当前 `:768` 用 `_` 忽略）。

---

### F2 — MEDIUM: AnyfromPool 当 ttl <= 0 时 socket 泄漏

**位置**: `control/anyfrom_pool.go:235-245`

**问题**: socket 只在 `ttl > 0` 时才被加入 pool（`:244`）。如果 `ttl <= 0`，socket 被创建并返回给调用者，但从不入池。后续对同一 `lAddr` 的 `GetOrCreate` 调用会再次创建新 socket，造成 fd 泄漏。

```go
if ttl > 0 {
    newAf.deadlineTimer = time.AfterFunc(ttl, func() { ... })
    p.pool[lAddr] = newAf  // 仅 ttl > 0 时入池
}
```

**触发条件**: 生产代码中 `AnyfromTimeout = 5 * time.Second`（始终 > 0），因此当前不会触发。但这是一个**池合约违反**——方法签名承诺"获取或创建"，ttl<=0 时违反。

**影响**: 当前无实际影响，但若未来有 ttl=0 的调用场景，会导致 fd 耗尽。

**修复建议**: 将 `p.pool[lAddr] = newAf` 移到 `if ttl > 0` 块外，无条件入池。ttl<=0 时不设定 timer 即可（socket 永驻直到手动清理）。

---

### F3 — HIGH: reload 时 dnsIngressQueue 未排空，缓冲区泄漏

**位置**: `control/control_plane.go:778-793`, `control/control_plane.go:1083-1097`

**问题**: `Close()` 调用 `c.cancel()`（`:1095`），worker 收到 `ctx.Done()` 后立即退出（`:783`）。此时 `dnsIngressQueue` 中可能还有缓冲的 task，这些 task 的 `data` buffer 永远不会被 `Put()` 回池。

```go
// worker 退出
case <-c.ctx.Done():
    return  // 直接退出，不排空队列
```

**影响**: `dae reload`（SIGUSR1）在**同一进程内**销毁旧 ControlPlane 并创建新的（`cmd/run.go:263,298`）。每次 reload 最多泄漏 2048 个 pool buffer。频繁 reload 会导致内存持续增长。

**reload 生命周期确认**:
1. SIGUSR1 → `cmd/run.go:204`
2. 创建新 ControlPlane → `cmd/run.go:263`（新 context、新 dnsIngressQueue）
3. `oldC.Close()` → `cmd/run.go:298` → `c.cancel()` → worker 立即退出
4. 旧 dnsIngressQueue 中残留 task 的 `data` buffer 泄漏

**修复建议**: 在 worker 退出前增加排空循环：
```go
case <-c.ctx.Done():
    // 排空队列，释放 buffer
    for {
        select {
        case task := <-c.dnsIngressQueue:
            task.data.Put()
        default:
            return
        }
    }
```

---

### F4 — HIGH: 长跑后出现“轮次首秒超时簇”，成功率与轮次耗时退化

**位置**: 运行时现象（与 `control/control_plane.go:756-763` 的阻塞入队模型强相关）

**新增证据**:
1. 基线数据 `/Users/ouzy/Documents/DevProjects/dae/.plan/data/probes_20260217_170709.csv`（刚启动）：
   - 800/800 成功（100%）
   - 轮次耗时约 `3.25s / 3.00s / 2.29s / 1.25s`
2. 四小时后数据 `/Users/ouzy/Documents/DevProjects/dae/.plan/data/probes_20260217_205654.csv`：
   - 779/800 成功（97.375%）
   - 21 条失败均为 `dig: connection timed out; no servers could be reached`
   - 轮次耗时约 `15.35s / 15.42s / 15.38s / 15.36s`
3. 失败样本时间戳集中在每轮起始 1 秒窗口（`20:56:54-55`, `20:57:24-25`, `20:57:54-55`, `20:58:25`），呈“突发入站时丢失/超时”特征。

**判读**:
- 现象不是“所有 DNS 普遍变慢”，而是“少量超时请求将整轮 wall time 拉到 dig 超时上限（约 15s）”。
- 该模式与 F1 的风险模型一致：当处理链路瞬时饱和时，入口阻塞/背压会导致请求丢失或超时。
- 但当前缺少 `dns_ingress_queue_full_total` 与 `dns_ingress_drop_total`，无法在现场直接量化“队列满 -> 丢包”的因果强度。

**影响**:
- 长跑稳定性不达预期，成功率从 100% 下滑到 97.375%，且用户感知为“DNS 偶发卡住 15s”。
- 不满足“修复后长期稳定”的验收目标。

**修复建议（在 F1 修复基础上升级为必做项）**:
1. `enqueueDnsIngressTask` 改为非阻塞入队（`default` 分支），队列满时立即释放 buffer 并记录计数。
2. 落地并导出两个计数器：`dns_ingress_queue_full_total`、`dns_ingress_drop_total`。
3. 增加 soak 验证门禁：至少 4 小时运行 + 每 30 分钟一次 DNS endurance，对比成功率与超时簇是否复现。

---

## 排除项（误报分析）

以下是 agent 报告的问题，经验证后确认为误报或已在当前架构下被缓解：

| Agent 报告 | 排除原因 |
|---|---|
| DoH/DoQ client 清理竞态 | **误报**。dnsForwarderCache 已被移除，每次 `dialSend` 创建全新 forwarder 实例（`:590`），不存在跨 goroutine 共享。DoH `d.client` 和 DoQ `d.connection` 的 reconnect 逻辑仅在单个 `ForwardDNS` 调用内执行，无并发竞争。 |
| DoUDP localConn 竞态 | **误报**。每次 `dialSend` 创建新 `DoUDP` 实例（`:53`），`localConn` 是 `ForwardDNS` 内的局部变量，goroutine 和主线程操作同一个 `localConn` 是 **设计意图**（goroutine 写，主线程读），不存在 data race。 |
| Worker goroutine "泄漏" | **不成立**。worker 通过 `ctx.Done()` 退出，context 在 `Close()` 中被 cancel。256 个 goroutine 会在 cancel 后退出。这不是泄漏，是正常生命周期。 |
| invokeDialSend nil check 死代码 | **正确但无风险**。nil check 是防御性编程，`NewDnsController` 初始化时已赋值。不影响正确性。 |
| 测试未执行真实代码路径 | **已知局限**。`TestHandle_PropagatesDeadlineContextToDialSend` 通过 seam 捕获 ctx，验证 context 传播。这是 unit test 的正常做法——不等于自证。dispatch 测试同理，验证分流决策逻辑本身。集成测试由 CI 的完整 build + race test 覆盖。 |

---

## 修复文件清单

| 文件 | 修复项 |
|---|---|
| `control/control_plane.go` | F1: enqueueDnsIngressTask 增加 default 分支；dispatchDnsOrQueue 检查返回值 |
| `control/control_plane.go` | F3 (HIGH): worker 退出时排空队列（reload 场景触发泄漏） |
| `control/anyfrom_pool.go` | F2: p.pool[lAddr] = newAf 移到 if 块外 |
| `control/control_plane.go`（及指标导出路径） | F4: queue full/drop 计数器与日志节流，支持长跑归因 |

---

## 验证方式（补充版）

### 新增现场观测结论（2026-02-17）

1. 新现象与 F1 风险模型一致，且当前版本未达到“长期稳定”验收。
2. 该现象应按新增高优先级问题跟踪，不能按“偶发网络抖动”直接关闭。
3. 是否完全归因于 dae 仍需对照组验证（同机直连上游 DNS 的并行探针），但在计数器缺失前不应宣告修复完成。

### 1) “队列满压测下 UDP 读循环不被阻塞” 测试方法与验收指标

**测试目标**: 在 DNS lane 明确“满队列”状态下，证明 UDP 读循环仍持续消费，不出现全局停读。

**建议步骤**:
1. 构造“持续慢 DNS 上游”场景（例如黑洞 DNS 或强制超时），让 DNS worker 长时间占满。
2. 同时运行两类流量：
   - DNS 压测：沿用现有 endurance（`concurrency=200` 或更高）。
   - 非 DNS UDP 探针：固定频率发送/接收（如每 50ms 一个探针包）。
3. 观测项：
   - 日志：持续出现 `DNS ingress queue full`（证明确实打满）。
   - 指标：`dns_ingress_queue_full_total`、`dns_ingress_drop_total` 持续增长。
   - 读循环活性：非 DNS 探针持续有响应、无长时间空窗。

**验收标准**:
1. 在“队列已满且持续 >=30s”窗口内，非 DNS 探针成功率 `>=99%`。
2. 非 DNS 探针连续无响应空窗 `<=1s`（超过 1s 视为读循环可能被阻塞）。
3. `dns_ingress_queue_full_total` 与 `dns_ingress_drop_total` 均有增量，但进程无“UDP 全面停摆”现象。

备注：如果当前版本还没有上述两个计数器，先补齐计数器再执行该验收；否则仅靠主观日志不够稳定。

### 2) “reload 场景下无持续内存增长（>=30 次）” 测试方法与验收标准

**测试目标**: 验证 reload 不引入累积性内存泄漏（重点覆盖旧 `dnsIngressQueue` 残留 task 的 buffer 回收）。

**测试方法**:
1. 保持稳定流量（建议包含 DNS 流量）运行 dae。
2. 执行 30 次 reload（可脚本化，例如每次间隔 3-5 秒），不是只执行一次 `dae reload`。
3. 每次 reload 后采样同一进程 RSS（`/proc/<pid>/status` 的 `VmRSS` 或等效指标）。
4. 记录样本到表格并做趋势判断（至少比较第 5 次到第 30 次，规避初始热身噪声）。

**验收标准**:
1. `RSS(30) - RSS(5) <= 10 MB`。
2. 第 5~30 次样本线性趋势斜率接近 0（建议门限：`<=0.3 MB/reload`）。
3. 无单调持续爬升形态（允许锯齿波动，不允许“每次 reload 都更高且不回落”）。

结论：单次 `dae reload` 不能证明“无持续增长”；必须是“多次 + 采样 + 趋势判定”。

### 3) “ttl<=0 语义有测试覆盖” 的测试方式

代码修复后应补齐 `AnyfromPool.GetOrCreate` 的语义单测，最少包含：
1. `TestAnyfromPoolGetOrCreate_ZeroTTLStillPooled`
   - 连续两次对同一 `lAddr` 调用 `GetOrCreate(..., 0)`。
   - 断言：第一次 `isNew=true`，第二次 `isNew=false`，且返回同一连接实例。
2. `TestAnyfromPoolGetOrCreate_NegativeTTLStillPooled`
   - 连续两次对同一 `lAddr` 调用 `GetOrCreate(..., -1*time.Second)`。
   - 断言同上。
3. 回归保护：若未来把 `p.pool[lAddr] = newAf` 再次放回 `ttl > 0` 分支内，上述测试应立即失败。

**执行命令（建议）**:
`go test ./control -run 'TestAnyfromPoolGetOrCreate_(ZeroTTLStillPooled|NegativeTTLStillPooled)' -count=1`

### 4) 两个计数器的生产意义（不仅是 debug）

建议新增：
1. `dns_ingress_queue_full_total`: DNS 入队时命中“队列已满”的次数。
2. `dns_ingress_drop_total`: DNS 入队/处理链路中最终被丢弃的包总数。

**生产使用价值**:
1. SLO 预警：`drop_total` 的增速可直接映射用户可感知失败率，不是纯内部调试信息。
2. 容量规划：`queue_full_total` 长期偏高说明 lane 容量/worker 数不足，可量化调参收益。
3. 故障定位：结合上游超时与系统负载，可快速区分“上游慢”还是“本地入口饱和”。
4. 变更回归：版本升级后对比这两个计数器的基线变化，能早期发现性能退化。

建议在告警规则中同时使用两者：
1. `queue_full_total` 高但 `drop_total` 低：系统逼近容量上限，需预扩容。
2. `drop_total` 持续上升：已发生用户面损失，需立即处置。

### 5) 回归门禁

1. `GOWORK=off GOOS=linux GOARCH=amd64 go vet ./control/`
2. 相关单测（含上文 ttl<=0、dispatch、context 传播）全部通过
3. CI `dns-race.yml` 通过
