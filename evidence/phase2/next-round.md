# Next Round

Status: proposed execution order.

## Goal

Turn Phase 2 from exploratory evidence into a reviewable decision.

## Order

1. Keep this cleanup commit separate from any new experiment.
2. Freeze `evaluation-protocol.md` as the acceptance contract.
3. Build a shared harness for build/run/API/repeat/load/churn rows.
4. Run one calibration variant end to end before subagent fan-out.
5. Rerun `fp-walk` under the full protocol.
6. Rerun only the alternatives still worth testing after policy gates.
7. Write final comparison from matrix results only.

## Calibration Choice

Use `snapshot-remote-unwind` as the next calibration target.

Reason:

- It tests the safest handler model.
- It directly answers whether stack snapshot size changes frame depth.
- It forces an explicit remote-unwind capability check before BE work.
- It avoids spending more time on handler-side libunwind variants if the
  production policy rejects them.

## Parallelism Rule

Do not fan out subagents until the harness, evidence schema, and one calibration
run are complete. After that, subagents receive the standard brief template and
may not solve shared build/API issues independently.
