# Patch Guidelines

## Goal

Make each patch easy to review and replay.

## Layout

Use these directories:

- `patches/common/` for common API changes
- `patches/<variant>/` for variant-only changes

Put test patches in `patches/common/`.
Use a `tests-` patch name prefix so reviewers can find test changes quickly.

Examples:

- `0004-tests-native-stack-api.patch`
- `0005-tests-native-stack-timeout.patch`

## Split Rules

Use one `.patch` for one file difference.

Allowed exceptions:

- Put a matching header and implementation pair in one patch.
  Example: `native_stack_action.h` and `native_stack_action.cpp`.
- Put all build-system changes in one patch.
  Example: `CMakeLists.txt`, `*.cmake`, build scripts, and build config files.

Do not mix these changes:

- behavior code and build-system changes
- common API changes and variant changes
- unrelated source files

## Naming

Use sortable numeric prefixes and stable names.

Examples:

- `0001-native-stack-action-api.patch`
- `0002-http-service-registration.patch`
- `0003-build-system.patch`

## Review Rule

A reviewer should understand each patch without reading unrelated files.

## Code Rules

Write only code that is necessary for the variant.

For each new class or function:

- Add a short comment that explains why it exists.
- If it follows reference source, cite the source location in the comment.
- Use an exact file and line reference.

Use these source aliases:

- `<ck>`: `repos/source/ClickHouse-v26.3.10.62-lts`
- `<ob>`: `repos/source/oceanbase-v4.5.0_CE`

Examples:

```cpp
// Reason: mirrors ClickHouse signal-frame unwind setup.
// Reference: <ck>/path/to/source.cpp:120
```

```cpp
// Reason: keeps the request thread out of the two-phase signal wait.
// Reference: <ob>/path/to/source.cpp:88
```

If there is no reference source, explain the local reason:

```cpp
// Reason: tracks one in-flight dump so concurrent HTTP requests return busy.
```

If a function has several core steps, add a numbered comment before each step.
Keep the comment short.

```cpp
// 1. Collect target thread ids.
collect_tids();

// 2. Interrupt each target thread.
signal_tids();

// 3. Build the response from captured frames.
write_response();
```
