# Origin Research Summary

Source: the intern research that started this phase. Kept verbatim for
provenance. The durable findings are folded into
[../../docs/phase2-design.md](../../docs/phase2-design.md).

---

# 调研总结

## 可选方案 - ip 收集

1. ck 的实现方式（stacktrace）：
  - 流程：
    1. coordinator 通过 `rt_tgsigqueueinfo` 中断 workers
    2. workers 在 `signal handler` 里运行 `unw_backtrace()`
    3. 再由 coordinator 通过 `StackTrace::forEachFrame()` 解析符号

  - 前置条件：
    - ck 的 `jemalloc profiling` 编译参数使用 `libunwind`。不走 glibc 的 `_Unwind_Backtrace()` （避免死锁）
    - ck 增加 `updatePHDRCache()`，重写 `dl_iterate_phdr()`，支持 `dl_iterate_phdr()` 可重入（避免死锁）

    - PS：`jemalloc profiling` 和 `stacktrace`，二者都会走 `unw_backtrace()` 的 `unw_step()`，里面有路径会走 `dl_iterate_phdr()`

  - 风险：`updatePHDRCache()` 在 Doris 的边界问题尚未完全验证


2. ob 的实现方式（kill-60）：
  - PS：与 ck 大方向类似
  - 流程：
    1. coordinator 通过 `rt_tgsigqueueinfo` 中断 workers
    2. workers 在 `signal handler` 中，运行 `safe_backtrace()`（等待 coordinator 解析符号的过程中会阻塞）
    3. coordinator 通过 `/proc/self/maps` 计算 ip 偏移，离线符号化
    4. 通知 workers 继续执行

  - 前置条件：
    - ob 中未明确支持 `jemalloc profiling` （与 Doris 有冲突）

  - 风险：
    - 开启 `jemalloc profiling` 可能存在死锁风险（需要实际验证）
      - `unw_step()` 中调用 `dl_iterate_phdr()` 的路径：https://github.com/libunwind/libunwind/blob/af44179ae8fafed497505a124bc48397a84560b7/src/dwarf/Gfind_proc_info-lsb.c#L787

  PS: 未找到 ob 阻塞 workers 的原因，感觉从两阶段改成单阶段也不是不可以（阻塞原因未知）
    - https://github.com/oceanbase/oceanbase/blob/109121611519b2f74bcf154ed8fcbcde7984df19/deps/oblib/src/lib/signal/ob_signal_worker.cpp#L366


3. 未验证方式 1
  - 流程：
    1. 仍然是 coordinator 通过 `rt_tgsigqueueinfo` 中断 workers
    2. workers 在 `signal handler` 中，copy 一段自己的 stack 内存（长度待定）和寄存器快照
    3. coordinator 从各个 stack 快照中挑出 ip（方式待定）

  - 风险：
    - AI 一直说这是自创方案，不如 ck 和 ob 的经过验证的方案可靠，风险未知
    - 未压测过，性能未知


4. 未验证方式 2
  - 前置条件：开启 `-fno-omit-frame-pointer`
  - 可在 worker 中通过 `rip` 和 `rbp` 爬栈收集 ip（待实际验证）

  - 风险：依赖 `-fno-omit-frame-pointer`（其他风险未知）



## 我做了的事情：

1. 从 ck 中试用了下 stacktrace，了解这是个什么功能，目标要做什么

2. 阅读 ck stacktrace 相关实现
  - 发现 ck 的 `updatePHDRCache()`，缓存了 `dl_iterate_phdr`，看起来存在较多风险（暂未全面验证）
  - 发现 ck 自己维护了一套 `llvm`，封装了 `unw_backtrace()` （但改动不大）

3. 阅读 ob 的 kill-60 相关实现
  - 发现 ob 是通过 `/proc/self/maps` 找 `ELF`，离线符号化
  - ob 的实现中，coordinator 解析符号时会阻塞 workers（我没找到非要阻塞的原因）
  - ob 的 `safe_backtrace()` 也是使用和 ck 一样的 `libunwind`（所以风险应该差不多）

4. 从提交历史的时间，猜测出 ob 的相关实现比 ck 要晚，怀疑 ob 实现比 ck 要好（但现在觉得未必）

5. 试着在 doris 中实现
  - 看到这个 PR：https://github.com/apache/doris/pull/22549
  - 看到 ck 的 Jemalloc 编译参数：https://github.com/ClickHouse/ClickHouse/blob/f74c9de34f7b0a956d18330b00544a977ceb0347/contrib/jemalloc-cmake/CMakeLists.txt#L201-L214
  - 发现 doris 使用 -fno-omit-frame-pointer 而不是 -fomit-frame-pointer
  - （感觉情况和我想的不大一样）
