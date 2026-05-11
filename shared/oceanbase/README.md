# shared/oceanbase

Shared shell helpers for OceanBase observer runtime fixtures.

This directory is not a research scheme and must not be added to the root
README checklist. Scheme evidence remains owned by:

- `schemes/ob-observer-kill60`
- `schemes/ob-ocp-obstack`
- `schemes/ob-open-obstack-ptrace`

The helper only centralizes duplicated runtime mechanics:

- source-built observer executable checks and metadata printing
- observer run directory layout
- `-N` single-node observer startup arguments and readiness wait
- observer pid resolution through `run/observer.pid` or background child pid
- ptrace-capable podman security arguments
- repo-relative path conversion for podman runners

It must not encode scheme conclusions, evidence status, or root checklist state.
