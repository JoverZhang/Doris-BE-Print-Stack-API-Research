# Build

The reproducer is intended to link against the OceanBase vendored libunwind
source tree:

```text
../../.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind
```

That source tree is libunwind `v1.6.2`.

## Build libunwind

```bash
cd ../../.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind
autoreconf -i
mkdir -p _build-local
cd _build-local
../configure --prefix="$PWD/_install"
make -j"$(nproc)"
```

The expected shared library is:

```text
_build-local/src/.libs/libunwind.so.8
```

## Build the Reproducer

```bash
cd ../../../../../../reproduce/dl_iterate_phdr_signal_reentry
bash build.sh
```

`build.sh` links to:

```text
../../.mira/research-sources/oceanbase-kill-60/oceanbase-v4.5.0_CE/libunwind/_build-local/src/.libs
```

Override paths if needed:

```bash
OCEANBASE_LIBUNWIND_ROOT=/path/to/libunwind bash build.sh
OCEANBASE_LIBUNWIND_LIB_DIR=/path/to/libunwind/_build-local/src/.libs bash build.sh
```

Verify the linked library:

```bash
ldd ./libunwind_signal_deadlock_reproducer | grep libunwind
```
