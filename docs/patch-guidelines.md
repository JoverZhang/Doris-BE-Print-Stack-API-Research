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

See [coding-guidelines.md](coding-guidelines.md).
