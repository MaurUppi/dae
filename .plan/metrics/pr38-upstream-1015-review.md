# PR #38 审查报告：将推向上游（daeuniverse/dae#1015）的 metrics 代码

- 审查对象：MaurUppi/dae#38（已合并，merge commit `a25e50e`，head `fe27ea6`）
- 关注范围：PR #38 中**会推送到上游 PR daeuniverse/dae#1015** 的 metrics 代码（#1015 head = `feat/metrics-endpoint-clean` @ `8573436`，base = 上游 `17cc1de`）
- 审查日期：2026-10-02
- 目标：找出“最佳但不过度优化”的修复方案

---

## 1. 摘要与结论

**结论：#1015 在当前状态下不建议合并。需要先合入一个小型修复提交（约 8 个文件），覆盖 2 个 P0 和 4 个 P1 问题。**

| 级别 | 数量 | 一句话概括 |
|---|---|---|
| **P0** | 2 | ① `link` 标签把代理节点的密码/UUID 导出到 `/metrics`；② 同组内节点重名会让整个 `/metrics` 返回 HTTP 500 |
| **P1** | 4 | TCP 健康序列重复导出；`dae_dns_cache_hit_total` 的 HELP 与实际语义不符；只设密码时 BasicAuth 被静默关闭；示例配置默认监听 `0.0.0.0` |
| **P2** | 3 | TLS 权限精确匹配会拒绝更严格的权限，另有一个函数是死代码；`dae_health_check_total` 把“无结论”的检查也计入；PR 需要 rebase，面板位置也不合适 |
| **P3** | 5 | 只记录、不建议在本轮修改（避免过度优化） |

另外，审查确认 PR #38 的 reload 生命周期重构本身是正确的：`adoptPreparedGeneration` 是唯一的发布点，`managementServers` 只由 Run 所在的 goroutine 访问，reload 前会先预校验配置。审查中没有发现并发或生命周期缺陷。

---

## 2. 审查范围与方法

### 2.1 fork main 与 #1015 是否为同一份代码？

方法：用 GitHub API 读取 #1015 head（`8573436`）下各文件的 blob SHA，再与本地 `git rev-parse a25e50e:<path>` 逐个比对。

| 结果 | 文件 |
|---|---|
| **相同（40 个）** | `cmd/{endpoint_config,management_servers,management_servers_test,reload_adoption_test,reload_manager,run,run_reload_worker,run_test}.go`；`control/{connection_metrics,connection_metrics_test,control_plane,dns_cache_metrics_test,dns_control,dns_controller_handle,dns_controller_response,dns_metrics,dns_metrics_test,dns_preference_wait_test,dns_singleflight_test,node_latency,tcp,udp,udp_task_pool}.go`；`pkg/metrics/*`（7 个）；`pkg/metricshttp/*`（3 个）；`common/file_permission{,_test}.go`；`config/config.go`；`example.dae`；`go.mod`；`go.sum`；`component/outbound/dialer_group.go` |
| **不同（1 个）** | `component/outbound/dialer/connectivity_check.go`：fork 额外带有 `e956321`（动态 CheckOpts / 移除 IPv6 probe skip）。#1015 的提交说明写明 “The probe list (CheckOpts) is unchanged”，只包含 metrics 访问器与计数器 |

**推论**：本报告列出的问题**同时存在于 fork main 和 #1015**。同一个修复补丁可以直接应用到两边；`check()` 函数在两边也完全一致。

### 2.2 #1015 的提交结构（5 个）

| 提交 | 内容 |
|---|---|
| `78ea02c` | `pkg/metricshttp`、TLS 权限检查、`endpoint_*` 配置 |
| `1d9686f` | `pkg/metrics` 各采集器，以及 control/dialer 的只读访问器 |
| `f6b01e8` | TCP/UDP/DNS 埋点 |
| `cbf59fc` | `cmd`：management server 生命周期、reload 发布点 |
| `8573436` | Grafana 面板（`.plan/metrics/dae_Transparent_Proxy-Grafana_dashboard.json`） |

### 2.3 方法说明

- 静态审查上述全部 Go 代码，并沿调用链追到 v2.1.1 的 dialer、health 和 reload 子系统。
- 读取 outbound 依赖（`olicesx/outbound@cc86ced2e683`）中 `ExportToURL()` 的源码，确认 `Property.Link` 里有什么。
- **实证实验**：在独立的 scratchpad 模块中，用与仓库相同版本的 `client_golang v1.19.1` 复现了 P0-2（输出见 §3.2）。
- 本轮只做审查，没有改动仓库中的任何代码。

