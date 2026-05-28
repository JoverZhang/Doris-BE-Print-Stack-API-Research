# Repeat Result

iterations: 50
endpoint: /api/debug/native_stack?timeout_ms=1000&max_frames=8
status_counts:
- "ok": 50
latency_ms_p50: "76"
latency_ms_p95: "88"
latency_ms_p99: "88"
latency_ms_max: "88"
max_signal_blocked_threads: 4
max_handler_time_ns: 17246469
crash_observed: no
{"status": "OK","msg": "OK"}