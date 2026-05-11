set shell := ["bash", "-eu", "-o", "pipefail", "-c"]
set positional-arguments := true

default:
    @just --list

validate:
    ./scripts/validate_repo.sh

repos-sync:
    ./scripts/sync_repos.sh

repos-check:
    ./scripts/validate_repos.sh

ck-system-stack-trace:
    ./schemes/ck-system-stack-trace/run.sh

ob-observer-kill60:
    ./schemes/ob-observer-kill60/run.sh

ob-ocp-obstack:
    ./schemes/ob-ocp-obstack/run.sh

ob-open-obstack-ptrace:
    ./schemes/ob-open-obstack-ptrace/run.sh

ebpf-perf-bpftrace:
    ./schemes/ebpf-perf-bpftrace/run.sh

ebpf-alloy-pyroscope:
    ./schemes/ebpf-alloy-pyroscope/run.sh

all-phase1:
    just ck-system-stack-trace
    just ob-observer-kill60
    just ob-ocp-obstack
    just ob-open-obstack-ptrace
    just ebpf-perf-bpftrace
    just ebpf-alloy-pyroscope

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
