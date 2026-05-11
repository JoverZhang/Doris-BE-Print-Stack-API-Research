SELECT
    thread_name,
    thread_id,
    query_id,
    length(trace) AS trace_len,
    arraySlice(trace, 1, 8) AS trace_head,
    untracked_memory
FROM system.stack_trace
WHERE length(trace) > 0
ORDER BY thread_id
LIMIT 5
FORMAT Vertical
