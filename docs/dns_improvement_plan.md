# dae DNS 改进计划（以 mosDNS 为 baseline）

## 背景
- 当前仓库中未找到以下外部分析附件：
  - `docs/dae_Feature_Overview.md`
  - `docs/dae_System_Architecture.md`
  - `docs/dae_DNS_feature_workflow.md`
  - `docs/dae_vs_mosDNS_findings.md`
  - `docs/dae_vs_mosdns_table.csv`
  - `docs/dae_mosdns_20260216_comparison.png`
- 本计划基于当前代码与仓库内 DNS 文档进行静态分析。

## 现象与根因（按影响排序）

### 1) UDP forwarder 的连接生命周期管理存在缺陷（高失败率主因）
- `DoUDP.ForwardDNS` 中使用局部变量 `conn` 发送/接收，但没有将其赋值给结构体字段 `d.conn`。
- `DoUDP.Close` 仅关闭 `d.conn`，导致一次查询创建的 UDP 连接不被 `Close` 回收。
- 在并发压测下，容易放大为端口/FD 压力，体现为连接超时比例升高。

### 2) `tcp+udp` 仅“选一路径执行一次”，缺少 query 级协议兜底
- 代码会在候选路径中选择“当前最优”协议+IP 组合，然后单次执行查询。
- 当选中的 UDP 路径发生瞬时抖动/丢包时，请求直接失败；没有 UDP→TCP 的同查询自动切换。
- 这会显著拉高失败率，并放大尾延迟。

### 3) 超时模型与不健康反馈链路不闭环
- `DnsController` 里注入了 `timeoutExceedCallback`，但查询失败路径未实际调用。
- 结果是：发生超时后，拨号器健康度不被及时标记，后续仍可能反复命中同一坏路径。
- `sendHttpDNS` 使用 `http.NewRequest` 而非 `http.NewRequestWithContext`，请求取消与总超时传播不完整。

### 4) `ipversion_prefer` 的 A/AAAA 并发双查会放大上游压力
- 在 A/AAAA 查询场景会并发发起另一 qtype 查询。
- 压力场景下会把单请求放大为双请求，叠加上游抖动时容易提高超时概率。

## 最佳修复方案（推荐）

采用“**两阶段落地**”：先稳定，再提效。

### Phase 1（止血，1~2 个迭代）
1. 修复 DoUDP 连接回收：
   - 在 `DoUDP.ForwardDNS` 中将 `d.conn = conn`；
   - `Close` 后清空字段并保证幂等。
2. 打通超时反馈：
   - 在 `dialSend` 识别 timeout/网络超时错误后，调用 `timeoutExceedCallback`；
   - 让拨号器快速下线不健康路径。
3. 统一上下文超时传递：
   - DoH 请求改为 `NewRequestWithContext`；
   - 为流式 DNS（TCP/TLS/QUIC）补齐读写 deadline/ctx 取消。

### Phase 2（提效，2~3 个迭代）
1. 为 `tcp+udp` 增加查询级兜底：
   - 默认先 UDP（短超时预算），超时后同请求切 TCP；
   - 仅对可重试错误触发切换，避免无效重试。
2. 优化 `ipversion_prefer`：
   - 从“强制并发双查”升级为“首选优先 + 条件补查”或可配置 hedge；
   - 降低请求放大系数。
3. 指标化观测：
   - 增加按协议/上游/出口统计的成功率、超时率、P50/P95/P99，形成自适应选择依据。

## 验收标准（对齐 mosDNS baseline）
1. 成功率：在同等压测下，目标接近 mosDNS 水平，至少将失败率显著下降到个位数。
2. 延迟：P50 下降，P95/P99 明显收敛，避免长尾抖动。
3. 稳定性：连接超时占比显著下降，且不再长期集中于同一拨号路径。

## 建议测试矩阵
- 协议：UDP / TCP / TLS / HTTPS / QUIC / H3。
- 上游：单上游、`tcp+udp` 双栈上游、不同地域上游。
- 网络：正常、随机丢包、抖动、单方向阻断（仅 UDP 或仅 TCP）。
- 查询类型：A、AAAA、混合域名、热点域名重复查询。
- 配置：`ipversion_prefer` 关闭/4/6，含 response 重查规则与不含重查规则。
