# ob-kill60 Repeat Result

- iterations: 50
- curl_success: 50
- curl_failures: 0
- statuses: {'timeout': 23, 'ok': 27}
- duration_ms_min: 508
- duration_ms_p50: 1040
- duration_ms_p95: 1049
- duration_ms_max: 1051
- mean_ok_threads: 1848.4
- mean_timeout_threads: 15.7
- mean_doris_frames: 5188.1

No curl-level failures or container crashes observed during the loop.

Interpretation: root status remained timeout in successful all-thread dumps because a small tail of Doris threads did not enter the realtime signal handler before the 1000 ms coordinator deadline. Most worker threads returned raw PCs and DSO offsets.
