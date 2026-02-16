# dae DNS 改进计划 v2（以 mosDNS 为 baseline）

## 0. 目标与基线
- baseline：`.plan/dae_vs_mosdns_table.csv` 与 `.plan/dae_vs_mosDNS_findings.md` 显示 mosDNS 在成功率（96.8%~100%）与延迟（39ms 中位）显著优于 dae（成功率约 60%，中位 58ms）。
- 目标：优先把 dae 的失败率从 ~40% 降到 <5%，再把时延拉近到 mosDNS 区间。

## 1. 根因分析（按优先级）

### P0-1：UDP forwarder 连接未被正确回收，易在压测时触发连接/FD 压力
**代码证据**
- `DoUDP.ForwardDNS` 创建了局部 `conn`，但没有赋值给结构体字段 `d.conn`。
- `DoUDP.Close` 只会关闭 `d.conn`，因此多数查询创建的 UDP 连接不会被 `Close()` 关闭。

**影响机制**
- `DnsController.dialSend` 每次查询都会调用 `forwarder.Close()`，设计意图是“每次请求后回收连接”。
- 但对于 UDP 实现，`Close()` 实际不生效，导致高并发下 socket/端口资源压力积累，最终体现为连接超时比例升高。

### P0-2：`tcp+udp` 只有“选优单发”，缺少同查询级别 UDP→TCP 兜底
**代码证据**
- `chooseBestDnsDialer` 会在候选 `(ipversion × l4proto)` 中选出一个“当前最优路径”。
- `dialSend` 只执行一次 `forwarder.ForwardDNS`；出错即返回，不会在同一请求内切换另一协议重试。

**影响机制**
- 当 `tcp+udp` upstream 被选中 UDP 路径且出现瞬时丢包/抖动时，查询直接失败。
- 在有明显 UDP 波动的网络环境中，这会显著抬高失败率并拉长尾时延（等待超时后失败）。

### P1-1：超时反馈链路未闭环，不健康路径不能被快速熔断
**代码证据**
- `DnsControllerOption` 注入了 `TimeoutExceedCallback`，`control_plane` 里该回调用于 `ReportUnavailable`。
- 但 `dialSend` 失败路径没有调用 `c.timeoutExceedCallback`，导致超时信息没有反馈给 dialer 健康度系统。

**影响机制**
- 坏路径超时后仍持续被选中，形成“连续命中坏路径”的放大效应。
- 这会同时拖高失败率和时延（尤其 P95/P99）。

### P1-2：context 超时未完整传递到各 DNS 协议 I/O，导致取消不及时
**代码证据**
- `dialSend` 给查询设置了 `ctxDial (8s)`，但 `sendHttpDNS` 使用 `http.NewRequest` 而不是 `NewRequestWithContext`。
- `sendStreamDNS` 读写未设置 deadline，也不感知 ctx（TCP/TLS/DoQ 流读写路径）。

**影响机制**
- 在上游卡顿时，查询可能无法及时被取消，放大排队与尾时延。
- 连接被长时间占用，也会加剧资源竞争并间接提升失败率。

### P2：`ipversion_prefer` 的 A/AAAA 并发双查会放大上游请求量
**代码证据**
- `HandleWithResponseWriter_` 在 A/AAAA 查询且启用 `ipversion_prefer` 时，会并发触发另一 qtype 查询，并等待两个分支。

**影响机制**
- 压测下相当于把单请求放大为双请求，增加 upstream 和本地处理压力。
- 在网络抖动场景下，更易出现 timeout 叠加，进一步拖慢响应。

## 2. 最佳修复方案（优先级排序）

### Priority 0（立即止血：1 个迭代）
1. **修复 UDP 连接回收**
   - `DoUDP.ForwardDNS` 拨号后设置 `d.conn = conn`。
   - `DoUDP.Close` 关闭后将 `d.conn=nil`，保证幂等。
2. **在 `dialSend` 失败路径接入超时反馈**
   - 识别 timeout / temporary network error 后调用 `c.timeoutExceedCallback(dialArgument, err)`。
   - 让坏路径快速降权或熔断，减少连续超时。

### Priority 1（成功率提升：1~2 个迭代）
3. **为 `tcp+udp` 增加同查询 fallback**
   - 首选 UDP（短预算，如 800ms~1500ms），超时/可重试错误立即切 TCP。
   - 仅 retry 一次，且只对可重试错误触发，避免放大流量。
4. **统一上下文/超时语义**
   - DoH 请求改为 `http.NewRequestWithContext(ctx, ...)`。
   - stream DNS（TCP/TLS/DoQ）在 write/read 前设置 deadline，并在 ctx 取消时主动中断。

### Priority 2（延迟与弹性优化：2~3 个迭代）
5. **优化 `ipversion_prefer` 为“优先+条件补查”而非固定并发双查**
   - 默认先查 prefer qtype；仅在首查为空/失败/策略命中时补查另一族。
6. **增加 DNS 维度可观测性并驱动自适应**
   - 指标：按 upstream/l4proto/ipversion/outbound/dialer 统计 success、timeout、P50/P95/P99。
   - 利用指标为 `chooseBestDnsDialer` 提供短窗口惩罚与恢复机制。

## 3. 建议实施顺序与预期收益
1. **先做 P0（连接回收 + 超时反馈）**：直接打掉“连接超时”主因，预期失败率立刻显著下降。
2. **再做 P1（query 级 fallback + timeout 语义统一）**：进一步降低超时失败并压缩长尾。
3. **最后做 P2（请求放大与策略优化）**：在成功率稳定后再追求时延与资源效率。

## 4. 验收标准（对齐 baseline）
- 成功率：压测场景下从 ~60% 提升到 >95%，再逐步逼近 mosDNS（96.8%~100%）。
- 失败结构：连接超时占比接近 0；失败主要收敛为少量上游/域名自身问题。
- 时延：`time_namelookup`/`time_total` 的 P50 接近 39ms，P95/P99 明显收敛。
- 稳定性：轮次间成功率波动明显缩小，不再出现大幅抖动。

## 5. 回归测试矩阵（最小可行）
- 协议：`udp` / `tcp` / `tcp+udp` / `tls` / `https` / `quic` / `h3`
- 网络扰动：正常、10% 丢包、仅 UDP 阻断、仅 TCP 阻断
- 查询：A、AAAA、混合热点域名、冷门域名
- 配置：`ipversion_prefer`=0/4/6，response reroute 开/关

