# DNS Trace-Back 2nd 修复开发任务书（执行版）

> 来源审计: `/Users/ouzy/Documents/DevProjects/dae/.plan/code_audit_trace-back-2nd.md`
> 分支: `dns_fix`
> 目标: 按 High -> Medium 顺序关闭 F1/F3/F4/F2，并补齐任务级验证与测试记录

## 0. 串行执行策略（落实）

1. High 任务先行，且按依赖顺序执行：`T1(F1+F4 ingress)` -> `T2(F3 shutdown)` -> `M1(High 里程碑回归)`。
2. Medium 任务只在 High 代码与本地可执行验证完成后进入：`T3(F2)` -> `M2(总里程碑回归)`。
3. 本地环境限制（非 Linux + 无 eBPF 生成链路）下，回归分为两层：
   - 本地：代码级静态/结构验证（gofmt + 路径断言）。
   - CI：Linux + eBPF 构建与编译测试闭环。

## 1. High 实施关系设计

### T1（HIGH，覆盖 F1+F4 主因）

**目标**:
- 消除 DNS lane 满时阻塞 UDP 读循环。
- 增加可观测性计数（queue full / drop）用于长跑退化归因。

**代码实现**:
- 文件: `/Users/ouzy/Documents/DevProjects/dae/control/control_plane.go`
- 改动:
  1. `enqueueDnsIngressTask` 增加 `default` 分支，队列满时不阻塞。
  2. 新增 `dnsIngressQueueFullTotal`、`dnsIngressDropTotal` 两个计数器。
  3. 新增 `onDnsIngressQueueFull`（计数 + 节流日志），日志字段名与审计要求一致：
     - `dns_ingress_queue_full_total`
     - `dns_ingress_drop_total`
  4. `dispatchDnsOrQueue` 显式检查入队返回值。

**任务级测试（本地可执行）**:
- `gofmt -w control/control_plane.go control/dns_improvement_test.go`
- `rg -n "dnsIngressQueueLogEvery|onDnsIngressQueueFull|dns_ingress_queue_full_total|dns_ingress_drop_total" control/control_plane.go`
- `rg -n "TestUdpIngressDispatch_NoSyncFallbackWhenDnsLaneBusy|dnsIngressQueueFullTotal|dnsIngressDropTotal" control/dns_improvement_test.go`

**结果**: 通过（结构与路径验证通过）。

---

### T2（HIGH，覆盖 F3）

**目标**:
- reload/close 时不遗留 `dnsIngressQueue` 中的 buffer。

**代码实现**:
- 文件: `/Users/ouzy/Documents/DevProjects/dae/control/control_plane.go`
- 改动:
  1. 新增 `drainDnsIngressQueue`，在退出路径排空队列并回收 buffer。
  2. worker 收到 `ctx.Done()` 后执行 drain 再退出。
  3. worker 取到 task 后增加 `ctx.Err()` 检查，关闭期间不再进入 `handlePkt`，直接回收。

**任务级测试（本地可执行）**:
- `rg -n "drainDnsIngressQueue|ctx\.Err\(\)" control/control_plane.go`
- `rg -n "TestDrainDnsIngressQueue_DrainsWithoutCountingDrop" control/dns_improvement_test.go`

**结果**: 通过（结构与路径验证通过）。

---

### M1（High 里程碑回归）

**目标**: 对 High 变更执行本地编译级回归尝试并记录环境阻塞。

**执行命令**:
1. `GOWORK=off go test ./control -run 'Test(UdpIngressDispatch|DrainDnsIngressQueue|AnyfromPoolGetOrCreate_(ZeroTTLStillPooled|NegativeTTLStillPooled))' -count=1`
2. `GOWORK=off GOOS=linux GOARCH=amd64 go test ./control -run 'Test(UdpIngressDispatch|DrainDnsIngressQueue|AnyfromPoolGetOrCreate_(ZeroTTLStillPooled|NegativeTTLStillPooled))' -count=1`

**结果**:
- 命令 1 失败：macOS 缺失 Linux netlink/IP_TRANSPARENT 常量（平台限制）。
- 命令 2 失败：缺少 eBPF 生成类型（`bpfObjects/bpfRoutingResult`），需 CI 生成链路。

**结论**:
- High 改动已完成本地代码级验证。
- Linux + eBPF 编译测试需由 CI 接管。

## 2. Medium 实施

### T3（MEDIUM，覆盖 F2）

**目标**:
- 修复 `AnyfromPool.GetOrCreate` 在 `ttl<=0` 时不入池问题。

**代码实现**:
- 文件: `/Users/ouzy/Documents/DevProjects/dae/control/anyfrom_pool.go`
- 改动:
  1. `p.pool[lAddr] = newAf` 移到 `if ttl > 0` 外，保证 `ttl<=0` 仍入池。
  2. 新增 `createAnyfromFn` 测试 seam（默认指向 `createAnyfrom`），支撑无 socket 单元语义测试。
  3. 竞争失败关闭连接处增加 nil 防护（测试 seam 下更稳健）。
- 文件: `/Users/ouzy/Documents/DevProjects/dae/control/dns_improvement_test.go`
- 新增测试:
  1. `TestAnyfromPoolGetOrCreate_ZeroTTLStillPooled`
  2. `TestAnyfromPoolGetOrCreate_NegativeTTLStillPooled`

**任务级测试（本地可执行）**:
- `gofmt -w control/anyfrom_pool.go control/dns_improvement_test.go`
- `rg -n "createAnyfromFn|p\.pool\[lAddr\] = newAf" control/anyfrom_pool.go`
- `rg -n "TestAnyfromPoolGetOrCreate_ZeroTTLStillPooled|TestAnyfromPoolGetOrCreate_NegativeTTLStillPooled" control/dns_improvement_test.go`

**结果**: 通过（结构与路径验证通过）。

## 3. M2（总里程碑回归）

**目标**: 对 High+Medium 的变更做统一本地回归尝试并确认 CI 接管项。

**本地结论**:
1. 代码级修复路径完整落地（F1/F3/F4/F2）。
2. 本地无法完成 `control` 包 Linux/eBPF 编译测试（环境限制已复现）。
3. 下一步必须提交 PR 触发 CI 完成最终编译与测试闭环。

## 4. 交付清单

1. `/Users/ouzy/Documents/DevProjects/dae/control/control_plane.go`
   - 非阻塞 DNS 入队、queue/drop 计数器、关闭排空逻辑。
2. `/Users/ouzy/Documents/DevProjects/dae/control/anyfrom_pool.go`
   - `ttl<=0` 入池修复 + create seam。
3. `/Users/ouzy/Documents/DevProjects/dae/control/dns_improvement_test.go`
   - 队列满语义测试更新、drain 测试、`ttl<=0` 语义测试。
4. `/Users/ouzy/Documents/DevProjects/dae/.plan/code_audit_trace-back-2nd-dev.md`
   - 本执行文档。

## 5. CI 要求（必须）

1. 在 Linux runner 上完成 eBPF 代码生成后执行 `go test`。
2. 覆盖 DNS 分流、关闭排空、AnyfromPool 语义回归。
3. 结合 endurance/soak 数据确认 F4（长跑退化）是否收敛。
