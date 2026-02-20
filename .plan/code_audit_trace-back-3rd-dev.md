# DNS Ingress 分级可配置化开发任务书（执行版）

> 来源审计: `/Users/ouzy/Documents/DevProjects/dae/.plan/code_audit_trace-back-3rd.md` §5（修订版）
> 分支: `dns_fix`
> 目标: 将 DNS ingress 硬编码常量升级为分级性能等级配置，默认行为不变

## 0. 执行总则（强制）

1. **严格串行**: 所有任务严格串行执行：`Tn` 未测试通过，不允许开始 `Tn+1`。
2. **三件套**: 每个任务必须包含并记录在 `.plan/test-log.md`：
   - 代码实现（对应文件变更）
   - 任务级测试（单元/集成/验证）
   - 测试记录（命令、结果、结论）
3. **里程碑回归**: 每个里程碑必须在全部任务通过后，执行一次里程碑回归测试。
4. **失败即停**: 任一测试失败，立即停止后续任务，先修复并重测，直至通过。

## 0.1 执行策略

1. config 层改动先行（T1→T2→T3），确保配置解析与校验完备。
2. control 层消费 config（T4），替换硬编码常量。
3. example.dae 更新（T5），对齐用户文档。
4. 新增测试（T6），覆盖 profile 解析逻辑。
5. 本地里程碑验证（M1）。
6. 本地环境限制（macOS + 无 eBPF 生成链路），编译/运行级回归需 CI 接管。

---

## T1: `config/config.go` — 新增类型和字段

**目标**: 定义 `DnsIngressManual` struct，在 `Global` 中新增 `DnsPerformanceLevel` 和 `DnsIngressManual`。

**代码实现**:
- 文件: `/Users/ouzy/Documents/DevProjects/dae/config/config.go`
- 改动:
  1. 在 `Global` struct 定义之前（约 L20）新增：
     ```go
     type DnsIngressManual struct {
         Workers uint16 `mapstructure:"workers" default:"0"`
         Queue   uint16 `mapstructure:"queue" default:"0"`
     }
     ```
  2. 在 `Global` struct 的 `BandwidthMaxRx` 之后（L48-49 间）新增：
     ```go
     DnsPerformanceLevel string           `mapstructure:"dns_performance_level" default:"balanced"`
     DnsIngressManual    DnsIngressManual `mapstructure:"dns_ingress_manual"`
     ```

**任务级验证**:
```bash
rg -n "DnsIngressManual|DnsPerformanceLevel|dns_performance_level|dns_ingress_manual" config/config.go
```

---

## T2: `config/patch.go` — 新增校验 patch

**目标**: 校验 `dns_performance_level` 合法性；`manual` 模式下 clamp workers/queue。

**代码实现**:
- 文件: `/Users/ouzy/Documents/DevProjects/dae/config/patch.go`
- 改动:
  1. 在 `patches` 切片（L19-23）中追加 `patchDnsPerformanceLevel`。
  2. 新增函数：
     ```go
     func patchDnsPerformanceLevel(params *Config) error {
         level := strings.ToLower(strings.TrimSpace(params.Global.DnsPerformanceLevel))
         switch level {
         case "lean", "balanced", "aggressive", "manual":
             params.Global.DnsPerformanceLevel = level
         case "":
             params.Global.DnsPerformanceLevel = "balanced"
         default:
             logrus.Warnf("Unknown dns_performance_level '%s', falling back to 'balanced'",
                 params.Global.DnsPerformanceLevel)
             params.Global.DnsPerformanceLevel = "balanced"
         }
         if level == "manual" {
             m := &params.Global.DnsIngressManual
             const minW, maxW uint16 = 32, 1024
             const minQ, maxQ uint16 = 128, 16384
             if m.Workers == 0 {
                 m.Workers = 256
             }
             if m.Queue == 0 {
                 m.Queue = 2048
             }
             if m.Workers < minW {
                 logrus.Warnf("dns_ingress_manual.workers %d below min %d, clamping", m.Workers, minW)
                 m.Workers = minW
             } else if m.Workers > maxW {
                 logrus.Warnf("dns_ingress_manual.workers %d above max %d, clamping", m.Workers, maxW)
                 m.Workers = maxW
             }
             if m.Queue < minQ {
                 logrus.Warnf("dns_ingress_manual.queue %d below min %d, clamping", m.Queue, minQ)
                 m.Queue = minQ
             } else if m.Queue > maxQ {
                 logrus.Warnf("dns_ingress_manual.queue %d above max %d, clamping", m.Queue, maxQ)
                 m.Queue = maxQ
             }
         }
         return nil
     }
     ```

