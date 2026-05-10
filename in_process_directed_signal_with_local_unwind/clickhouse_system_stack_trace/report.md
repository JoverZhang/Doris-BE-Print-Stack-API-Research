# ClickHouse system.stack_trace Phase 1-B Report

## Verdict

PASS.

This case reproduces ClickHouse `system.stack_trace` on the fixed official release `v26.3.10.62-lts` and proves:

- raw stack PC output from a real ClickHouse server;
- symbol output with `addressToSymbol()` and `demangle()`;
- file/line output with matching `clickhouse-common-static-dbg`;
- inline file/line output with `addressToLineWithInlines()`;
- a separate FP/no-FP backend/build-condition control.

The FP/no-FP control is not a ClickHouse API comparison. ClickHouse exposes one SQL table: `system.stack_trace`.

## Run

```bash
just clickhouse
```

Direct case entry:

```bash
in_process_directed_signal_with_local_unwind/clickhouse_system_stack_trace/scripts/run.sh
```

Host prerequisites are ordinary user-space tools: `curl`, `tar`, coreutils checksums, `readelf`/`addr2line`, `g++`, and `libunwind-dev` for the FP/no-FP control.

Large files are cached and gitignored:

- `cache/clickhouse-common-static-26.3.10.62-amd64.tgz`
- `cache/clickhouse-common-static-dbg-26.3.10.62-amd64.tgz`
- `cache/debug-extract/.../clickhouse.debug`
- `bin/clickhouse`
- `bin/clickhouse.debug`
- server `data/`, `tmp/`, `logs/`

## Release and Debug Info

ClickHouse release:

- URL: <https://github.com/ClickHouse/ClickHouse/releases/download/v26.3.10.62-lts/clickhouse-common-static-26.3.10.62-amd64.tgz>
- Size: `221892115` bytes
- SHA256: see `outputs/clickhouse_package.sha256`

Debug package:

- URL: <https://github.com/ClickHouse/ClickHouse/releases/download/v26.3.10.62-lts/clickhouse-common-static-dbg-26.3.10.62-amd64.tgz>
- Size: `833692025` bytes
- SHA256: `78b4c8d19808951d2ee3607a7114fc6e6e94fdc013678093deafeed9af0d20b1`
- Package member: `clickhouse-common-static-dbg-26.3.10.62/usr/lib/debug/usr/bin/clickhouse.debug`
- Case-local layout: `bin/clickhouse.debug` symlink to the extracted debug binary
- Build ID: `6eb1953afad1495bf822a2e45c41166d34390877` for both `clickhouse` and `clickhouse.debug`

The case-local layout works because ClickHouse `SymbolIndex` first checks for a non-empty sibling debug file named after the executable stem: for `bin/clickhouse`, it checks `bin/clickhouse.debug`. The global layouts are still documented for VM/root installs: `/usr/lib/debug/usr/bin/clickhouse.debug` and `/usr/lib/debug/.build-id/<build-id>.debug`.

## Real ClickHouse Output

Summary from `outputs/phase1b_summary.txt`:

```text
version=26.3.10.62
rows:       657
with_trace: 653
min_trace:  0
max_trace:  17
```

Schema from `outputs/system_stack_trace_describe.txt`:

```text
thread_name String
thread_id UInt64
query_id String
trace Array(UInt64)
untracked_memory Int64
```

Raw trace sample from `outputs/raw_trace.txt`:

```text
thread_name:      TCPHandler
query_id:         <non-empty query id>
trace_len:        17
trace_head:       [651059,603036,603788,614504,396512763]
```

Symbol sample from `outputs/symbol_names.txt`:

```text
'DB::PullingAsyncPipelineExecutor::pull(DB::Chunk&, unsigned long)'
'DB::TCPHandler::runImpl()'
```

File/line sample from `outputs/file_lines_filtered.txt`:

```text
./contrib/llvm-project/libcxx/src/condition_variable.cpp:37
./ci/tmp/build/./src/Loggers/OwnSplitChannel.cpp:515
./base/poco/Foundation/src/Thread_POSIX.cpp:356
```

Inline sample from `outputs/inline_lines.txt`:

```text
./ci/tmp/build/./src/Loggers/OwnSplitChannel.cpp:363
./contrib/llvm-project/libcxx/src/condition_variable.cpp:37:std::__1::condition_variable::wait(...)
```

This satisfies the hard file-line/debug-info gate. The first few frames in some rows still resolve to `bin/clickhouse.debug`; later frames resolve to source paths. That is expected for trampoline/signal/unwind frames where source line data is not useful.

## FP/no-FP Controlled Backend Comparison

Command:

```bash
scripts/run_fp_no_fp_control.sh
```

Result from `outputs/fp_control/depth_summary.csv`:

```text
case,frame_pointer_depth,libunwind_depth
fp_enabled,6,6
fp_omitted,3,6
```

Interpretation:

- The toy frame-pointer walker loses frames when compiled with `-fomit-frame-pointer`.
- `libunwind` still recovers the same depth in this controlled binary because unwind tables are available.
- This is a backend/build-condition comparison only. It does not mean ClickHouse exposes FP and no-FP variants.

## Source Mapping

Source commit: `e1c11930c28196f954a93287e43c1aa112c8c607`.

Key files:

- `src/Storages/System/StorageSystemStackTrace.cpp`
  - signal is `SIGRTMIN` on Linux;
  - enumerates `/proc/self/task`;
  - sends directed signal with `rt_tgsigqueueinfo`;
  - waits with pipe timeout;
  - writes `trace Array(UInt64)` rows.
- `src/Common/StackTrace.cpp`
  - `StackTrace(const ucontext_t&)` aligns captured frames with signal context;
  - `tryCapture()` uses `unw_backtrace()` on Linux.
- `src/Common/SymbolIndex.cpp`
  - documents DWARF debug-info behavior;
  - looks for sibling `<binary>.debug`, `/usr/lib/debug/<binary>.debug`, and build-id debug files;
  - verifies matching build ID before using separate debug info.

## Boundaries

- This case proves ClickHouse release behavior, not Doris BE behavior.
- It proves file-line output only with matching debug info.
- It does not benchmark latency or perturbation.
- It does not cover coroutine/bthread stacks.
- It does not claim FP/no-FP are ClickHouse user-visible modes.
