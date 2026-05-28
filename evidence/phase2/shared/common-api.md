# Shared Common API

Endpoint: `GET /api/debug/native_stack`

Registration: `TPrivilegeHier::GLOBAL`, `TPrivilegeType::ADMIN`.

Query params:

- `tid`: optional target thread id.
- `timeout_ms`: default `100`, range `1..60000`.
- `max_frames`: default `64`, range `1..1024`.
- `max_stack_bytes`: default `8192`, range `0..1048576`.
- `test_sleep_ms`: test-only hook for timeout/busy smoke tests.

Root JSON fields:

- `status`
- `collector`
- `timeout_ms`
- `max_frames_per_thread`
- `max_copied_stack_bytes`
- `elapsed_ms`
- `target_tid` when requested
- `threads`

Per-thread fields:

- `tid`
- `status`
- `truncated`
- `error_reason`
- `frames`

The common patch intentionally returns empty `frames` with `collector: "stub"`. Real PC collection belongs to variant patches.