**任务级验证**:
```bash
rg -n "patchDnsPerformanceLevel|dns_performance_level" config/patch.go
```

---

## T3: `config/desc.go` — GlobalDesc 新增描述

**目标**: 为新增 config 项提供描述文本。

**代码实现**:
- 文件: `/Users/ouzy/Documents/DevProjects/dae/config/desc.go`
- 改动: 在 `GlobalDesc`（约 L61 `}` 之前）追加：
  ```go
  "dns_performance_level": "DNS ingress performance level. Options: lean, balanced (default), aggressive, manual. " +
      "Use 'lean' for low-power devices, 'aggressive' for high-load environments. " +
      "Only set 'manual' if you need fine-grained control over worker and queue sizes.",
  ```

**任务级验证**:
```bash
rg -n "dns_performance_level" config/desc.go
```

---

## T4: `control/control_plane.go` — profile 查找表 + 初始化改造

**目标**: 用 profile 查找表替换硬编码常量，从 config 读取 level 决定 workers/queue。

**代码实现**:
- 文件: `/Users/ouzy/Documents/DevProjects/dae/control/control_plane.go`
- 改动:

  1. **替换常量块**（L49-54）：
     ```go
     const (
         dnsIngressQueueLogEvery = 100
     )

     type dnsIngressProfile struct {
         workers  int
         queueLen int
     }

     var dnsIngressProfiles = map[string]dnsIngressProfile{
         "lean":       {workers: 32, queueLen: 128},
         "balanced":   {workers: 256, queueLen: 2048},
         "aggressive": {workers: 1024, queueLen: 4096},
     }

     func resolveDnsIngressProfile(level string, manual config.DnsIngressManual) dnsIngressProfile {
         if level == "manual" {
             return dnsIngressProfile{
                 workers:  int(manual.Workers),
                 queueLen: int(manual.Queue),
             }
         }
         if p, ok := dnsIngressProfiles[level]; ok {
             return p
         }
         return dnsIngressProfiles["balanced"]
     }
     ```

  2. **ControlPlane struct** 新增字段（L77 附近）：
     ```go
     dnsIngressWorkerCount int
     ```

  3. **NewControlPlane 初始化**（L405-415 区域）：
     ```go
     profile := resolveDnsIngressProfile(global.DnsPerformanceLevel, global.DnsIngressManual)
     ```
     - `dnsIngressQueue: make(chan dnsIngressTask, profile.queueLen)` 替换原 `dnsIngressQueueLength`
     - 新增赋值 `dnsIngressWorkerCount: profile.workers`
     - 初始化后打印：
       ```go
       log.Infof("DNS ingress: level=%s, workers=%d, queue_len=%d",
           global.DnsPerformanceLevel, profile.workers, profile.queueLen)
       ```

  4. **startDnsIngressWorkers**（L818-819）：
     `for i := 0; i < dnsIngressWorkerCount; i++` → `for i := 0; i < c.dnsIngressWorkerCount; i++`

**任务级验证**:
```bash
rg -n "dnsIngressProfile|resolveDnsIngressProfile|dnsIngressWorkerCount|DnsPerformanceLevel" control/control_plane.go
```

---

## T5: `example.dae` — 注释掉的配置示例