---

## 3. 逐条发现

> 行号以 fork main `a25e50e` 为准。由于文件逐字节相同，这些行号同样适用于 #1015 head `8573436`。

### 3.1 【P0-1 安全】`link` 标签泄露代理凭据

**现象**
`pkg/metrics/collector_runtime.go:50-61` 定义了 `dae_node_latency_seconds` 和 `dae_node_alive`，标签为 `{group, name, link}`；`:89-100` 把 `node.Link` 原样写入标签。`node.Link` 来自 `control/node_latency.go:71-79` 的 `d.Property().Link`。

**`Link` 的实际内容**（已读取 outbound 源码确认）

| 协议 | 源码位置 | 包含的敏感信息 |
|---|---|---|
| Trojan | `dialer/trojan/trojan.go:133` 处 `Link: s.ExportToURL()`；`:176` 处 `User: url.User(t.Password)` | **明文密码** |
| Shadowsocks | `dialer/shadowsocks/shadowsocks.go:165,455` | `base64(cipher:password)`，可直接解码 |
| VLESS / VMess | `dialer/v2ray/v2ray.go:315,449` | VLESS 是 `url.User(s.ID)`（UUID）；VMess 是整个 JSON 的 base64，其中含 ID |

**影响**
- 凡是能访问 `/metrics` 的人，都能拿到**所有代理节点的完整凭据**。默认没有 BasicAuth，而 `example.dae` 示例的监听地址是 `0.0.0.0:5556`（见 P1-4）。
- 凭据还会进入 Prometheus TSDB、远程存储和 Grafana，且会在其中长期保留。
- 风险对象是路由器或网关上的 dae，暴露面很大。

**推荐方案：删除这两个指标，而不是改造它们**

理由：
1. 它们与 `dae_dialer_alive` / `dae_dialer_latency_last_seconds{network="tcp4"|"tcp6"}` 的信息**冗余**。
2. #1015 自己的 Grafana 面板**没有用到** `dae_node_*`（已在 `8573436` 的面板 JSON 中检索确认）。
3. 如果只删掉 `link`、保留 `{group, name}`，又会落入 P0-2 的重名问题。
4. 删除可以让上游 diff 变小：`control/node_latency.go` 中新增的 `Name`/`Group` 字段可以一并回退。

```diff
--- a/pkg/metrics/collector_runtime.go
+++ b/pkg/metrics/collector_runtime.go
@@ type RuntimeCollector struct {
 	uploadRateBytesPerSecond   *prometheus.Desc
 	downloadRateBytesPerSecond *prometheus.Desc
-	nodeLatencySeconds         *prometheus.Desc
-	nodeAlive                  *prometheus.Desc
 }
@@ func NewRuntimeCollector
-		nodeLatencySeconds: prometheus.NewDesc("dae_node_latency_seconds", ..., []string{"group", "name", "link"}, nil),
-		nodeAlive:          prometheus.NewDesc("dae_node_alive", ..., []string{"group", "name", "link"}, nil),
@@ func (c *RuntimeCollector) Describe
-	ch <- c.nodeLatencySeconds
-	ch <- c.nodeAlive
@@ func (c *RuntimeCollector) Collect
-	for _, node := range cp.SnapshotNodeLatencies() {
-		...
-	}
--- a/control/node_latency.go
+++ b/control/node_latency.go
-	Name      string // human-readable dialer name, e.g. "香港标准 IEPL 专线 1"
-	Group     string // outbound group name, e.g. "FC_HK"
...
-			snapshot.Name = d.Property().Name
-			snapshot.Group = group.Name
```

测试同步修改：把 `pkg/metrics/collector_describe_test.go:98` 的 `TestRuntimeCollectorDescribeIncludesRuntimeAndNodeDescriptors` 改为只断言 4 个 runtime 描述符，并增加一条断言：没有任何描述符带有 `link` 标签。

### 3.2 【P0-2 可用性】同组内节点重名导致整个 `/metrics` 返回 500

