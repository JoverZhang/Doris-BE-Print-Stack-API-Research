# 抓栈参考矩阵

## 矩阵 1：CK / OB 每个环节实现

| 环节               | ClickHouse `system.stack_trace`                                               | OceanBase `kill -60`                                                                     |
|--------------------|-------------------------------------------------------------------------------|------------------------------------------------------------------------------------------|
| 触发入口           | SQL 读 `system.stack_trace`                                                   | 外部 `kill -60 <pid>`                                                                    |
| thread 枚举        | 读 `/proc/self/task`                                                          | 读 `/proc/self/task`                                                                     |
| 唤起目标线程       | `rt_tgsigqueueinfo` 发送 `SIGRTMIN` 到目标 tid                                | signal 60 触发 worker；worker 再发送 `SIGURG` 到目标 tid                                  |
| 遍历方式           | 顺序，一次一个 thread                                                          | 顺序，一次一个 thread                                                                     |
| handler 入口校验   | 校验 sender pid 和 sequence                                                   | 校验 request id                                                                          |
| 抓栈位置           | 目标线程 signal handler                                                       | 目标线程 signal handler                                                                  |
| 抓栈实现           | CK 定制 LLVM/libunwind `unw_backtrace()`                                      | OB `safe_backtrace()` 包装 nongnu libunwind 1.6.2                                        |
| `updatePHDRCache`  | `main()` 预先填充 PHDR cache；这是 signal handler 内 unwind 的前置条件          | 无 CK PHDR cache；走 nongnu libunwind 路径                                               |
| 协同方式           | 单阶段：handler 抓栈、通知、返回                                                 | 两阶段：handler `prepare()` 后等待 collector `process()` 和 release                       |
| 输出形态           | system table：`thread_name`、`thread_id`、`query_id`、`trace`、`untracked_memory`  | `stack.<pid>.<time>` 文本文件；文件头写 `/proc/maps`，每个 thread 行带 `tid`、`tname`、`lbt` |
| 地址语义           | `trace` 是 file/object offset 数组，语义接近 DSO offset                        | `lbt` 是运行时虚拟地址列表；普通 frame 会做 `ip - 1`，不是 DSO offset                      |
| 解析方式           | 抓栈时不符号化；SQL 中用 `addressToLine` / `addressToSymbol` / `demangle` 解析 | 抓栈时不符号化；后续依赖 maps + raw address 解析                                          |
| frame pointer      | 非核心依赖                                                                    | `oblib` 带 `-fno-omit-frame-pointer`，但抓栈仍以 libunwind 为主                           |
| jemalloc profiling | 有，且和 libunwind / `trace_log` 相关                                          | `kill -60` 路径无明显关联                                                                |

## 矩阵 2：Doris 各实验方案

| 序号 | Doris 设计点         |   fp-walk   | ck-phdr-unwind |  ob-kill60  | 说明                                                                                               |
|------|----------------------|:-----------:|:--------------:|:-----------:|----------------------------------------------------------------------------------------------------|
| 0    | libunwind 依赖形态   |      -      |     nongnu     |   nongnu    | Doris thirdparty / OB 同为 nongnu libunwind 1.6.2                                                   |
| 1    | `updatePHDRCache`    |      -      |       ck       |      -      | 仅 ck-phdr 继承 CK 的 PHDR cache 预热；fp-walk / ob-kill60 不引入                                  |
| 2    | 触发入口             | doris local |  doris local   | doris local | HTTP API                                                                                           |
| 3    | thread 枚举          |   ck, ob    |     ck, ob     |   ck, ob    | 全一致，直接采用 `/proc/self/task` 枚举线程                                                         |
| 4    | 顺序唤起 thread      |   ck, ob    |     ck, ob     |   ck, ob    | 全一致，避免 signal queue 和共享状态复杂度                                                          |
| 5    | 协同方式             |     ck      |       ck       |     ob      | CK 单阶段；OB 两阶段                                                                                |
| 6    | 抓栈实现             | doris local |  CK + nongnu   | OB + nongnu | 见下方                                                                                             |
| 7    | 可见栈完整度         | 受限        |      更好      |    更好     | 见下方                                                                                             |
| 8    | handler 外解析地址   |     ck      |       ck       |     ck      | CK 用 SQL introspection 函数；Doris 输出 `(dso, dso_offset)`                                        |
| 9    | public API 输出 JSON | doris local |  doris local   | doris local | { "thread_id": ..., "thread_name": ..., "trace": [{"dso": ..., "dso_offset": ...}] }               |
| 10   | jemalloc profiling   |      -      |       ck       |     ck      | 附带依赖风险，不一定进入 `print_stack` 主流程                                                       |

抓栈实现：
- fp-walk：Doris 本地 RBP 链 walk，不依赖 libunwind。
- ck-phdr-unwind：CK 单阶段 handler 协议 + CK PHDR cache；unwinder 依赖 Doris thirdparty nongnu libunwind。
- ob-kill60：OB `safe_backtrace()` 形状 + nongnu libunwind 1.6.2；不加 CK PHDR cache。

可见栈完整度：
- fp-walk：只靠 `-fno-omit-frame-pointer` + RBP 链；tail call / tail return、断在 prologue、手写汇编会少帧。
- libunwind：使用 unwind info + fallback；通常比 fp-walk 覆盖更多帧。

## 矩阵 3：LLVM/libunwind 与 nongnu libunwind

| 环节               | LLVM/libunwind（CK）                                                                  | nongnu libunwind 1.6.2（OB / Doris）                                                      |
|--------------------|-------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------|
| Doris 是否直接使用 | 否。Doris 没有 CK vendored LLVM/libunwind fork。                                      | 是。Doris Linux thirdparty 使用 nongnu libunwind 1.6.2。                                  |
| CK / OB 使用方式   | CK fork 增加 `unw_backtrace()`。                                                     | OB 自己写 `safe_backtrace()` 包装 cursor API。                                           |
| 主要 unwind 元数据 | `.eh_frame_hdr` / `.eh_frame`；LLVM CFI parser；Linux x86_64 主要走 DWARF。            | `.eh_frame_hdr` / `.eh_frame`；缺 header 时可合成 `.eh_frame_hdr`；可选 `.debug_frame`。   |
| fallback 形态      | 找不到 unwind info 时倾向结束；CK 版本还关闭了慢速 full scan。                        | DWARF 失败后还有 signal frame、PLT、RSP fixup、guessed RBP frame 等 x86_64 fallback。       |
| signal frame       | CK 在 `StackTrace(signal_context)` 外层用 signal `ucontext` 对齐 interrupted frame。 | 提供 `unw_is_signal_frame()`；x86_64 fallback 可处理 signal frame。                       |
| 对 Doris 的含义    | 不能按“纯 CK unwinder”移植，只能借鉴 CK 单阶段协议。                                  | 依赖形态更接近 Doris；但 signal handler 内跑 libunwind 仍需处理 PHDR / loader-lock 风险。 |
