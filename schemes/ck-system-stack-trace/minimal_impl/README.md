# Minimal Implementation

This directory contains two source-trace-derived controls for one ClickHouse
`system.stack_trace` scheme:

- `default/`: directed-signal local-unwind demo for the default source-build
  variant. It intentionally uses normal compiler frame-pointer behavior and
  does not add `-fno-omit-frame-pointer`.
- `fp-build/`: frame-pointer-preserving backend/build-condition control. This
  is where `-fno-omit-frame-pointer` and `-fomit-frame-pointer` are compared.

The FP control is not a second ClickHouse user API. Both variants exercise the
same `system.stack_trace` table shape.