**现象**
- `pkg/metrics/collector_dialer.go:125` 的标签是 `{group.Name, prop.Name, typ.String()}`。
- `component/outbound/filter.go:150` 的 `NewDialerSetFromLinksContext` **不对节点名去重**。多订阅场景下（例如两个机场都有“香港 01”），配合 `filter: name(keyword: 香港)`，同一组内会出现同名 dialer。
- `pkg/metricshttp/server.go:44` 使用 `promhttp.HandlerOpts{}`，其 `ErrorHandling` 默认值是 `HTTPErrorOnError`。

**实证**（独立模块，`client_golang v1.19.1`，构造两个 `{group="HK",dialer="香港 01",network="tcp4"}` 序列加一个正常 counter）：

```text
HandlerOpts{}: status=500 body="An error has occurred while serving metrics:
  collected metric "dae_dialer_alive" { ... dialer="香港 01" group="HK" network="tcp4" ... }
  was collected before with the same name and label values"
ContinueOnError: status=200 body="... dae_dialer_alive{dialer="香港 01",group="HK",network="tcp4"} 1
  ... dae_dns_query_total 42"
```

**影响**
只要配置里出现一次重名，**整个 endpoint 就不返回任何指标**：DNS、连接、runtime 指标全部丢失，Prometheus 判定 target down。在多订阅用户中，这是高概率触发的问题（初步判断，数据未充分确认：触发比例没有统计数据）。

**推荐方案：两处改动，都很小**

(a) 在采集器内按组为重名追加后缀，让标签保持唯一：

```go
// dialerMetricName keeps label sets unique when a group holds several nodes
// with the same name (common with multiple subscriptions): a duplicate label
// set fails the whole scrape.
func dialerMetricName(seen map[string]int, name string) string {
	seen[name]++
	if n := seen[name]; n > 1 {
		return fmt.Sprintf("%s #%d", name, n)
	}
	return name
}
```

(b) 用 `ContinueOnError` 兜底。这样以后任何一个采集器出现标签冲突，都不会再让整个 endpoint 失效：

```diff
--- a/pkg/metricshttp/server.go
+++ b/pkg/metricshttp/server.go
-				promhttp.HandlerFor(registry, promhttp.HandlerOpts{}),
+				promhttp.HandlerFor(registry, promhttp.HandlerOpts{ErrorHandling: promhttp.ContinueOnError}),
```

权衡说明：
- 后缀依赖 `group.Dialers` 的顺序，而该顺序来自 map 遍历，所以 reload 之后 “#2” 可能指向另一个节点。同一代 generation 内是稳定的，可以接受。
- 如果要做到跨 reload 稳定，就得引入订阅 tag 或链接哈希这类新标签，并改动标签 schema，属于过度设计，本轮不建议。
- 仅靠 (b) 不够：重复的那一条会被静默丢弃，而且每次抓取都会产生一次错误。所以 (a) 才是主修复，(b) 是防线。

### 3.3 【P1-1 正确性】`tcp4(DNS)` / `tcp6(DNS)` 与 `tcp4` / `tcp6` 重复导出

**现象**
- v2.1.1 把 TCP 统一为一个健康域。`component/outbound/dialer/dialer.go:296-297` 中 `collections[IdxDnsTcp4] = collections[IdxTcp4]`、`collections[IdxDnsTcp6] = collections[IdxTcp6]`。
- `component/outbound/dialer_group.go:481-483` 对 `aliveDialerSets` 也做了同样的别名。上游自己的 `uniqueAliveDialerSets`（`dialer_group.go:610`）正是为了处理这种别名而存在的。
- 但 `collector_dialer.go:17-26` 仍沿用 v2.1.1 之前的 8 类型表，于是每个 dialer 的 6 个指标中，TCP 部分以 `network="tcp4(DNS)"` 和 `"tcp4"` 两种标签**各导出一次**，`dae_group_alive_dialers_total` 也一样。

**影响**
- 跨 network 聚合会把 TCP 重复计算，例如 `sum by (group) (increase(dae_health_check_total[1h]))` 中 TCP 部分被算两次。
- 每个 dialer 多出 2/8 = 25% 的序列。
- #1015 的面板因为用了 `network!~".*DNS.*"` 过滤，没有直接受影响；但用户自己写的查询会受影响。

**推荐方案**
改为遍历上游的权威列表 `dialer.StandardHealthKeys()`（6 个互不相同的健康域），并改用已有的 `MustGetAliveDialerSet`。这样新增的 `DialerGroup.AliveDialerSets()` 就可以删除，进一步缩小上游 diff：

