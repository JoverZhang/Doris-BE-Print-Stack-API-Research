SELECT
    thread_name,
    thread_id,
    arrayMap(x -> demangle(addressToSymbol(x)), arraySlice(trace, 1, 8)) AS symbols
FROM system.stack_trace
WHERE length(trace) > 0
ORDER BY thread_id
LIMIT 5
FORMAT Vertical
