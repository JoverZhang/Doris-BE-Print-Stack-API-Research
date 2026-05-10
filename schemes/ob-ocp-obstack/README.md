# ob-ocp-obstack

## What This Verifies

The OCP `obstack_x86_64` route is verified by exact tool provenance and real behavior against OceanBase; it is not replaced by open-source obstack.

## Source Trace

release tag: TBD if source is available
commit: TBD if source is available

```text
TBD if OCP tool source is available:
  <file>:<line> <function>
    -> <file>:<line> <function>
      -> output: OCP obstack output

If source is not available, this section must say source unavailable and list only:
  tool package/version/provenance
  command behavior observed against real observer
  whether it triggers observer signal path or performs external attach
```

## Run

```bash
just ob-ocp-obstack
```

## Inputs / Outputs

| input | output | meaning |
| --- | --- | --- |
| `commands/obstack_collect.sh` | `commands/obstack_collect.out` | OCP tool behavior against a real observer. |

## Minimal Impl

If OCP source is unavailable, `minimal_impl/` must explicitly state that a source-derived minimal implementation is not possible. Do not substitute open-source obstack as OCP implementation evidence.