```go
// dialerMetricNetworkTypes lists each distinct health collection once.
// tcp4(DNS)/tcp6(DNS) share the tcp4/tcp6 collection and alive set
// (see NewDialerContext and buildSelectionState), so they are not exported.
var dialerMetricNetworkTypes = func() (types [6]*dialer.NetworkType) {
	for i, key := range dialer.StandardHealthKeys() {
		types[i] = key.NetworkType()
	}
	return types
}()

// in Collect, per group:
	seen := make(map[string]int, len(group.Dialers))
	for _, d := range group.Dialers {
		// ... nil checks unchanged ...
		name := dialerMetricName(seen, prop.Name)
		for _, typ := range dialerMetricNetworkTypes {
			alive, lastLatency, avg10, movingAvg, hasLastLatency := d.GetCollectionState(typ)
			labels := []string{group.Name, name, typ.String()}
			// ... emits unchanged ...
		}
	}
	for _, typ := range dialerMetricNetworkTypes {
		if set := group.MustGetAliveDialerSet(typ); set != nil {
			ch <- prometheus.MustNewConstMetric(c.groupAliveDialers, prometheus.GaugeValue,
				float64(set.Len()), group.Name, typ.String())
		}
	}
```

```diff
--- a/component/outbound/dialer_group.go
+++ b/component/outbound/dialer_group.go
-func (g *DialerGroup) AliveDialerSets() [8]*dialer.AliveDialerSet {
-	return g.currentSelectionState().aliveDialerSets
-}
```

兼容性：保留下来的 6 个 label 值（`tcp4`、`tcp6`、`udp4(DNS)`、`udp6(DNS)`、`udp4`、`udp6`）与现状**逐字相同**。现有查询只要不显式依赖 `tcp4(DNS)` / `tcp6(DNS)`，就不受影响。

### 3.4 【P1-2 语义】`dae_dns_cache_hit_total` 的 HELP 与实际语义不符

**现象**
- `pkg/metrics/collector_dns.go:67` 的 HELP 写的是 “Total number of **fresh** DNS cache hits”。
- 但 `control/dns_metrics.go:234-244` 的 `noteDNSCacheServed` 对 lazy（陈旧）命中也会执行 `dnsCacheHitTotal.Add(1)`。测试 `TestDNSStaleServedRefreshCountsLazyHit` 明确断言了 `hit=1, lazy=1`。

**影响**
- 指标一旦进入上游就成为公共 API，HELP 写错会误导所有使用者。
- #1015 的面板已经按 “hit 包含 lazy” 来计算（新鲜命中 = `hit - lazy`），是正确的。
- **fork 仓库**中的旧面板（`.plan/metrics/dae Transparent Proxy-Grafana_dashboard.json` 和 `.plan/metrics/dae-dashboard.json`）却用 `hit + lazy` 计算“总命中率”，**重复计入了 lazy**；“Fresh Hit Ratio = hit/query” 实际也包含陈旧命中。

**推荐方案**

```diff
-			"Total number of fresh DNS cache hits",
+			"Total number of DNS queries answered from the response cache, including stale (lazy) hits also counted in dae_dns_cache_lazy_hit_total",
```

fork 侧：用 #1015 的面板文件替换上述两个旧面板。

### 3.5 【P1-3 安全】只设 `endpoint_password` 时 BasicAuth 被静默关闭

**现象**
`pkg/metricshttp/auth.go:14`：`if username == "" { return handler }`。如果用户只写了密码，以为已经开启了保护，实际上 endpoint 是完全开放的。反过来，只写用户名时，密码会被要求为空字符串，同样不符合预期。

**推荐方案**：在 `cmd/management_servers.go` 的 `resolveManagementServers` 中，构建 `cfg` 之后增加校验。由于 reload 前已经会预校验，这个改动也自动覆盖了 reload 路径：

```go
if (cfg.Username == "") != (cfg.Password == "") {
	return managementPlan{}, fmt.Errorf("endpoint_username and endpoint_password must be configured together")
}
```

测试：在 `TestResolveManagementServers` 的表中增加两条用例（只有用户名、只有密码），都期望返回错误。

### 3.6 【P1-4 安全默认值】`example.dae` 示例监听 `0.0.0.0:5556`

**现象**
`example.dae:39` 是 `#endpoint_listen_address: '0.0.0.0:5556'`。dae 常部署在路由器上，用户照抄示例就会把 endpoint 绑定到所有接口，可能包括 WAN。即使修复了 P0-1，指标里仍有节点名、组名和 DNS 上游地址。

