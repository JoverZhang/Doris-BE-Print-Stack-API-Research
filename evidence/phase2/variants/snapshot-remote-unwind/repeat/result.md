# Repeat Result

Single target TID: 736

| kind | runs | statuses | elapsed_ms min/p50/max | ok min/max | multi-frame max | max frames/thread max |
|---|---:|---|---:|---:|---:|---:|
| all-threads | 5 | timeout | 4083/4117/4175 | 1861/1864 | 0 | 1 |
| one-tid | 20 | ok | 6/7/9 | 1/1 | 0 | 1 |

Result: signal snapshot collection was stable for the selected TID. Full-thread dumps consistently timed out in this idle standalone BE because a small number of threads did not run the handler before the 1000ms deadline; most threads still produced raw PC snapshots. Frame depth remained 1 because libunwind remote address-space creation is stubbed in the image and the FP fallback could not walk from the copied stack.
