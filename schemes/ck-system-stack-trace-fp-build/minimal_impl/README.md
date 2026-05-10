# Minimal Impl

`fp_vs_unwind.cpp` is a build-condition/backend control derived from the scheme Source Trace:

- ClickHouse still captures through `StackTrace::tryCapture()` and `unw_backtrace()`.
- The source build option `DISABLE_OMIT_FRAME_POINTER=ON` adds `-fno-omit-frame-pointer -mno-omit-leaf-frame-pointer`.
- This demo compares a small manual frame-pointer walker with libunwind under `-fno-omit-frame-pointer` and `-fomit-frame-pointer`.

This is not a second ClickHouse user API. It only demonstrates why preserving frame pointers changes the behavior of frame-pointer-based capture backends.

This is mechanism evidence only. It does not replace the ClickHouse source-build project run.

Run:

```bash
./minimal_impl/run.sh
```