**推荐方案**

```diff
-    # Set a listen address to enable the endpoint server (disabled by default).
-    #endpoint_listen_address: '0.0.0.0:5556'
+    # Set a listen address to enable the endpoint server (disabled by default).
+    # Metrics reveal node, group and DNS upstream names: keep it on loopback or a
+    # LAN address, and set endpoint_username/endpoint_password (and TLS) first.
+    #endpoint_listen_address: '127.0.0.1:5556'
```

### 3.7 【P2-1】TLS 权限是精确匹配，会拒绝更严格的权限；另有一个函数是死代码

**现象**
- `cmd/endpoint_config.go:57` 规定证书只能是 `0640` 或 `0644`；`:70` 规定私钥只能是 `0600`。于是 `0400` 的私钥会被拒绝，尽管它更安全；`0600` 或 `0444` 的证书也会被拒绝，而 Caddy、acme.sh 等工具常生成这类权限（初步判断，数据未充分确认：各工具的默认权限未逐一核实）。
- `common/file_permission.go:15` 的 `ValidateFilePermissionNotTooOpen` **没有任何调用者**（`grep` 确认），是死代码。它与上游已有的 `config/config_merger.go:78`、`common/subscription/subscription.go:128` 中的内联检查重复。

**推荐方案**：改为“禁止位”检查，与上游现有的 `0037` 掩码风格保持一致。两个函数合并为一个：

```go
// ValidateFilePermissionForbidden rejects a directory, or a file whose
// permission bits include any of forbidden.
func ValidateFilePermissionForbidden(path string, fi os.FileInfo, forbidden os.FileMode) error {
	if fi.IsDir() {
		return fmt.Errorf("cannot read a directory: %v", path)
	}
	if perm := fi.Mode().Perm(); perm&forbidden != 0 {
		return fmt.Errorf("permissions %04o for '%v' are too open; bits %04o must not be set", perm, path, forbidden.Perm())
	}
	return nil
}
```

调用方式：证书用 `0o022`（同组和其他用户不可写），私钥用 `0o077`（同组和其他用户不可访问）。同时更新 `example.dae:42` 的注释和 `common/file_permission_test.go`。

更小的备选方案：保留 `ValidateFilePermissionAllowed`，只扩充允许列表（证书加 `0600/0444/0440/0400`，私钥加 `0400`）。改动更少，但枚举式写法较笨拙，死代码问题也没有解决，因此不推荐。

### 3.8 【P2-2】`dae_health_check_total` 把“无结论”的检查也计入

**现象**
`component/outbound/dialer/connectivity_check.go:1413` 在 `check()` 入口无条件执行 `CheckTotal.Add(1)`。以下几种情况没有健康结论，却也被计入总数：
- context canceled（dialer 退役）
- `errCheckOptionUnavailable`（probe 基础设施失败）
- `ok=false, err=nil`（跳过）

它们不会计入 `CheckFailureTotal`（`:1486`），于是面板里的 `1 - failure/total` 成功率被系统性抬高。

**推荐方案**：把计数移到两个有结论的分支里，各 1 行：

```diff
-	d.mustGetCollection(opts.networkType).CheckTotal.Add(1)
 ...
 	case ok && err == nil:
 		d.collectionFineMu.Lock()
 		collection := d.mustGetCollection(opts.networkType)
+		collection.CheckTotal.Add(1)
 ...
 	case err != nil && !d.isLifecycleTeardownError(err) && !stderrors.Is(err, errCheckOptionUnavailable):
 ...
+		collection.CheckTotal.Add(1)
 		collection.CheckFailureTotal.Add(1)
```

另外，HELP 文本可以相应改为 “...health checks that produced a verdict”。

### 3.9 【P2-3 流程】rebase 与面板位置

- 上游 main 当前为 `e3fee8f`，比 #1015 的 base `17cc1de` 多 6 个提交：#1111、#1117（config Marshaller）、#1122、#1124（config 校验）、#1130、#1125。其中 #1117 和 #1124 涉及 `config/`，可能与 `config/config.go` 中新增的 `endpoint_*` 字段冲突（初步判断，数据未充分确认：尚未实际 rebase 验证）。
- 上游仓库（`dbae2e8`）**没有** `.plan/` 目录。把 Grafana 面板放进 `.plan/metrics/` 会引入一个上游原本不存在的内部目录。建议移到 `docs/`（上游自 #1100 起维护中英文手册），或者把 JSON 作为 PR 附件或单独的文档 PR 提交，由维护者决定。
- 上游文档目前没有 `endpoint_*` 的配置说明。建议至少在 PR 描述里给出配置示例，以及“对外暴露前需要认证和 TLS”的提示。

