set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

default:
    @just --list

env:
    ./scripts/collect_env.sh

validate:
    ./scripts/validate_repo.sh

report:
    ./scripts/build_report.sh

vm-create:
    ./vm/ubuntu-24.04/create.sh

vm-start:
    ./vm/ubuntu-24.04/start.sh

vm-start-bg:
    ./vm/ubuntu-24.04/start_bg.sh

vm-wait-ssh:
    ./vm/ubuntu-24.04/wait_ssh.sh

vm-ssh:
    ./vm/ubuntu-24.04/ssh.sh

vm-stop:
    ./vm/ubuntu-24.04/stop.sh

vm-destroy:
    ./vm/ubuntu-24.04/destroy.sh

clickhouse:
    ./in_process_directed_signal_with_local_unwind/clickhouse_system_stack_trace/scripts/run.sh

oceanbase-observer:
    ./in_process_directed_signal_with_local_unwind/oceanbase_observer_signal_worker/scripts/run.sh

obstack-external:
    ./external_ptrace_remote_unwind/oceanbase_obstack_external/scripts/run.sh

perf-ebpf:
    ./kernel_perf_ebpf_user_stack/perf_ebpf_vm/scripts/run.sh
