SELECT sum(number)
FROM numbers({rows})
SETTINGS
    query_profiler_cpu_time_period_ns = {cpu_period_ns},
    query_profiler_real_time_period_ns = 0
