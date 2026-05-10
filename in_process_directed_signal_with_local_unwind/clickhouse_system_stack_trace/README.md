# ClickHouse system.stack_trace

Owner: task #17.

This case proves real ClickHouse `system.stack_trace` output on fixed release `v26.3.10.62-lts`, including raw PCs, symbols, file/line, and inline file/line after installing matching debug info.

It also contains a separate FP/no-FP controlled backend comparison. That comparison is not a ClickHouse user API. It only shows how a frame-pointer walker and libunwind respond to build conditions.

Run:

```bash
just clickhouse
```

Host prerequisites:

- `curl`, `tar`, `sha512sum`, `sha256sum`, `readelf`
- `g++`, `addr2line`
- libunwind development package for the FP/no-FP control (`libunwind-dev` on Debian/Ubuntu)

Direct run from this case:

```bash
scripts/run.sh
```

Important cache rule: `cache/`, `bin/`, `data/`, `logs/`, and `clickhouse.debug` are gitignored. The debug package is large, so the repo stores only scripts, fixed URLs/checksums, small output samples, and the report.

Key outputs:

- `outputs/raw_trace.txt`
- `outputs/symbol_names.txt`
- `outputs/file_lines.txt`
- `outputs/file_lines_filtered.txt`
- `outputs/inline_lines.txt`
- `outputs/fp_control/depth_summary.csv`
- `outputs/debug_info_layout.txt`

The case-local debug layout is preferred: `bin/clickhouse.debug` symlinks to the extracted cache file. If case-local discovery fails in a different environment, use the global ClickHouse-supported layout `/usr/lib/debug/usr/bin/clickhouse.debug` or `/usr/lib/debug/.build-id/<build-id>.debug` inside a VM/root environment.
