SELECT
    trace_type,
    count() AS samples,
    uniqExact(thread_id) AS sampled_threads,
    min(length(trace)) AS min_frames,
    max(length(trace)) AS max_frames
FROM system.trace_log
WHERE query_id = '{query_id}'
GROUP BY trace_type
ORDER BY trace_type
FORMAT Vertical