### 3.10 【P3】仅记录，本轮不建议修改

| 项 | 说明 | 不修改的理由 |
|---|---|---|
| `endpoint_prometheus_enabled` 默认 `false` | 只设置监听地址时，得到一个没有任何 handler 的 server（访问 `/metrics` 返回 404） | 属于配置语义选择。可以在 PR 中询问维护者：是改为默认 `true`，还是在 `start` 时打印一条警告 |
| DNS upstream 序列不清理 | `dnsUpstreamMetrics` 存放在跨 reload 共享的 store 中，上游配置被移除后，旧序列仍会继续导出 | 基数受配置约束；`asis` 上游统一记为 `"asis"`，不会膨胀 |
| `RouteDialTcpContext` 埋点 | 该导出函数在仓库内没有调用者（`control/tcp.go:384`） | 无害，只服务外部嵌入方；也可以删掉以缩小 diff |
| `pprof_port is deprecated` 警告 | `endpointConfigFromGlobal` 在 reload 预校验和 `apply` 时各执行一次，所以每次 reload 打印 2 次 | 只是日志噪声 |
| 端点地址冲突检测 | 只拒绝字符串完全等于 `localhost:<pprof_port>` 的地址；`127.0.0.1:<port>`、`:<port>` 不会被拦截，失败时只记日志 | 绑定失败有日志可查，补全需要做地址规范化，收益低 |

---

## 4. 修复落地策略

### 4.1 推荐流程

1. 在 `feat/metrics-endpoint-clean` 上追加**一个**提交 `fix(metrics): address review findings`，覆盖 §3.1 至 §3.8。
2. 将该分支 rebase 到上游最新 main（`e3fee8f`），解决冲突，然后重新跑 `go build`、`go vet`、golangci-lint、gofmt 和 SPDX 检查，并 force-push 到 PR 分支（这是 PR 作者自己的分支，force-push 可以接受）。
3. 把同一个修复提交 cherry-pick 到 fork 的新分支，向 fork main 提 PR。相关文件逐字节相同，预期可以干净应用（初步判断，数据未充分确认）。fork 侧另外用 #1015 的面板替换 `.plan/metrics/` 下的两个旧面板。

为什么选择“追加 1 个提交”，而不是把修复折进原来的 5 个提交：
- 对评审者来说，增量最清楚。
- 上游通常 squash 合并，提交历史的“洁癖”收益很低（初步判断，数据未充分确认：上游合并策略未逐一核实）。

### 4.2 预计改动规模（初步判断，数据未充分确认）

| 文件 | 改动 |
|---|---|
| `pkg/metrics/collector_runtime.go` | 删除 2 个 node 指标（约 −30 行） |
| `control/node_latency.go` | 回退 `Name`/`Group`（−4 行） |
| `pkg/metrics/collector_dialer.go` | 改用 6 个健康域，加入重名后缀（约 ±30 行） |
| `component/outbound/dialer_group.go` | 删除 `AliveDialerSets()`（−4 行） |
| `pkg/metricshttp/server.go` | 改用 `ContinueOnError`（1 行） |
| `pkg/metrics/collector_dns.go` | 修正 HELP（1 行） |
| `cmd/management_servers.go` | 用户名和密码成对校验（+3 行） |
| `cmd/endpoint_config.go` + `common/file_permission.go` | 改为禁止位检查，删除死代码（约 −30 行） |
| `component/outbound/dialer/connectivity_check.go` | 移动 `CheckTotal` 计数（±3 行） |
| `example.dae` | 改示例地址和注释（±4 行） |
| 测试 | 见 §4.3（约 +60 行） |

### 4.3 测试建议（适度即可，不为测试而重构）

