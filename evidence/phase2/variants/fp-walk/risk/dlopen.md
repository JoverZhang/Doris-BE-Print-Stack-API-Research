status: SKIPPED

Reason: standalone BE smoke did not include a controlled `dlopen`/`dlclose`
churn harness. fp-walk does not maintain a PHDR cache and computes DSO offsets
from `/proc/self/maps` after collection, so this is lower risk than the PHDR
variant, but the matrix row remains unproven.
