set shell := ["bash", "-eu", "-o", "pipefail", "-c"]
set positional-arguments := true

default:
    @just --list

validate:
    just repos-check
    cmake --preset debug >/dev/null
    cmake --build --preset debug --target stacktrace_minimal_impls stacktrace_risk_cases

repos-sync:
    ./scripts/sync_repos.sh

repos-check:
    ./scripts/validate_repos.sh

cmake-configure:
    cmake --preset debug

cmake-build:
    cmake --build --preset debug --target stacktrace_minimal_impls

all-minimal:
    just cmake-build
    ./schemes/ck-system-stack-trace/minimal_impl/default/run.sh
    ./schemes/ck-system-stack-trace/minimal_impl/fp-build/run.sh
    ./schemes/inprocess-minidump/minimal_impl/run.sh
    ./schemes/ob-observer-kill60/minimal_impl/run.sh
    ./schemes/ob-open-obstack-ptrace/minimal_impl/run.sh
    ./schemes/ebpf-perf-bpftrace/minimal_impl/run.sh
    ./schemes/ebpf-alloy-pyroscope/minimal_impl/run.sh

risk-unwind-without-phdr-cache:
    ./risk_cases/ck_unwind_without_phdr_cache/run.sh

ck-system-stack-trace:
    ./schemes/ck-system-stack-trace/run.sh

ck-query-profiler-trace-log:
    ./schemes/ck-query-profiler-trace-log/run.sh

inprocess-minidump:
    ./schemes/inprocess-minidump/run.sh

ob-observer-kill60:
    ./schemes/ob-observer-kill60/run.sh

ob-open-obstack-ptrace:
    ./schemes/ob-open-obstack-ptrace/run.sh

ebpf-perf-bpftrace:
    ./schemes/ebpf-perf-bpftrace/run.sh

ebpf-alloy-pyroscope:
    ./schemes/ebpf-alloy-pyroscope/run.sh

all-evidence:
    @if [[ "$${RUN_HEAVY_EVIDENCE:-0}" != "1" ]]; then \
      echo "Refusing to rerun heavyweight Phase 1 evidence by default."; \
      echo "Use RUN_HEAVY_EVIDENCE=1 just all-evidence when you explicitly want CK/OB/eBPF project runs."; \
      exit 2; \
    fi
    just ck-system-stack-trace
    just ck-query-profiler-trace-log
    just inprocess-minidump
    just ob-observer-kill60
    just ob-open-obstack-ptrace
    just ebpf-perf-bpftrace
    just ebpf-alloy-pyroscope

all-phase1:
    @echo "all-phase1 now runs lightweight repo-owned minimal implementations only."
    @echo "Use RUN_HEAVY_EVIDENCE=1 just all-evidence for heavyweight source-project evidence reruns."
    just all-minimal

vm-create:
    ./vm/ubuntu-24.04/create.sh

vm-start:
    ./vm/ubuntu-24.04/start.sh

vm-start-bg:
    ./vm/ubuntu-24.04/start_bg.sh

vm-wait-ssh:
    ./vm/ubuntu-24.04/wait_ssh.sh

vm-ssh *args:
    ./vm/ubuntu-24.04/ssh.sh "$@"

vm-stop:
    ./vm/ubuntu-24.04/stop.sh

vm-destroy:
    ./vm/ubuntu-24.04/destroy.sh
