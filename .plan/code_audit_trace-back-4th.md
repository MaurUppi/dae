# handlePkt / Broken Pipe 综合审计报告

> 数据源:
> - `.plan/data/handlePkt.csv`（5000 条，2026-02-18 08:31–09:29）
> - `.plan/data/broken_pipe/dae-triage-*`（**5** 次 triage 采集，跨 1 月 5 日 + 2 月 20 日）
> - `.plan/data/probes_20260218_004105.csv`（冷启动探测）+ `probes_20260218_085634.csv`（10 小时探测）
> - 远程实时日志（`ssh dae "journalctl -u dae"`, 2026-02-18 10:11 仍在持续）
> 审计范围: `handlePkt` 错误路径、broken pipe 根因、CLOSE-WAIT socket 泄漏、`sendPkt`/AnyfromPool 绑定失败
> 分支: 2026-01-05 采集 = main 分支; 2026-02-20 采集 = **dns_fix 分支**
> 代理节点端口映射:
> | 端口 | 节点 |
> |---|---|
> | 12101 | 香港高级 IEPL 专线 3 |
> | 12103 | 香港高级 IEPL 专线 2 |
> | 11108 | 香港标准 IEPL 专线 7 |
> | 11141 | 台湾标准 IEPL 专线 3 |

---

## 数据摘要

### A. handlePkt.csv 日志统计（2026-02-18 08:31–09:29, dns_fix 分支）

| 指标 | 值                                                                                |
|---|----------------------------------------------------------------------------------|
| 总错误条数 | 5,000                                                                            |
| broken pipe | 4,987（99.7%）                                                                     |
| bind: address already in use | 13（0.3%）                                                                         |
| handlePkt(dns) 占比 | 4,652（93.2%）                                                                     |
| handlePkt（非 DNS）占比 | 348（6.8%）                                                                        |
| 唯一目标 IP | **163.177.58.13**（100%）                                                          |
| 目标端口分布 | 12101(香港高级3): 2,182; 11141(台湾标准3): 1,156; 11142(台湾标准1): 1,069; 12103(香港高级2): 580 |
| 峰值频率 | ~250 次/分钟（08:57）                                                                 |
| 当前状态 | **仍在持续**（10:11 实时日志确认）                                                           |

### B. dae_triage_unified_v5.sh 五次采集汇总

| # | 采集时间 | 分支 | PID | IEPL 节点 | 事件数 | 结论 | CLOSE-WAIT max | Scenario A |
|---|---|---|---|---|---|---|---|---|
| 1 | 2026-01-05 16:18 | main | 44855 | 113.108.0.12 | 60 | **DAE_BUG: ERRORS_IGNORED** | 3 | 8 |
| 2 | 2026-01-05 16:36 | main | 44855 | 113.108.0.12 | 104 | **DAE_DESIGN_ISSUE** | 7 | 44 |
| 3 | 2026-02-20 08:28 | dns_fix | 363521 | 163.177.58.13:11108(香港标准7) | 7 | MIXED_OR_PROPER | **111** | 0* |
| 4 | 2026-02-20 09:23 | dns_fix | 363521 | 163.177.58.13:11108(香港标准7) | 32 | **DAE_DESIGN_ISSUE** | **54** | 31 |
| 5 | 2026-02-20 10:12 | dns_fix | 363521 | 163.177.58.13:11108(香港标准7) | 101 | **DAE_DESIGN_ISSUE** | **24** | **100** |

\* 采集#3 的 7 事件全部为 `graceful_fin`（对端 FIN, 无 RST），因事件数少且 dae 正确处理故判定 MIXED_OR_PROPER。但 CLOSE-WAIT 堆积至 111 本身说明存在严重问题。

**第 5 次采集关键发现（dae-triage-20260220-101200, dns_fix 分支）**:

1. **30 秒内爆发 101 个事件**（10:12:01–10:12:30），平均 3.4 次/秒
2. **100% Scenario A**（FIN→RST）：对端先 FIN 后 RST，dae 在 FIN 后仍写入
3. **100% 单一节点**：全部指向 `163.177.58.13:11108`（香港标准 IEPL 专线 7）
4. **handlePkt 前缀分布**: `handlePkt:` 86（86%）, `handlePkt(dns):` 14（14%）
5. **CLOSE-WAIT 呈波浪形**：0→24（峰值）→0（恢复）→12（二次堆积）→5（末尾）
6. **29 个唯一源端口中 28 个重复出现**：说明 dae 在同一条已断裂连接上反复写入（最多 8 次/端口）
7. **strace 错误处理**: proper_handling 77%, no_errors_captured 19%, unclear 4%
8. **Scenario C = 0**：dns_fix 分支已修复 EPIPE 后继续写入的 bug

