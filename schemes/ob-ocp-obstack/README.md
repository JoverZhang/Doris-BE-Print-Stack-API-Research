# ob-ocp-obstack

## What This Verifies

The OCP `obstack_x86_64` route is verified by exact package provenance and, when a real observer is available, direct collection against that observer; it is not replaced by open-source obstack.

## Source Trace

source availability: no public OCP `obstack_x86_64` source was identified in this repo.
package: `obstack-2.0.4-172024070513.el8.x86_64.rpm`
package URL: <http://mirrors.aliyun.com/oceanbase/development-kit/el/8/x86_64/obstack-2.0.4-172024070513.el8.x86_64.rpm>
RPM sha256: `b3acda83d7a237434f302929553598f1e33930d3ac2953bc611ebf95c48a2a7a`
binary sha256: `274124b1d22ac49c46341f6bfc62051011e74194919a82602e5e1b028ab717cd`
binary BuildID: `5e12ff5305158a33fde1d1cedeb3e6643bb7f124`
reported version: `obstack (2.0.4)`
reported revision: `d91edd6d882a33b69164f8d3e809092408da3a33`

```text
OceanBase v4.5.0_CE source package reference:
deps/init/oceanbase.el8.x86_64.deps:62 obstack-2.0.4-172024070513.el8.x86_64.rpm

OceanBase crash/faststack integration:
deps/oblib/src/lib/signal/ob_signal_handlers.cpp:55 FASTSTACK_SCRIPT
  -> deps/oblib/src/lib/signal/ob_signal_handlers.cpp:56 path_to_obstack="bin/obstack"
  -> deps/oblib/src/lib/signal/ob_signal_handlers.cpp:58 fallback command -v obstack
  -> deps/oblib/src/lib/signal/ob_signal_handlers.cpp:61 "$path_to_obstack -o `cat $(pwd)/run/observer.pid` > stack.<pid>.<date>"
  -> output: stack.<observer_pid>.<timestamp>

Observed package behavior:
obstack --version
  -> obstack (2.0.4), revision d91edd6d882a33b69164f8d3e809092408da3a33

obstack --help
  -> obstack [option(s)] [pid]
  -> -n/--no_parse, -a/--agg, -s/--symbol_path, -d/--debuginfo_path, -o/--no_lineno, -t/--thread_only

Binary string evidence:
  -> /proc/%d/task/
  -> PTRACE_ATTACH / PTRACE_DETACH
  -> libunwind ptrace symbols

Boundary:
  OCP obstack source is unavailable, so this scheme is package provenance
  plus real binary behavior only. It intentionally has no source-derived
  minimal implementation.

Real source-built observer collection:
  target: OceanBase v4.5.0_CE observer built from source in task #29
  observer binary: /work/repos/source/oceanbase-v4.5.0_CE/build_release/src/observer/observer
  observer binary BuildID: 5b9de1e9d53c4ad19d9cf908f44f6b513d2a8da8
  runtime: podman AlmaLinux 8 with --cap-add=SYS_PTRACE --security-opt seccomp=unconfined --security-opt label=disable
  command: obstack -o <observer_pid>
  output: 4247 text lines, 511132 bytes, per-thread symbolized stack output
  stderr summary: task_cnt 379, attach/detach cost 40.825 ms, parse addrs cost 495.396 ms, total 540.121 ms
  output style: thread headers plus function/module frames; -o means no source line numbers
```

## Run

```bash
just ob-ocp-obstack
```

## Inputs / Outputs

| input | output | meaning |
| --- | --- | --- |
| `commands/provenance_probe.sh` | `commands/provenance_probe.out` | OCP package provenance, version, help, and binary string evidence. |
| `commands/obstack_collect.sh` | `commands/obstack_collect.out` | OCP tool behavior against the source-built real observer from task #29. |

`build.sh` only prepares the OCP binary cache through `helpers/prepare_obstack.sh`;
it does not write research `.out` files.

## Minimal Impl

No source-derived minimal implementation is possible for the OCP package without source. The open-source obstack ptrace minimal implementation in `../ob-open-obstack-ptrace/minimal_impl/` is related behavior evidence, not OCP implementation evidence.
