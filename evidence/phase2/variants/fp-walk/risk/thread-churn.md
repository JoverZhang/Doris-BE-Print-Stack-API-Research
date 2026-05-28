status: PARTIAL

Evidence: all-thread dumps observed normal thread-count drift during startup
and repeat tests. The collector returns `exited_thread` on `tgkill` `ESRCH` and
marks signal-masked threads as `signal_blocked`.

Gap: no dedicated high-rate thread create/exit harness was run.