**目标**: 在 example config 中展示新参数的用法。

**代码实现**:
- 文件: `/Users/ouzy/Documents/DevProjects/dae/example.dae`
- 改动: 在 `pprof_port: 0`（L13）之后插入：
  ```
    # DNS ingress performance level.
    # Options: lean, balanced (default), aggressive, manual.
    # - lean: for low-power/embedded devices (32 workers)
    # - balanced: for typical home/small office (256 workers)
    # - aggressive: for high-load environments (1024 workers)
    # - manual: expert tuning, requires dns_ingress_manual section below
    # dns_performance_level: balanced

    # Only effective when dns_performance_level is "manual".
    # Workers: 32-1024, Queue: 128-16384.
    # dns_ingress_manual {
    #     workers: 512
    #     queue: 2048
    # }
  ```

**任务级验证**:
```bash
rg -n "dns_performance_level|dns_ingress_manual" example.dae
```

---

## T6: `control/dns_improvement_test.go` — 新增 profile 解析测试

**目标**: 覆盖 `resolveDnsIngressProfile` 的各分支。

**代码实现**:
- 文件: `/Users/ouzy/Documents/DevProjects/dae/control/dns_improvement_test.go`
- 新增测试函数 `TestResolveDnsIngressProfile`，测试用例：
  1. `level="lean"` → workers=32, queueLen=128
  2. `level="balanced"` → workers=256, queueLen=2048
  3. `level="aggressive"` → workers=1024, queueLen=4096
  4. `level="manual"` + manual{Workers:512, Queue:4096} → workers=512, queueLen=4096
  5. `level="unknown"` → 回落 balanced (workers=256, queueLen=2048)
  6. `level=""` → 回落 balanced

**任务级验证**:
```bash
rg -n "TestResolveDnsIngressProfile" control/dns_improvement_test.go
```

现有 dispatch/drain/anyfrom_pool 测试无需修改——它们直接构造 ControlPlane struct，不走 config 层。

---

## M1: 本地里程碑验证

**目标**: 对所有改动执行本地可执行验证。

**执行命令**:
```bash
# 1) 格式化
gofmt -w config/config.go config/patch.go config/desc.go control/control_plane.go control/dns_improvement_test.go

# 2) 关键路径检查
rg -n "DnsIngressManual|DnsPerformanceLevel|dns_performance_level" config/config.go
rg -n "patchDnsPerformanceLevel" config/patch.go
rg -n "dnsIngressProfile|resolveDnsIngressProfile|dnsIngressWorkerCount" control/control_plane.go
rg -n "TestResolveDnsIngressProfile" control/dns_improvement_test.go
rg -n "dns_performance_level|dns_ingress_manual" example.dae

# 3) 交叉编译 vet（本地可执行的最大检查范围）
GOWORK=off GOOS=linux GOARCH=amd64 go vet ./config/
```

**预期阻塞点**: `go vet ./control/` 在 macOS 上可能失败（缺 Linux netlink/eBPF 常量），需 CI 接管。

---

## 交付清单

| 文件 | 改动 |
|---|---|
| `config/config.go` | `DnsIngressManual` struct + `Global` 两个字段 |
| `config/patch.go` | `patchDnsPerformanceLevel` + patches 切片追加 |
| `config/desc.go` | `GlobalDesc` 新增 `dns_performance_level` 描述 |
| `control/control_plane.go` | profile 查找表 + `resolveDnsIngressProfile` + 初始化改造 + worker 循环使用 struct 字段 |
| `example.dae` | 注释掉的 level + manual 示例 |
| `control/dns_improvement_test.go` | `TestResolveDnsIngressProfile` |

---

## CI 要求

1. 在 Linux runner 上完成 eBPF 代码生成后执行 `go vet ./control/`。
2. `go test -race ./control/` 覆盖 profile 解析 + 现有 dispatch/drain/anyfrom_pool 测试。
3. 确认 `config/` 包编译与 vet 通过。