- `dialerMetricName`：表驱动测试，覆盖不重名、重名两次、重名三次。
- `dialerMetricNetworkTypes`：断言共 6 个，`Index()` 两两不同，`String()` 恰好是 `{tcp4, tcp6, udp4(DNS), udp6(DNS), udp4, udp6}`。
- `pkg/metricshttp`：注册一个故意产生重复标签的采集器，断言 `/metrics` 返回 200 且其余指标仍在。这相当于把 §3.2 的实证固化为回归测试。
- `collector_describe_test.go`：断言没有任何 Desc 带 `link` 标签，runtime 采集器只有 4 个描述符。
- `TestResolveManagementServers`：增加用户名和密码只配其一的用例。
- `TestValidateEndpointTLSFilesChecksPermissions`：增加“私钥 0400 通过”“证书 0600 通过”“私钥 0640 拒绝”。
- **不建议**为测试 `Collect` 而给 `ControlPlane` 增加测试构造器。那需要导出内部字段，代价大于收益。

---

## 5. 风险与权衡：为什么不做更多

| 可选的更大改动 | 不做的理由 |
|---|---|
| 给 dialer 指标加 `subtag` 或链接哈希标签，做跨 reload 稳定的唯一标识 | 要改标签 schema，增加基数，还要解释哈希来源；重名后缀加 ContinueOnError 已经能消除故障 |
| 把连接计数器挪到共享 store，避免 reload 归零 | Prometheus 的 `rate()` 原生能处理计数器重置；PR #38 也已在说明中把它列为已知行为 |
| DNS upstream 序列按配置做 GC | 基数有上限，收益低 |
| 端点地址规范化与冲突预检 | 绑定失败有日志可查，规范化逻辑容易出现平台差异 |
| 在 fork 侧为 dae_node_* 做兼容层 | 冗余指标，fork 面板改用 #1015 的面板即可 |

---

## 6. 未核实事项清单

1. ~~#1015 rebase 到 `e3fee8f` 是否有冲突~~ → **已核实：无冲突**，两边改动的文件零重叠，见 §7。
2. ~~修复提交能否直接 cherry-pick~~ → **已核实**：同一个修复提交已干净应用到 fork 和 #1015 分支，见 §7。
3. 多订阅用户中同组节点重名的实际比例。（此信息/数据暂未核实完毕）
4. Caddy、acme.sh 等工具默认生成的证书和私钥权限。（此信息/数据暂未核实完毕）
5. 上游维护者对 `endpoint_prometheus_enabled` 默认值和面板存放位置的偏好。
6. 本报告的 P0 和 P1 都基于代码阅读和一次独立实证，**没有**在真实 dae 进程上做端到端抓取。建议修复后在测试机上用两个含重名节点的订阅实际抓一次 `/metrics` 验证。

---

## 7. 实施状态（2026-10-02 更新）

本节记录 P0–P2 修复的落地情况。按要求，P3 项本轮不处理。

### 7.1 各项发现的处理结果

| 发现 | 状态 | 实施要点 |
|---|---|---|
| §3.1 P0-1 `link` 凭据泄露 | 已修复 | 删除 `dae_node_latency_seconds` / `dae_node_alive`；`control/node_latency.go` 回退后与上游 v2.1.1 完全一致 |
| §3.2 P0-2 重名导致 500 | 已修复 | 新增 `dialerMetricName` 按组追加 ` #N` 后缀；`promhttp` 改用 `ContinueOnError` |
| §3.3 P1-1 TCP 序列重复 | 已修复 | 改为遍历 `dialer.StandardHealthKeys()`（6 个）；删除 `DialerGroup.AliveDialerSets()`，`dialer_group.go` 回退后与上游一致 |
| §3.4 P1-2 HELP 语义 | 已修复 | HELP 改为“包含 lazy 命中”；fork 的两个旧面板已替换为 #1015 的面板（blob `21ce121`） |
| §3.5 P1-3 认证被关闭 | 已修复 | 用户名和密码必须成对配置，否则启动或 reload 报错 |
| §3.6 P1-4 示例监听地址 | 已修复 | 示例改为 `127.0.0.1:5556`，并补充暴露风险说明 |
| §3.7 P2-1 TLS 权限 | 已修复 | 改用禁止位检查：证书为 `0o022`，私钥为 `0o077`；删除两个旧函数，新增 `ValidateFilePermissionForbidden` |
| §3.8 P2-2 检查计数 | 已修复 | `CheckTotal` 只在得出结论的成功或失败分支中计数 |
| §3.9 P2-3 rebase 与面板 | 已完成并推送 | 与上游 6 个新提交**没有任何文件重叠**，rebase 无冲突。面板保留在 `.plan/metrics/`，内容见 §7.4 |

### 7.2 提交

