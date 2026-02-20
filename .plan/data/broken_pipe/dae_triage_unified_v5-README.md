# dae Broken Pipe Accountability Triage (Unified v5)

用于对 `dae` 服务中的 `write: broken pipe` 事件做证据采集与定责分析。

脚本文件：`dae_triage_unified_v5.sh`

## 功能概览

- 实时监听 `journalctl` 日志中的目标模式（默认 `broken pipe`）
- 针对每个事件做多次连接快照（`ss` + fd 映射）
- 可选持续抓包（`tcpdump` 环形缓冲）
- 可选持续系统调用跟踪（`strace`）
- 自动生成：
  - 事件明细 `events.jsonl`
  - 汇总 `summary.json` / `summary.txt`
  - 定责报告 `accountability.txt`

## 采集与分析流程

1. 监听 `journalctl -u <service> -f -o json`
2. 发现匹配日志后创建事件目录 `raw/<event_id>/`
3. 在短窗口内做多次连接快照
4. 抽取该时段 `pcap` 和 `strace` 上下文（若启用）
5. 分别执行 pcap / strace 分析并写入事件结果
6. 持续刷新 summary，退出时生成最终 accountability 报告

## 快速开始

### 1) Dry-run（只检查参数）

```bash
sudo ./dae_triage_unified_v5.sh --dry-run
```

### 2) 基础模式（只看日志 + 连接快照）

```bash
sudo ./dae_triage_unified_v5.sh --service dae
```

### 3) 完整定责（推荐）

```bash
sudo ./dae_triage_unified_v5.sh \
  --service dae \
  --enable-tcpdump \
  --enable-strace \
  --peer-ip 163.177.58.13
```

按 `Ctrl-C` 结束，脚本会自动收尾并生成最终报告。

## 参数说明

| 参数 | 默认值 | 说明 |
|---|---|---|
| `--service NAME` | `dae` | systemd 服务名 |
| `--pid PID` | 自动解析 | 显式指定进程 PID |
| `--outdir DIR` | `dae-triage-YYYYmmdd-HHMMSS` | 输出目录 |
| `--pattern STR` | `broken pipe` | 日志匹配字符串 |
| `--peer IP:PORT` | `auto` | 固定对端地址；`auto` 时从日志解析 |
| `--peer-ip IP` | 空 | tcpdump 过滤 IP（仅抓该 host） |
| `--max-events N` | `0` | 最大事件数（0=不限） |
| `--window N` | `50` | summary 统计窗口大小 |
| `--snapshots N` | `5` | 每个事件采样次数 |
| `--interval-ms MS` | `200` | 采样间隔（毫秒） |
| `--enable-tcpdump` | off | 启用 tcpdump 环形缓冲 |
| `--tcpdump-buffer SEC` | `60` | tcpdump 轮转秒数（`-G`） |
| `--tcpdump-snaplen N` | `128` | tcpdump 抓包长度（`-s`） |
| `--enable-strace` | off | 启用 strace 持续跟踪 |
| `--strace-expr EXPR` | `write,writev,send,sendto,sendmsg,close,shutdown` | strace syscall 过滤 |
| `--dry-run` | off | 打印解析后的参数并退出 |
| `-h, --help` | - | 显示帮助 |

## 输出目录结构

```text
dae-triage-YYYYmmdd-HHMMSS/
├── events.jsonl
├── summary.json
├── summary.txt
├── accountability.txt
├── .tmp/
│   ├── counters.txt
│   └── window_flags.txt
├── tcpdump/                    # 启用 --enable-tcpdump 时
│   ├── cap_*.pcap
│   └── stderr.log
├── strace/                     # 启用 --enable-strace 时
│   ├── trace
│   └── stderr.log
└── raw/
    └── <event_id>/
        ├── log.json
        ├── snap_1.fdmap.txt    # 能解析 peer 时
        ├── snap_1.tuple.txt
        ├── snap_1.ss.txt       # 不能解析 peer 时
        ├── ...
        ├── pcap/
        │   └── *.pcap
        ├── strace/
        │   └── trace*
        ├── pcap_analysis.json
        └── strace_analysis.json
```

## 定责逻辑

### pcap 场景（`pcap_analysis.scenario`）

- `A_fin_then_rst`：观察到对端 FIN 后又有 RST，倾向 dae 在 FIN 后继续写
- `B_rst_only`：仅见对端 RST，倾向对端/网络异常断开
- `graceful_fin`：仅见 FIN，无 RST
- `no_close_packets`：窗口内未见 FIN/RST
- `unknown`：其他情况
- `no_pcap`：未启用 tcpdump 或无抓包文件

### strace 处理质量（`strace_analysis.error_handling`）

- `C_errors_ignored`：EPIPE 后仍继续写（实现缺陷）
- `proper_handling`：出现 EPIPE 且观察到 close，处理较正确
- `no_errors_captured`：窗口内没看到写错误
- `unclear`：证据不足
- `no_strace`：未启用 strace

### 最终结论（`accountability.txt`）

脚本按以下顺序给出结论：

1. `INSUFFICIENT_DATA`
2. `NO_EVENTS`
3. `ANALYSIS_PENDING`
4. `DAE_BUG: ERRORS_IGNORED`
5. `DAE_DESIGN_ISSUE`
6. `PEER_OR_NETWORK_ISSUE`
7. `MIXED_OR_PROPER`

其中 `total_analyzed = ScenarioA + ScenarioB + ScenarioC + ProperHandling`，用于结论分支与置信度计算。

## 关键输出字段

### `events.jsonl`（每行一个事件 JSON）

包含字段：

- `service`, `pid`
- `ts_us`, `ts_epoch`
- `message`
- `peer`, `peer_ip`, `peer_port`
- `event_id`
- `close_wait_count`
- `pcap_analysis`（内嵌 JSON）
- `strace_analysis`（内嵌 JSON）

### `summary.json`

包含：

- 基础运行信息（service/pid/outdir）
- 开关状态（tcpdump/strace）
- 总事件数、窗口统计、CLOSE-WAIT 统计
- `accountability` 计数（A/B/C/proper）

### `accountability.txt`

最终人类可读定责报告，含：

- `CONCLUSION`
- `CONFIDENCE`
- `EVIDENCE BREAKDOWN`
- `RECOMMENDATION`
- 数据源路径

## 依赖与权限

必需命令：

- `journalctl`
- `ss`
- `awk` `sed` `grep`
- `jq`

可选命令：

- `tcpdump`（启用 `--enable-tcpdump` 时）
- `strace`（启用 `--enable-strace` 时）

建议使用 root/sudo 运行，否则可能无法读取 socket/进程信息或抓包。

## 性能与开销建议

- 常驻低开销：`journalctl` + `ss/fdmap`
- 中等开销：`tcpdump`（主要是磁盘写入）
- 中高开销：`strace`（线程多、syscall 频繁时更明显）
- 线上建议：先短时开启完整模式定位根因，再按需降级到基础模式

## 常见问题

### 看不到事件

```bash
journalctl -u dae -f | grep -F 'broken pipe'
systemctl show -p MainPID dae
```

### tcpdump 启动失败

```bash
sudo tcpdump -D
ip link show
```

### strace 附加失败

```bash
cat /proc/sys/kernel/yama/ptrace_scope
# 如有需要：
# sudo sysctl kernel.yama.ptrace_scope=0
```

## 备注

- 脚本内部帮助与启动横幅仍显示 `v3` 文案，这是历史命名遗留，不影响 `dae_triage_unified_v5.sh` 的实际功能。
