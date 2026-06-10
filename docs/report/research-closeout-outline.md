# Doris BE 原生栈采集调研收尾大纲

Doris BE 需要一个 debug API，在运行中采集 native thread stack。
候选方案共享同一个 HTTP / coordinator 协议，差异集中在 signal handler 里的 capture hook。
当前收尾工作要补齐关键实验，再按统一标准进入方案取舍。

## 0. 当前判断

- 公共 API / coordinator 协议可以先收敛，capture hook 保持可替换。
- 方案分歧集中在 handler 内执行 libunwind、copy snapshot、还是读取 RBP 链。
- CK / OB 提供了 signal handler 内采集的生产参考，同时把 libunwind 风险带进 handler。
- Snapshot 把 unwind 移到 coordinator，但引入 copied stack 和 remote accessor 复杂度。
- Frame-pointer walking 的 handler 最小，取舍点是 tail call、prologue、缺少 frame pointer 的帧边界。

## 1. 候选方案对比

结论：四个方案的取舍集中在 handler safety、栈质量、loader 交互和验证成本。

| 方案 | Handler 内做什么 | 主要收益 | 主要风险 | 待补实验 |
|---|---|---|---|---|
| CK-style PHDR-cache unwind | 用 signal `ucontext_t` 跑 libunwind walk | 预期栈帧质量较好；有 CK 协议参考 | PHDR cache 与 `dlopen` / `dlclose` 生命周期；全局 `dl_iterate_phdr` override | PHDR 信息缺失 / stale PHDR 实验 |
| OB-style two-phase `kill -60` | 跑 nongnu libunwind，并参与 release 协作 | 有 OB 生产参考；输出适合离线解析 | handler 内 libunwind 可能进入 loader path；两阶段协议增加同步复杂度 | two-phase 作用实验 |
| Snapshot + remote unwind | copy registers 和 bounded stack bytes | libunwind 运行在 coordinator；loader 交互离开 handler | copied stack 截断；remote accessor 复杂；snapshot 一致性 | snapshot stack size / accessor / 截断实验 |
| Frame-pointer walking | 读 RIP/RBP，沿 RBP 链取 return address | handler 路径小；依赖 Doris Release frame pointer | tail call、prologue、缺少 frame pointer 的代码可能漏帧 | tail call / prologue 漏帧实验 |

证据：

- CK 和 OB 都证明了 signal 驱动的 live stack dump 形态可落地。
- Doris patch 已把公共 API、coordinator、handler 通知协议与 capture hook 解耦。
- jemalloc / glibc 实验证明 unwind、loader、allocator 之间存在真实历史风险。

## 2. 待补实验

结论：当前卡点是失败形态和边界条件，而不是 HTTP API 形状。

| 实验 | 影响的方案 | 要确认的取舍点 | 最小实验输出 |
|---|---|---|---|
| PHDR 信息缺失 / stale PHDR | CK-style PHDR-cache unwind | PHDR cache 不完整时是少帧、停止、错误 frame，还是崩溃 | 完整 PHDR / 缺失 PHDR / stale PHDR 三列结果表 |
| two-phase 作用 | OB-style two-phase `kill -60` | release 协作在 Doris slot + sequence 模型中提供的额外属性 | single-phase 与 two-phase 的 stale result / timeout recovery 行为表 |
| snapshot 截断 | Snapshot + remote unwind | copied stack 需要多大；截断后 libunwind 如何停止 | stack size sweep 表：size、frame count、stop reason |
| tail call / prologue 漏帧 | Frame-pointer walking | `-fno-omit-frame-pointer` 下 RBP 链具体漏哪些帧 | 普通调用、tail call、禁用 sibling-call 的栈对比表 |
| libunwind 截断行为 | libunwind 相关方案 | cursor API 停止条件和调用方 cap 的关系 | recursion depth、frame cap、stop reason 对比表 |

证据：

- PHDR cache 风险来自 CK-style `dl_iterate_phdr` override 与 Doris 启动后 `dlopen` 边界。
- tail call 风险来自 frame-pointer walking 对 RBP 链的依赖。
- snapshot 风险来自 copied stack 的固定窗口和 remote accessor 行为。
- libunwind 截断问题影响 CK / OB / snapshot 三类方案的栈质量解读。

## 3. 公共协议收敛点

结论：公共协议可以作为候选方案共享底座，方案比较只需要替换 capture hook。

| 协议点 | 当前收敛方向 | 取舍影响 |
|---|---|---|
| API route | `GET /api/print_stack` | 对所有候选方案一致 |
| Target selection | 默认所有线程；可选 `thread_id` | 方案差异不影响请求形态 |
| Thread enumeration | coordinator 读取 `/proc/self/task` | 复用 CK / OB 的线程枚举形态 |
| Signal delivery | coordinator 顺序 signal 每个 tid | 降低共享 slot 和 signal queue 复杂度 |
| Completion signal | pipe 只传 sequence notification | frames 留在 slot / snapshot 中 |
| Stale result guard | sequence 匹配 | timeout 和迟到 handler 的恢复基础 |
| Address output | coordinator 归一化为 `(dso, dso_offset)` | 符号化留给离线工具 |

证据：

- CK 使用 sequence + pipe notification 的单线程顺序采集协议。
- Doris common patch 已把 action、coordinator、handler 通知、PC 归一化做成共享层。
- 四个候选方案的差异都能落在 capture hook 或 variant-local coordinator extension 上。

## 4. 已有证据

结论：已有证据足以支撑候选方案边界划分，最终取舍还依赖剩余实验。

| 证据来源 | 已确认内容 | 支撑的比较维度 |
|---|---|---|
| CK 源码阅读 | `system.stack_trace` 使用 sequential signal、sequence、pipe notification、handler 内 libunwind、PHDR cache | 公共协议、PHDR cache 风险、handler 内 libunwind |
| OB 源码阅读 | `kill -60` 使用 signal worker、handler 内 `safe_backtrace()`、two-phase release、maps + raw address 输出 | two-phase 参考、handler 内 libunwind、离线解析 |
| Doris patch / tests | `/api/print_stack` contract、`thread_id` selector、best-effort frame observation、common coordinator 可复用 | 公共协议可收敛、capture hook 可替换 |
| jemalloc / glibc 实验 | Ubuntu 20.04 上 libgcc `_Unwind_Backtrace` + profiling 复现 allocator / loader recursion；libunwind backtracer 和 Ubuntu 24.04 case 完成 | unwind / loader / allocator 交互风险 |
| Doris build flags | Release 保留 frame pointer | frame-pointer walking 的前置条件 |

## 5. 会议需要决策的问题

结论：会议应先锁定评估标准和补实验优先级，再进入实现取舍。

| 决策问题 | 建议会议产出 |
|---|---|
| 统一评估标准是否完整 | handler safety、stack quality、runtime compatibility、failure containment、engineering cost 五项是否足够 |
| 公共协议是否先收敛 | `/api/print_stack`、thread selection、sequence、pipe、`(dso, dso_offset)` 是否作为共享底座 |
| 补实验优先级 | PHDR 缺失、tail call、snapshot 截断、two-phase 作用、libunwind 截断的排序 |
| 方案取舍门槛 | 每个候选方案进入下一步所需的最低证据 |
| 汇报结论形态 | 用统一表格记录候选方案收益、风险、实验结果和后续动作 |

证据：

- 四类方案已经映射到同一组评估维度。
- 待补实验直接对应未收敛的失败形态和边界条件。
- 公共协议与 capture hook 的分层能减少方案比较时的重复实现讨论。
