WITH
    arrayMap(x -> addressToLine(x), trace) AS all_lines,
    arrayFilter(x -> (x != '' AND x NOT LIKE '%/clickhouse'), all_lines) AS source_lines
SELECT
    thread_name,
    thread_id,
    query_id,
    arrayStringConcat(if(notEmpty(source_lines), source_lines, all_lines), '\n') AS res
FROM system.stack_trace
WHERE length(trace) > 0
ORDER BY thread_id
LIMIT 3
FORMAT Vertical