- fork（分支 `claude/laughing-sagan-ndu7a8`）：
  - `3c02657 fix(metrics): address review findings`：18 个文件，+322/−127。不计测试和 `example.dae`，生产代码净减约 42 行。
  - `ea9f706 docs(metrics): replace stale fork dashboards ...`：仅 fork 侧。
- 上游 PR 分支 `feat/metrics-endpoint-clean`（daeuniverse/dae#1015 的 head）：
  - 用 `--force-with-lease`（基准 `8573436`）推送：`8573436...5c9df67`。5 个原提交已 rebase 到上游 `e3fee8f`，修复提交为 `5c9df67`。
  - 面板修订作为快进提交追加：`5c9df67..8502e56`。
- fork 分支：`3006758` 依据 v6 修订面板，并把文件名改回 `dae Transparent Proxy-Grafana_dashboard.json`。

### 7.3 验证

验证环境与 CI 等价：go1.26.0、CI 的 GOEXPERIMENT、`-tags dae_stub_ebpf`、golangci-lint v2.11.0。

| 检查 | fork 分支 | 上游 rebase 分支 |
|---|---|---|
| `go build ./...` 与 `go vet` | 通过 | 6 个提交**逐个**通过 |
| 相关包测试（pkg、common、component/outbound、dialer、cmd、config、control 中与 metrics 相关的部分） | 通过 | 通过 |
| golangci-lint | 0 issues | 0 issues |
| gofmt 与 `go mod tidy` | 无差异 | 无差异 |

新增的回归测试已在**修复前的代码**上确认会失败：`TestPrometheusHandlerSurvivesCollectorError` 得到 `status=500`，`TestCheck_CountersCountOnlyVerdicts` 得到 `total=3`。修复后两者都通过。

### 7.4 Grafana 面板（基于 v6 修订）

- 基准文件：用户上传的 `dae_Transparent_Proxy-v6-1790143652539.json`。经深度比对，#1015 原有面板正是 v6 去除环境信息后的版本，差异只有 `id`、`version`、数据源 uid 和组选择这 4 处。v6 本身不使用 `dae_node_*`，DNS 缓存公式也已按“hit 含 lazy”编写。
- 修订内容（文本 diff 共 5 行）：
  - **D1**：`network` 变量去掉 `network!~".*DNS.*"` 过滤。重复的 `tcp4(DNS)` 序列已不存在，这个过滤器现在只会隐藏唯一被主动探测的 `udp4(DNS)`/`udp6(DNS)`。
  - **D2**：健康检查成功率的分母改为 `(sum(...) > 0)`。数据 UDP 没有检查，原写法会显示误导性的 100%，现在显示 No data。
  - **D3**：面板 202 与 203 的描述改为与“只统计得出结论的检查”一致。
- 文件位置：fork 侧为 `.plan/metrics/dae Transparent Proxy-Grafana_dashboard.json`；#1015 侧保留 `.plan/metrics/dae_Transparent_Proxy-Grafana_dashboard.json`。两者内容逐字节相同。
- 校验结果：
  - 程序化比对确认“结果等于对 v6 去环境化后再应用 D1–D3”；
  - 引用的 27 个 `dae_*` 指标全部由修复后的采集器导出；
  - 文件中不出现 `dae_node_`、`tcp4(DNS)` 或 `link`。

### 7.5 #1015 说明评论

本会话无法直接在 daeuniverse/dae 发评论：`add_repo` 因同名仓库目录冲突被拒，这是检出布局的限制，与权限无关。评论正文已交给仓库所有者手动发布。

## 8. 后续思考

- **Q1：** 如果 `/metrics` 已经被暴露过一段时间，凭据可能已经写入 Prometheus 或远程存储。是否需要提醒已部署 fork 的用户轮换节点密码或 UUID，并清理 TSDB 中的 `dae_node_*` 序列？
- **Q2：** 健康指标的 `network` 维度应该直接对齐 v2.1.1 的“健康域”（`tcp`、`dns_udp`、`data_udp`），还是继续沿用 `tcp4(DNS)` 这类旧字符串以保证兼容？这个选择会影响上游长期的指标契约。
- **Q3：** fork 独有的动态 CheckOpts（`e956321`）与 #1015 分叉。上游合并 #1015 之后，fork 每次同步都会在 `connectivity_check.go` 上产生冲突。是把它单独提交为上游 PR，还是在 fork 中长期作为补丁维护？
