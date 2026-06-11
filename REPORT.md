# Doris BE Print Stack API 调研报告

背景：[Doris#62497](https://github.com/apache/doris/issues/62497)。

仓库：[Doris-BE-Print-Stack-API-Research](https://github.com/JoverZhang/Doris-BE-Print-Stack-API-Research)。

目前 API 中尚未包含符号化逻辑，仅返回 `(dso, dso_offset)`。符号化方式较为固定，本文主要关注采集阶段的设计与权衡。

> 测试时，可使用 llvm-symbolizer 等工具对 (dso, dso_offset) 进行离线符号化

## 阅读前置术语

> 只解释本文中的使用方式，不展开通用背景。

| 术语 | 本文含义 |
|---|---|
| coordinator | 接收 HTTP 请求的普通线程，负责枚举目标线程、发送 signal、等待结果、汇总与符号解析。 |
| handler | 目标线程收到 rt signal 后进入的 signal handler，负责在目标线程上下文中采集栈。 |
| capture stack | 采集 PC / RIP 地址序列。 |
| symbolization | 符号化，把 `(dso, dso_offset)` 转成人类可读的函数名、文件名、行号；本文不重点讨论。 |
| dso / dso_offset | DSO 是动态库或可执行文件；offset 是扣除 ASLR 后的相对偏移，可用于离线符号化。 |
| rt signal | Linux realtime signal；本文用于让 coordinator 请求某个目标线程进入 handler。 |
| frame-pointer walk | 沿 RBP 链采集 return address，handler 逻辑简单，但可能缺帧。 |
| libunwind | 基于 unwind 信息恢复调用栈，栈质量更好，但在 signal handler 内有 async-signal-safety 风险。 |
| async-signal-safe | 表示函数可安全地在 signal handler 内调用；本文的核心风险判断之一。 |
| PHDR cache | 缓存动态库加载信息，避免 handler 内触碰 loader，但有生命周期与一致性风险。 |

## 结论：

1. 公共 API / coordinator 逻辑可以先收敛，方案差异收敛为 handler 内如何 capture stack，最终取舍取决于接受哪一级一致性（见 [5. 回归需求与下一步](#5-回归需求与下一步)）
2. 已复现部分 signal handler 内 libunwind 的风险路径（见 [4. 证据链](#4-证据链)）

## 1. 目标

为 `doris_be` 提供一个运行时 debug API，在不重启、不挂起进程的前提下采集线程的
native stack：

```text
GET /api/print_stack                  # 默认全部线程
GET /api/print_stack?thread_id=12345  # 指定线程（后续可支持多个）
```

- 每帧返回 `(dso, dso_offset)`，offset 已扣除 ASLR。（可直接符号化）
- 面向 Linux x86_64 Release 构建；同一时刻只允许一个 print_stack（需要阻塞后续请求）。
- 单个线程不响应时记空栈，不拖垮整个请求。

调研主要目标：评估不同设计方案在 signal 安全与栈质量上的权衡，锁定可接受的一致性等级。

## 2. 实现原理

API 层面设计参考了 CK 和 OB 的实现方式，目前主要差异在于 handler 内的 capture stack 方案。

### 2.1 API 层面

本仓库实现的 patch: [common](patches/common/0001-phase2-common-add-print_stack-types-coordinator-acti.patch)

```text
HTTP action
 └─ coordinator（普通线程）
     ├─ 读 /proc/self/task，得到所有目标 tid 列表
     ├─ 逐个 tid：发送 rt signal（携带 sequence）──► 目标线程进入 signal handler
     │    handler：capture stack 函数把 PC 数组写入共享 slot，向 pipe 写回 sequence
     ├─ 有界等待 pipe；超时则该线程记空栈，继续下一个
     └─ 把 slot 里的 PC 解析为 (dso, dso_offset)
```

核心要点：

- rt signal 会排队、不会合并；sequence 不匹配的迟到结果被丢弃。
- 采集顺序进行，所以一个共享 slot、单写 latch 就够了。
- handler 内只做 signal-safe 的事；DSO 解析、`/proc` 读取都留在 coordinator。

### 2.2 capture stack 层面（两种栈采集方式）

1. **frame-pointer walk**：从 ucontext 取 RIP/RBP，沿 RBP 链逐帧收集 return
   address。
    - 依赖 `-fno-omit-frame-pointer`（Doris Release 已开启）。
    - 有 `-mno-omit-leaf-frame-pointer` 效果更好（Doris 没开，leaf 函数可能缺帧）。
    - 本仓库实现的 patch: [frame-pointer walk](patches/fp-walk/0001-phase2-fp-walk-add-capture_into_slot-RBP-chain-walke.patch)

2. **libunwind**：通常按 `.eh_frame` 计算 caller 的 RIP（CK 和 OB 的生产方式）。
    - 本仓库实现的 patch（参考 CK）: [libunwind](patches/ck-phdr-unwind/0003-be-ck-phdr-unwind-libunwind-capture_into_slot.patch)
    - Doris 中原有的 [backtrace](https://github.com/apache/doris/blob/0cf0be2997708a18600b9bdfd9c12249cc02b3a8/be/src/common/stack_trace.cpp#L299-L308) （参考 CK）

## 3. 权衡点

### 3.1 协调层 — signal 怎么发：

| 方式 | 状态 |
|---|---|
| 逐线程发送、逐线程等待（CK / OB 方式） | 生产已验证；协议最简 |
| 预分配每线程 slot，并发发送 rt signal | 未验证；并发可能触碰 signal 队列上限导致丢失（待证明） |

### 3.2 采集层 — handler 内执行什么：

| 方案 | 关键收益 | 关键风险 |
|---|---|---|
| frame-pointer walk | handler 最小，天然接近 signal-safe | 依赖栈内保留的链信息：tail call 缺帧；signal 落在 prologue 时截断；leaf 帧可能省略 RBP（Doris 没开 `-mno-omit-leaf-frame-pointer`） |
| handler 内 libunwind（CK / OB） | 栈质量最好；两家生产已验证 | libunwind 不是 async-signal-safe；CK 用 PHDR cache 规避 `dl_iterate_phdr`，又引入 cache 生命周期风险（证据链 2、6） |

### 3.3 一种未验证的扩展方案

所有线程在 handler 内快照一段 stack 与寄存器，coordinator 线程通过 libunwind 爬栈。

- 优点：signal handler 内操作是 signal-safe 的；理论上能比 frame-pointer walk 捕获更多帧（取决于快照长度）
- 缺点：快照窗口固定，外层帧会截断

## 4. 证据链

| # | 证据 | 证明什么 |
|---|---|---|
| 1 | [CK 协调逻辑源码](https://github.com/ClickHouse/ClickHouse/blob/f74c9de34f7b0a956d18330b00544a977ceb0347/src/Storages/System/StorageSystemStackTrace.cpp#L376-L380) | CK 的全线程栈不是同一时刻的快照，而是逐线程顺序采集 |
| 2 | [CK jemalloc 构建配置](https://github.com/ClickHouse/ClickHouse/blob/f74c9de34f7b0a956d18330b00544a977ceb0347/contrib/jemalloc-cmake/CMakeLists.txt#L201-L214) | CK 把 jemalloc prof 的 unwinder 从默认 glibc 换成 libunwind，避免 Doris PR#22549 的问题 |
| 3 | [Doris PR#22549](https://github.com/apache/doris/pull/22549) | Doris 曾带着 `updatePHDRCache()` 的 override 正常工作；开启 jemalloc prof 后无法启动，PR 因此整体移除该路径 — `updatePHDRCache()` 本身不是即刻致命的 |
| 4 | [本仓库复现 Doris PR#22549](https://github.com/JoverZhang/Doris-BE-Print-Stack-API-Research/blob/master/reproduce/pr22549-jemalloc-dl-iterate-phdr/README.md) | 复现该启动死锁（`getOriginalDLIteratePHDR` → `_Unwind_Backtrace` → 嵌套 `malloc_init_hard`）；以及 jemalloc prof 换 libunwind backend 后正常启动 |
| 5 | [Doris PR#22549 的另一种修复尝试](https://github.com/JoverZhang/Doris-BE-Print-Stack-API-Research/blob/master/experiments/jemalloc-glibc-dlerror/README.md#matrix) | 根因隔离到 glibc < 2.34 的 `dlerror` 分配路径；四行矩阵证明 prof 是触发器，libunwind backend 与 glibc ≥ 2.34（[fada9018](https://github.com/bminor/glibc/commit/fada9018199c21c469ff0e731ef75c6020074ac9)）各自都能避免 |
| 6 | [PHDR cache 实验](https://github.com/JoverZhang/Doris-BE-Print-Stack-API-Research/blob/master/experiments/phdr-cache-incomplete/README.md) | cache 不完整 → 栈截断、正常退出；PHDR 条目损坏 → SIGSEGV — 给 CK-style cache 的生命周期风险定界 （待仔细检查）|

链条结论：unwind、loader、allocator 三者的交互风险真实且可复现；目前已发现的每条风险都有
已验证的缓解路径（libunwind backend、glibc ≥ 2.34、或不在 handler 内 unwind）。

## 5. 回归需求与下一步

对一致性的要求从严到宽分五级，每级对应不同的设计空间：

| 级 | 要求（逐级放宽） | 对应设计 |
|---|---|---|
| 1 | 严格全线程同一时刻快照 | 需并发 signal + handler 集体驻留等待放行（未验证并发 rt signal 风险） |
| 2 | 严格几个指定线程的同时快照 | 同上，范围更小 |
| 3 | 容忍各线程采集时刻不同 | CK / OB 生产形态：顺序采集 + handler 内 libunwind |
| 4 | 再容忍栈外层帧被截断 | snapshot + remote unwind（见 3.3） |
| 5 | 再容忍缺帧（tail call）与偶发截断（prologue） | frame-pointer walk |

下一步：

1. 锁定可接受的一致性等级 — 它直接决定候选集合与协调层形态。
2. 补实验闭环：并发 rt signal 丢失证明、snapshot 截断扫描、tail call /
   prologue 缺帧定量、libunwind 截断行为。
3. 公共协议先收敛落地（API、coordinator、sequence / pipe、`(dso, dso_offset)`），
   capture stack 保持可替换 — 方案比较只需要换一个函数。
4. 若走 libunwind 类方案，进入实现前补 async-signal-safety 审查（本阶段范围外）。