**跨 5 次采集综合分析**:

| 维度 | main 分支 (Jan 5) | dns_fix 分支 (Feb 20) | 结论 |
|---|---|---|---|
| IEPL 节点 | 113.108.0.12 | 163.177.58.13 | 问题跨节点重现 |
| Scenario A 合计 | 52 (32%) | **131 (87%)** | FIN→RST 是主导模式 |
| Scenario C (EPIPE ignored) | **14** | **0** | ✅ dns_fix 修复了 EPIPE 忽略 bug |
| CLOSE-WAIT max | 3-7 | **24-111** | ⚠️ 在 dns_fix 采集期显著升高；T1 已确认归属为非 DNS 代理路径 |
| handlePkt(dns): 占比 | 未采集 | 14% (采集#5) | 86% 为非 DNS 代理流量 |

### C. 用户 DNS 配置

```
dns {
  upstream {
    vyos_mosdns: 'tcp://192.168.1.8:5553'
  }
  routing {
    request {
      fallback: vyos_mosdns
    }
  }
}
```

DNS upstream 为本地 VyOS mosdns（`tcp://192.168.1.8:5553`），正常日志显示 `dialer=direct outbound=direct`。

### D. 路由配置分析（关键）

```
routing {
    pname(NetworkManager, systemd-resolved, curl, kdig, dig) -> must_direct
    dip(192.168.1.8) && dport(5553) -> must_direct   # DNS upstream 走 direct
    dip(geoip:private) -> direct                       # 内网直连
    ...
    fallback: HK                                       # 默认走 HK 代理组（IEPL 节点）
}
```

**代码层面验证**:
1. `chooseBestDnsDialer()` (L1076) 调用 `c.Route(req.realSrc, dnsUpstreamAddr, ...)` 对 DNS upstream 做路由。
2. `dip(192.168.1.8) && dport(5553) -> must_direct` 匹配 → 返回 `OutboundDirect`。
3. **关键**: `Route()` 在 `utils.go:46` 将 `must` 返回值**硬编码为 `false`** → DNS 路径的 `chooseBestDnsDialer` 永远不感知 must 标志。
4. 最终 `dialerGroup.Select()` 返回 **direct dialer**，DNS 查询直连 192.168.1.8:5553。

**结论**: DNS upstream 连接**不可能**经过 IEPL 代理节点。所有到 163.177.58.13 的 broken pipe **必然来自非 DNS 的 UDP 代理路径**（`handlePkt()` 内 `isDns=false` → `ue.WriteTo()` → 通过 IEPL TCP 隧道，路由匹配 `fallback: HK`）。

`handlePkt(dns):` 日志前缀仅表示**该包来自 DNS ingress 队列**（由 DNS worker 处理），不表示该包走了 DNS 代码路径。

---

## 发现清单

### 第一部分：非 DNS 相关问题（在 main 分支创建新分支修复）

> 以下问题的根因在 dae 原始代码中的非 DNS UDP 代理路径，不涉及 dns_fix 分支引入的代码。

#### F1 [严重] 通过已断裂的 IEPL 代理隧道持续写入导致 broken pipe

**代码路径（非 DNS UDP 代理路径）**:
```
handlePkt() (udp.go:64)
  → isDns=false
    → outboundIndex = BPF routing 匹配 fallback: HK → IEPL 代理组
      → UdpEndpointPool.GetOrCreate() → dialer.DialContext() → TCP 隧道到 163.177.58.13
        → ue.WriteTo(data, dialTarget) (L285) → 写入已断裂 TCP 隧道 → broken pipe
```

**根因**: IEPL 节点的 TCP 隧道连接被对端关闭（FIN/RST）后：
1. `ue.WriteTo()` 尝试写入已断裂的 TCP 连接 → `write: broken pipe`
2. 同一源端口反复报错（采集#5: 29 个源端口中 28 个重复出现，最多 8 次/端口），说明 UdpEndpoint **复用同一条已断裂 TCP 连接**
3. triage 5 次采集 **共 183 个 Scenario A 事件**（FIN→RST），占已分析事件 60%+

**影响**: 5000 条错误/58 分钟，峰值 250 条/分钟。代理流量在 IEPL 节点断连期间持续失败。

**证据**:
- handlePkt.csv: 同一源端口持续 15+ 分钟反复 broken pipe
- 采集#5: 30 秒内 101 事件，100% Scenario A，100% 单一节点 (11108/香港标准7)
- 4 个 IEPL 端口均受影响（12101/香港高级3, 11141/台湾标准3, 12103/香港高级2, 11108/香港标准7）

#### F2 [高] 非 DNS UDP 代理路径重试机制无法避免持续 broken pipe

**代码路径**: `udp.go:285-303`
```go
_, err = ue.WriteTo(data, dialTarget)   // L285
if err != nil {
    _ = DefaultUdpEndpointPool.Remove(realSrc, ue)  // L301: 清除坏连接
    retry++
    goto getNew  // L303: 重建连接重试（最多 MaxRetry=2 次）
}
```

**根因**: 重试重建连接时 `dialerGroup.Select()` 仍可能选中同一个已断裂的 IEPL 节点（健康检查未感知 broken pipe），导致重试无效。MaxRetry=2 消耗完后 worker 返回错误，但下一个相同 `realSrc` 的包又重复整个过程。

**代码归属**: dae 原始代码（`udp.go`），非 dns_fix 引入。

#### F3 [高] sendPkt/AnyfromPool 绑定 UDP 192.168.1.15:53 失败

**代码路径**:
```
sendPkt() (udp.go:55-62)
  → DefaultAnyfromPool.GetOrCreate("192.168.1.15:53", AnyfromTimeout)
    → createAnyfrom("192.168.1.15:53") (anyfrom_pool.go:184)
      → d.ListenPacket("udp", "192.168.1.15:53")
      → FAIL: bind: address already in use
```

**根因**: dae 自身 DNS 监听器已占用端口 53，`sendPkt` 尝试绑定同一地址失败。说明存在 DNS 回环场景。

**影响**: 13 条错误，频率低（约每 30-90 秒一次），但每次导致该 DNS 响应丢失。

**代码归属**: dae 原始代码（`udp.go`/`anyfrom_pool.go`），非 dns_fix 引入。

#### F4 [中] handlePkt 错误日志无节流机制，产生日志风暴

**代码位置**: `control_plane.go:859` 和 `control_plane.go:994`

**对比**: DNS ingress queue full 已有节流（`dnsIngressQueueLogEvery=100`），但 `handlePkt` 错误日志**没有任何节流**。

**影响**: 5,000 条 warn 在 58 分钟内。有用信息被淹没。

**代码归属**: dae 原始代码（`control_plane.go`），非 dns_fix 引入。

#### F5 [低] UdpEndpoint handler 中 sendPkt 失败导致静默退出接收循环

**代码路径**: `udp_endpoint_pool.go:40-58`
```go
func (ue *UdpEndpoint) start() {
    for {
        n, from, err := ue.conn.ReadFrom(buf[:])
        if err != nil { break }
        if err = ue.handler(buf[:n], from); err != nil {
            break  // handler 返回错误时静默退出循环
        }
    }
}
```

**影响**: endpoint 失效但未从池中清除，直到 NAT 超时。

**代码归属**: dae 原始代码，非 dns_fix 引入。


#### F6 [严重] CLOSE-WAIT TCP socket 大量堆积 — 归属非 DNS 代理路径（broken-pipe-fix）
> 基于 `.plan/test-log.md` L636-L689 的 T1 调查结论，更新 F6 归属。


**证据对比**:
| 分支 | 采集 | CLOSE-WAIT max | Scenario C |
|---|---|---|---|
| main (Jan 5) | #1, #2 | 3, 7 | 14 |
| dns_fix (Feb 20) | #3, #4, #5 | **111**, **54**, **24** | **0** |

**T1 关键结论（2026-02-20）**:
1. `DoTCP.Close()` 会调用 `d.conn.Close()`；direct dialer 无连接池，最终执行 `net.TCPConn.Close()`。
2. `ss -tnp state close-wait | grep dae` 实测 remote 全部为 `163.177.58.13`（IEPL 节点端口 `:12101/:11105`）。
3. DNS upstream 为 `192.168.1.8:5553`，CLOSE-WAIT 中无该地址。

**归属判定**:
- F6 不属于 `newDnsForwarder/defer forwarder.Close()` 的 DNS forwarder 关闭路径问题。
- F6 属于非 DNS UDP 代理流量经 IEPL TCP 隧道路径的问题，修复分支应为 `main -> broken-pipe-fix`（与 F1/F2 同链路）。

**影响**:
- 每个 CLOSE-WAIT socket 占一个 fd。峰值 111 + 持续波动堆积，存在长跑 fd 累积风险。
- 这是 **2nd 审计 F4（长跑退化）的贡献因子**。

### 第二部分：DNS 相关修复（在 dns_fix 分支继续开发）

~~#### F7 [高] DNS 入队阻塞可堵死 UDP 读循环（引用 2nd 审计 F1）~~

**⚠️ 重要发现: enqueueDnsIngressTask 已在 PR#9 中修复为非阻塞（有 default 分支），F7/S6 无需额外开发。**

~~已在 2nd 审计中详细分析。`enqueueDnsIngressTask` 的阻塞 `select` 在队列满时堵死 UDP 读循环。~~

~~**与 broken pipe 的关联**: broken pipe → worker 卡在 TCP 超时 → 队列消费骤降 → 队列满 → 入队阻塞 → UDP 读循环堵死 → DNS 请求无法接收 → 客户端 dig 超时。~~

~~**已由 DNS Ingress 可配置化 PR#9 (commit 3a308b92) 部分缓解**（扩大 worker/queue 参数），但根因（broken pipe 导致 worker 超时）未解决。~~

~~**代码归属**: dae 原始代码中的 `enqueueDnsIngressTask`，但 dns_fix 分支的 DNS worker 路径受影响。~~

---

## 方案建议

### 第一部分：非 DNS 相关修复（在 main 分支创建新分支开发）

#### S1 [针对 F1/F2] broken pipe 后标记 dialer 不健康 + 重试避开

**方案**: 在 `handlePkt()` 非 DNS 路径 `ue.WriteTo()` (L285) 失败后，增加 dialer 错误反馈：
```go
_, err = ue.WriteTo(data, dialTarget)
if err != nil {
    if isBrokenPipe(err) {
        ue.Dialer.ReportUnhealthy(networkType)  // 新增
    }
    _ = DefaultUdpEndpointPool.Remove(realSrc, ue)
    retry++
    goto getNew  // retry 时 dialerGroup.Select() 避开不健康 dialer
}
```

**修复原则**: 优先在 dae 原始代码上改进（根因在原始代码的 `udp.go`）。

**验证方法**:
1. 部署修复后，运行 `dae_triage_unified_v5.sh --service dae --enable-tcpdump --enable-strace --peer-ip 163.177.58.13`
2. 人工断开一个 IEPL 节点的 TCP 隧道（或等待自然断连）
3. **预期**: broken pipe 后 retry 选择其他健康节点，同一源端口不再重复出现 broken pipe
4. **成功标准**: 同一源端口的 broken pipe 次数从 8+ 降至 ≤2（MaxRetry 次数内）

#### S2 [针对 F3] sendPkt 对自身监听地址的特殊处理

**方案**: 在 `sendPkt` 中，当 `from` 地址是 dae 自身的 DNS 监听地址时，使用传入的 `lConn` 回写：
```go
func sendPkt(..., from netip.AddrPort, ..., lConn *net.UDPConn) error {
    if from == daeListenAddr {
        _, err = lConn.WriteToUDPAddrPort(data, realTo)
        return err
    }
    uConn, _, err := DefaultAnyfromPool.GetOrCreate(from.String(), AnyfromTimeout)
    ...
}
```

**修复原则**: 根因在 dae 原始代码（`udp.go`/`anyfrom_pool.go`）。

**验证方法**:
1. 部署修复后，监控 `journalctl -u dae | grep "address already in use"` 30 分钟
2. **预期**: 不再出现 `bind: address already in use` 错误
3. **成功标准**: 30 分钟内零 bind 错误（原频率约每 30-90 秒一次）

#### S3 [针对 F4] handlePkt 错误日志增加节流

**方案**: 参考 `onDnsIngressQueueFull` 模式（`dnsIngressQueueLogEvery=100`），为 `handlePkt` 错误增加 per-error-type 节流：
- 首次打印完整信息
- 之后每 N 次（如 100 次）打印汇总 + 累积计数

**修复原则**: 根因在 dae 原始代码（`control_plane.go`）。

**验证方法**:
1. 部署修复后，触发 broken pipe 高峰期（等待自然断连或手动断开 IEPL 节点）
2. 观察 `journalctl -u dae | grep handlePkt` 日志频率
3. **预期**: 从 250 条/分钟降至 ≤5 条/分钟（首次 + 每 100 次汇总）
4. **成功标准**: 日志中包含 "累计 N 次" 汇总信息，且单分钟 warn 行数 ≤10

#### S4 [针对 F5] UdpEndpoint 静默退出时打印日志并主动清除

**方案**: `UdpEndpoint.start()` 的 break 路径增加日志 + 主动从池中 Remove。

**修复原则**: 根因在 dae 原始代码。

**验证方法**:
1. 部署后观察 broken pipe 场景下是否有新的 "UdpEndpoint handler error, removing from pool" 日志
2. **成功标准**: endpoint 错误时日志可见，且 endpoint 被立即从池中清除

#### S5 [针对 F6] CLOSE-WAIT 堆积治理（已迁移到 broken-pipe-fix）

**归属依据**: `.plan/test-log.md` L636-L689 的 T1 已确认 CLOSE-WAIT 来源为 IEPL 非 DNS 代理路径，`DoTCP.Close()` 实现正确，dns_fix 分支的 DNS forwarder 关闭逻辑无需修改。

**实施方向（并入 broken-pipe 方案）**:
1. 在 `handlePkt(isDns=false)` 写失败路径落实 S1：`ReportUnavailable` + endpoint 重建重试，减少对断裂隧道重复写入。
2. 在 `UdpEndpoint` 生命周期落实 S4：错误退出后尽快从池中清理，缩短 FIN 后本端连接滞留窗口。
3. 将 CLOSE-WAIT 观测纳入 broken-pipe 任务验收，而非 DNS 分支验收。

**验证方法**:
1. 部署 `broken-pipe-fix` 后，运行 `dae_triage_unified_v5.sh --service dae --enable-tcpdump --enable-strace --peer-ip 163.177.58.13`
2. 同时监控 `ss -tnp state close-wait | grep dae`
3. **预期**: CLOSE-WAIT max 从 111 降至 ≤10，且 remote 仍仅为 IEPL 节点地址
4. **回归检查**: Scenario C 维持为 0（不回退 dns_fix 既有修复）

### 第二部分：DNS 相关修复（在 dns_fix 分支继续开发）

~~#### S6 [针对 F7] enqueueDnsIngressTask 非阻塞入队（引用 2nd 审计 S1）~~

**⚠️ 重要发现: enqueueDnsIngressTask 已在 PR#9 中修复为非阻塞（有 default 分支），F7/S6 无需额外开发。**

~~**方案**: 已在 2nd 审计中详述。`enqueueDnsIngressTask` 增加 `default` 非阻塞分支。~~

~~**验证方法**:~~
~~1. 压测：`dnsperf` 或 `dnsgenerator` 对 dae DNS 发送高负载（5000+ QPS）~~
~~2. 同时人工触发 IEPL 节点断连（制造 broken pipe 高峰）~~
~~3. **预期**: DNS 查询延迟不因 broken pipe 而急剧上升~~
~~4. **成功标准**: P95 延迟 ≤500ms（当前 broken pipe 高峰时探测失败率 4.25%）~~

#### S7 [针对 F4 的 DNS 部分] DNS worker 路径 handlePkt 错误日志节流
**目标**: 减少 DNS worker 路径的日志风暴

---

## 根因总结

| # | 问题 | 根因 | 严重程度 | 代码归属 | 修复分支 |
|---|---|---|---|---|---|
| F1 | 持续 broken pipe | IEPL 代理 TCP 隧道断裂 + dae 在对端 FIN 后持续写入 | 严重 | dae 原始代码 (`udp.go`) | main→新分支 |
| F2 | 重试不改变 dialer 选择 | `dialerGroup.Select()` 未感知 broken pipe | 高 | dae 原始代码 (`udp.go`) | main→新分支 |
| F3 | bind: address already in use | `sendPkt` 绑定 dae 自身 :53 端口 | 高 | dae 原始代码 (`udp.go`) | main→新分支 |
| F4 | 日志风暴 | `handlePkt` 错误无节流 | 中 | dae 原始代码 (`control_plane.go`) | main→新分支 |
| F5 | endpoint 静默失效 | `UdpEndpoint.start()` 静默退出 | 低 | dae 原始代码 (`udp_endpoint_pool.go`) | main→新分支 |
| **F6** | **CLOSE-WAIT 大量堆积** | **非 DNS UDP 代理路径（IEPL 隧道）连接关闭滞后，非 DoTCP.Close 路径问题** | **严重** | **dae 原始代理路径（`udp.go`/endpoint 生命周期）** | **main→broken-pipe-fix** |
| F7 | DNS 入队阻塞堵死读循环 | `enqueueDnsIngressTask` 无 default 分支 | 高 | dae 原始代码 (受 dns_fix 影响) | dns_fix |

### Triage 定责汇总（5 次采集合计）

| 场景 | 事件数 | 说明 |
|---|---|---|
| Scenario A (FIN→RST) | **183** | 对端优雅关闭后 dae 继续写入 → **dae 设计问题** |
| Scenario B (RST only) | 14 | 对端/网络异常断开 → 对端问题 |
| Scenario C (EPIPE ignored) | 14 | dae 在 EPIPE 后仍继续写入 → **dae 实现 bug**（仅 main 分支） |
| Proper Handling | 128 | dae 正确处理 → 无问题 |
| graceful_fin | 6 | 对端 FIN, dae 未写入, 无 RST → 正常关闭 |

---

## 建议的落地优先级

### 优先级 1：main→broken-pipe-fix（非 DNS 主链路，含 F6/S5 迁移项）

| 顺序 | 方案 | 对应发现 | 理由 |
|---|---|---|---|
| 1 | **S5**: CLOSE-WAIT 堆积治理（迁移项） | F6 | T1 已确认归属非 DNS 代理路径，需在 broken-pipe 分支治理 |
| 2 | **S1**: dialer 健康反馈 + 重试避开 | F1/F2 | "治本"修复，阻止持续向断裂隧道写入 |
| 3 | **S3**: handlePkt 日志节流 | F4 | 最小改动，立即减少噪声 |
| 4 | **S2**: sendPkt :53 绑定冲突 | F3 | 低频 bug，修复清晰 |
| 5 | **S4**: UdpEndpoint 静默退出 | F5 | 可观测性改进 |

### 优先级 2：dns_fix 分支（DNS 相关）

| 顺序 | 方案 | 对应发现 | 理由 |
|---|---|---|---|
| 1 | **S6**: enqueueDnsIngressTask 非阻塞 | F7 | 已在 PR#9 完成，当前仅保留回归确认 |

---

## 与第二次代码审计的交叉分析

### 数据对照：冷启动 vs 10 小时后

| 指标 | 冷启动 (00:41) | 10 小时后 (08:56) | 退化幅度 |
|---|---|---|---|
| 成功率 | 800/800 (100%) | 766/800 (95.75%) | -4.25% |
| 失败数 | 0 | 34 | +34 |
| DNS P50 | 0.001s | 0.034s | 34x |
| DNS P90 | 0.067s | 0.127s | 1.9x |

### handlePkt 错误与探测失败的时空重叠

在探测失败的 08:56-08:58 窗口内，handlePkt.csv 记录了 **552 条 broken pipe 错误**（08:57 达到峰值 250 条/分钟）。

| 时间段 | handlePkt 错误/分钟 | 探测失败数 |
|---|---|---|
| 08:55 | 158 | — |
| 08:56 | 160 | 7 |
| 08:57 | **250**（峰值） | **10** |
| 08:58 | 142 | 7 |

**因果链（已修正 DNS 路径分析）**:
```
IEPL 代理节点 TCP 隧道断裂（外部事件）
  → 非 DNS 的 UDP 代理流量（fallback: HK）持续写入断裂隧道 → broken pipe
    → DNS worker 中处理非 DNS 代理包的 handlePkt() 卡在 TCP 超时
      → dnsIngressQueue(2048) 填满
        → enqueueDnsIngressTask 阻塞（F7）
          → UDP 读循环堵死
            → DNS 请求无法被接收 → 客户端 dig 超时

  同时（F6 贡献链）：
  → CLOSE-WAIT socket 持续堆积 → fd 资源渐渐耗尽 → 长跑退化
```

### 综合关联矩阵

| 2nd 审计发现 | 与 broken pipe 关联度 | triage 补充证据 |
|---|---|---|
| F1: 入队阻塞 | **强关联** — broken pipe 是触发器 | Scenario A 证实 dae 在 FIN 后持续写入, 占用 worker |
| F2: AnyfromPool ttl<=0 | 无关联 | — |
| F3: reload 未排空队列 | 间接关联 | — |
| F4: 长跑首秒超时簇 | **直接因果** | F6(CLOSE-WAIT=111) 是长跑退化的又一贡献因子 |
