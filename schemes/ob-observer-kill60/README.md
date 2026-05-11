# ob-observer-kill60

## What This Verifies

OceanBase observer built from source can handle `kill -60 <observer_pid>` and emit real observer stack output.

## Source Trace

release tag: `v4.5.0_CE`
commit: `0e8d5ad012baf0953b2032a35a88bdf8886e9a7a`

```text
deps/oblib/src/lib/allocator/ob_tc_malloc.cpp:127 init_global_memory_pool
  -> deps/oblib/src/lib/signal/ob_signal_handlers.cpp:73 install_ob_signal_handler
    -> deps/oblib/src/lib/signal/ob_signal_handlers.cpp:80-81 sigaction(SIGURG, handler)

src/observer/main.cpp:521-531 inner_main
  -> sigaltstack(...)
  -> src/observer/main.cpp:531 g_redirect_handler = true
  -> src/observer/main.cpp:562 ObSignalHandle::change_signal_mask()
  -> src/observer/main.cpp:638 ObProcMaps::get_instance().load_maps()
  -> src/observer/ob_server.cpp:958 ObServer::start_sig_worker_and_handle()
    -> src/observer/ob_server.cpp:921 sig_worker_->start()
    -> src/observer/ob_server.cpp:923 signal_handle_->start()

src/observer/ob_signal_handle.cpp:37 ObSignalHandle::run1
  -> src/observer/ob_signal_handle.cpp:54 sigtimedwait(...)
  -> src/observer/ob_signal_handle.cpp:105 ObSignalHandle::deal_signals
    -> src/observer/ob_signal_handle.cpp:235 case 60
      -> src/observer/ob_signal_handle.cpp:237 send_request_and_wait(VERB_LEVEL_1, syscall(SYS_gettid))

deps/oblib/src/lib/signal/ob_signal_worker.cpp:31 send_request_and_wait
  -> deps/oblib/src/lib/signal/ob_signal_worker.cpp:66-74 pipe2(...) and write request to worker pipe
  -> deps/oblib/src/lib/signal/ob_signal_worker.cpp:79-83 wait/read request ack

deps/oblib/src/lib/signal/ob_signal_worker.cpp:164 ObSignalWorker::run1
  -> deps/oblib/src/lib/signal/ob_signal_worker.cpp:224-227 NEW_PROCESSOR(ObSigBTOnlyProcessor)
  -> deps/oblib/src/lib/signal/ob_signal_worker.cpp:247 processor->start()
  -> deps/oblib/src/lib/signal/ob_signal_worker.cpp:248 iter_task(task_process, ...)

deps/oblib/src/lib/signal/ob_signal_worker.cpp:99 iter_task
  -> deps/oblib/src/lib/signal/ob_signal_worker.cpp:109 open("/proc/self/task/")
  -> deps/oblib/src/lib/signal/ob_signal_worker.cpp:117 syscall(SYS_getdents64, ...)
  -> deps/oblib/src/lib/signal/ob_signal_worker.cpp:131 cb(tgid, tid, ...)

deps/oblib/src/lib/signal/ob_signal_worker.cpp:280 task_process
  -> deps/oblib/src/lib/signal/ob_signal_struct.cpp:25 MP_SIG = SIGURG
  -> deps/oblib/src/lib/signal/ob_signal_worker.cpp:304-309 syscall(SYS_rt_tgsigqueueinfo, tgid, tid, MP_SIG, &si)
  -> deps/oblib/src/lib/signal/ob_signal_worker.cpp:315-319 wait/read target-thread prepare ack
  -> deps/oblib/src/lib/signal/ob_signal_worker.cpp:330 processor->process()

deps/oblib/src/lib/signal/ob_signal_handlers.cpp:103 ob_signal_handler
  -> deps/oblib/src/lib/signal/ob_signal_handlers.cpp:109-115 if MP_SIG then ctx.handler_->handle(ctx)
    -> deps/oblib/src/lib/signal/ob_signal_worker.cpp:349 ObSigHandler::handle
      -> deps/oblib/src/lib/signal/ob_signal_worker.cpp:356 ctx.processor_->prepare()

deps/oblib/src/lib/signal/ob_signal_processor.cpp:23 ObSigBTOnlyProcessor::ObSigBTOnlyProcessor
  -> deps/oblib/src/lib/signal/ob_signal_processor.cpp:28-33 open stack.<pid>.<datetime>
deps/oblib/src/lib/signal/ob_signal_processor.cpp:43 ObSigBTOnlyProcessor::start
  -> deps/oblib/src/lib/signal/ob_signal_processor.cpp:46-47 write /proc maps into stack file
deps/oblib/src/lib/signal/ob_signal_processor.cpp:51 ObSigBTOnlyProcessor::prepare
  -> deps/oblib/src/lib/signal/ob_signal_processor.cpp:56-60 write tid/tname prefix
  -> deps/oblib/src/lib/signal/ob_signal_processor.cpp:63 safe_backtrace(...)
deps/oblib/src/lib/signal/ob_signal_processor.cpp:70 ObSigBTOnlyProcessor::process
  -> deps/oblib/src/lib/signal/ob_signal_processor.cpp:73-75 write one thread stack line

deps/oblib/src/lib/signal/ob_libunwind.c:26 safe_backtrace
  -> deps/oblib/src/lib/signal/ob_libunwind.c:30 unw_getcontext
  -> deps/oblib/src/lib/signal/ob_libunwind.c:55 get_stack_trace_inplace
    -> deps/oblib/src/lib/signal/ob_libunwind.c:61 unw_init_local
    -> deps/oblib/src/lib/signal/ob_libunwind.c:70 unw_step
    -> deps/oblib/src/lib/signal/ob_libunwind.c:84 get_frame_info
      -> deps/oblib/src/lib/signal/ob_libunwind.c:87 unw_get_reg(UNW_REG_IP)
  -> output: stack.<pid>.<datetime>
```

