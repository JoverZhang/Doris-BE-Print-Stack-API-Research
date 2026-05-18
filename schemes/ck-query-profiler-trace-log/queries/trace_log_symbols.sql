SELECT
    trace_type,
    thread_id,
    length(trace) AS frames,
    arraySlice(arrayMap(x -> demangle(addressToSymbol(x)), trace), 1, 8) AS symbols,
    arraySlice(arrayMap(x -> addressToLine(x), trace), 1, 8) AS lines
FROM system.trace_log
WHERE (query_id = '{query_id}') AND (length(trace) > 0)
ORDER BY event_time_microseconds, thread_id
LIMIT 3
FORMAT Vertical
