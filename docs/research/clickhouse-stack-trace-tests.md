# ClickHouse `system.stack_trace` Tests

> Owner: agent.
> Source tree: `repos/source/ClickHouse-v26.3.10.62-lts`.
> Scope: only `system.stack_trace`, because it is the ClickHouse feature
> comparable to Doris `print_stack`.

## Conclusion

ClickHouse has three relevant regression tests for `system.stack_trace`.

It does not have a C++ unit test that asserts the stack collector itself.
The closest behavior test is best-effort: it retries up to 100 times and only
requires one successful stack observation.

## Tests

| Test | Layer | What It Proves |
| --- | --- | --- |
| [`02117_show_create_table_system.sql`](../../repos/source/ClickHouse-v26.3.10.62-lts/tests/queries/0_stateless/02117_show_create_table_system.sql) | Schema regression | `system.stack_trace` has the expected public table shape. |
| [`02940_system_stacktrace_optimizations.sh`](../../repos/source/ClickHouse-v26.3.10.62-lts/tests/queries/0_stateless/02940_system_stacktrace_optimizations.sh) | Coordinator regression | Predicates reduce unnecessary signaling. |
| [`03565_system_stack_trace_works.sh`](../../repos/source/ClickHouse-v26.3.10.62-lts/tests/queries/0_stateless/03565_system_stack_trace_works.sh) | Collection regression | Asynchronous collection can return at least one ClickHouse frame. |

## Schema Regression

Source:
[`02117_show_create_table_system.sql`](../../repos/source/ClickHouse-v26.3.10.62-lts/tests/queries/0_stateless/02117_show_create_table_system.sql)

Relevant query:

```sql
use system;
show create table stack_trace format TSVRaw;
```

Expected shape:

```sql
CREATE TABLE system.stack_trace
(
    `thread_name` String,
    `thread_id` UInt64,
    `query_id` String,
    `trace` Array(UInt64),
    `untracked_memory` Int64
)
ENGINE = SystemStackTrace
```

This test does not exercise signal delivery.
It only fixes the table contract.

## Coordinator Regression

Source:
[`02940_system_stacktrace_optimizations.sh`](../../repos/source/ClickHouse-v26.3.10.62-lts/tests/queries/0_stateless/02940_system_stacktrace_optimizations.sh)

Relevant body:

```bash
echo "thread = 0"
$CLICKHOUSE_CLIENT --allow_repeated_settings --send_logs_level=test -m -q \
  "select * from system.stack_trace where thread_id = 0" \
  |& grep -F -o 'Send signal to'

echo "thread != 0"
$CLICKHOUSE_CLIENT --allow_repeated_settings --send_logs_level=test -m -q \
  "select * from system.stack_trace where thread_id != 0 format Null" \
  |& grep -F -o 'Send signal to' \
  | grep -v 'Send signal to 0 threads (total)'

echo "thread_name = 'foo'"
$CLICKHOUSE_CLIENT --allow_repeated_settings --send_logs_level=test -m -q \
  "select * from system.stack_trace where thread_name = 'foo' format Null" \
  |& grep -F -o 'Send signal to 0 threads (total)'
```

The oracle is log text.
It proves the coordinator avoids signals when the query predicate excludes all
targets or does not require stack data.

## Collection Regression

Source:
[`03565_system_stack_trace_works.sh`](../../repos/source/ClickHouse-v26.3.10.62-lts/tests/queries/0_stateless/03565_system_stack_trace_works.sh)

Full body:

```bash
#!/usr/bin/env bash

CURDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$CURDIR"/../shell_config.sh

# system.stack_trace has an inherent race condition in the mechanism of obtaining the data,
# so it works most of the time in practice, and checking that it works at least sometimes is enough for the test.
for _ in {1..100}
do
    ${CLICKHOUSE_LOCAL} "SELECT count() > 0 FROM system.stack_trace WHERE demangle(addressToSymbol(arrayJoin(trace))) LIKE 'DB::%'" | grep -F '1' && break;
done
```

This is the closest ClickHouse precedent for Doris `print_stack` testing.

The test does not require:

- every attempt to succeed
- a fixed frame count
- a fixed frame sequence
- exact source line resolution

It only requires one successful `DB::%` frame observation within 100 attempts.

## Doris Takeaway

ClickHouse treats asynchronous thread stack collection as best effort.

For Doris, exact stack-shape assertions should stay in stable build modes such
as Release, ASAN, and jemalloc.
TSAN should focus on lifecycle properties:

- no crash
- no hang
- no TSAN data race
- timeout and recovery behavior
- stale handler results do not corrupt later coordinator state