## Run

```bash
SKIP_MINIMAL=1 \
OBSERVER_BIN=/work/repos/source/oceanbase-v4.5.0_CE/build_release/src/observer/observer \
  ./schemes/ob-observer-kill60/run.sh
```

The recorded runtime uses podman AlmaLinux 8 with the main repo mounted at `/work` so the source-built
observer RUNPATH can resolve its deps cache. The direct host source build remains blocked because
Arch lacks `rpmextract.sh`; that is an environment blocker, not an OceanBase compile failure.
`minimal_impl/` was rerun separately on the host; the podman runtime uses `SKIP_MINIMAL=1` because the
AlmaLinux 8 base repositories used here do not provide `libunwind-devel`.

## Inputs / Outputs

| input | output | meaning |
| --- | --- | --- |
| `commands/observer_kill60.sh` | `commands/observer_kill60.out` | `kill -60` run against a real source-built observer and normalized stack result. |

## Evidence

- Source build: PASS in podman AlmaLinux 8 from `repos/source/oceanbase-v4.5.0_CE` at commit `0e8d5ad012baf0953b2032a35a88bdf8886e9a7a`.
- Observer binary: `/work/repos/source/oceanbase-v4.5.0_CE/build_release/src/observer/observer`, 4550125568 bytes, BuildID `5b9de1e9d53c4ad19d9cf908f44f6b513d2a8da8`, with debug info, not stripped.
- Dependency workaround: podman `wget` against upstream RPMs was unstable, so host `curl -C -` prefetched 50 RPMs and the container wrapper copied only from the complete cache.
- Runtime: PASS. `kill -60` against the source-built observer produced `stack.109.202651020300`, 82686 bytes, with 377 `tid:` stack lines.
- Runtime requirements found during reproduction: run observer with `-N`, use the background child pid because `run/observer.pid` is not created in this mode, precreate `store/{clog,slog,sstable}` and `run`, and set `__min_full_resource_pool_memory=1073741824` with `system_memory=1G`.

## Minimal Impl

`minimal_impl/` keeps signal 60 trigger, thread enumeration, per-thread signal, local unwind, and stack-file output. It omits OceanBase storage, SQL, election, tenants, logging, and deployment. It does not replace a real observer run.
