# minimal-impl — design plan (v2)

Standalone lab that isolates two stack-walk implementations under four build
configurations. Frames are stored as `(dso, dso_offset)` so traces survive
ASLR and resolve cleanly both in-process and offline.

Pseudocode below follows `docs/coding-guidelines.md`: every declaration that
encodes a non-obvious choice carries a `Reason:` and a provenance label
(`Spec:` / `Reference:` / `Local:`).

---

## 1. Build matrix

| Variant        | Flags                                            | Purpose                              |
|---             |---                                               |---                                   |
| `asan`         | `-O1 -g -fno-omit-frame-pointer -fsanitize=address` | sanitizer baseline                |
| `tsan`         | `-O1 -g -fno-omit-frame-pointer -fsanitize=thread`  | signal-handler ↔ TSan conflict    |
| `release_fp`   | `-O3 -DNDEBUG -g -fno-omit-frame-pointer`           | Doris BE production                |
| `release_nofp` | `-O3 -DNDEBUG -g -fomit-frame-pointer`              | control: no frame-pointer (fp-walk fails here) |

Each variant builds to `build/<variant>/`. Sibling dirs do not share artefacts.

## 2. Tree

```
minimal-impl/
  CMakeLists.txt   justfile   README.md   PLAN.md   .gitignore
  src/
    stack_walker.h         interface + factories
    stack_walker_fp.cpp    RBP-chain walker
    stack_walker_unwind.cpp  libunwind wrapper
    signal_harness.{h,cpp}   SIGPROF install + TLS sample slot
    workload.{h,cpp}         5-frame deterministic call chain
    resolver.{h,cpp}         pc -> (dso, dso_offset)
    symbolizer.{h,cpp}       (dso, dso_offset) -> "function(arg)"
    main.cpp                 CLI + verifier
  tools/
    elf_inspect.cpp          libdw-based CFI classifier
  scripts/
    build_all.sh   run_matrix.sh   inspect.sh
```

---

## 3. Components

### 3.1 `StackFrame` — the only frame type the API exposes

```cpp
// Reason: a trace identifies code by the loaded module that holds it plus
// the offset into that module. Storing only this lets the trace stay
// valid across ASLR re-runs and lets llvm-symbolizer resolve it from a
// dead dump. Absolute PCs are intermediate state inside the walker and
// are dropped before a Sample leaves the harness.
// Local: minimal-impl-specific frame schema.
struct StackFrame {
    // Reason: path or basename of the loaded ELF (executable or .so) that
    // contains this code. Stable across runs as long as the binary is not
    // rebuilt. Equivalent to dladdr's dli_fname.
    string dso;

    // Reason: byte offset from the dso's load base. The pair
    // (dso, dso_offset) names a code location uniquely and survives ASLR.
    // Equivalent to (pc - dli_fbase).
    uint64_t dso_offset;
};
```

### 3.2 `Mode` — collection trigger

```cpp
// Reason: the harness supports two ways of entering the walker. Each
// exercises a different async-signal-safety boundary, which is the whole
// point of the lab.
enum Mode {
    // Reason: walker is invoked directly from the deepest workload frame
    // on the worker's normal stack. No signal involved. Baseline that
    // shows the walker works at all; not the production case.
    Direct,

    // Reason: workload raises SIGPROF; the kernel delivers it on the
    // same thread; the handler calls the walker. This is the path where
    // TSan's pthread/atomic interceptors can deadlock libunwind, and
    // the path that mirrors the Doris BE collector.
    Signal,
};
```

### 3.3 `RawSample` — handler-local capture buffer

```cpp
// Reason: the signal handler writes raw PCs here, because dladdr() and
// path lookups are not async-signal-safe. Resolution to StackFrame
// happens after the handler returns, on the worker's normal stack.
// Reference: <ck>/src/Storages/System/StorageSystemStackTrace.cpp:381-384
// follows the same in-handler-capture, post-handler-resolve split.
struct RawSample {
    // Reason: an upper bound is required because the handler cannot
    // allocate. 64 is comfortably above the deepest workload chain plus
    // libc startup frames.
    // Local: minimal-impl-specific cap.
    static constexpr int kMax = 64;

    void* pcs[kMax];
    int depth;
};
```

### 3.4 `Sample` — what the verifier and offline dumper consume

```cpp
struct Sample {
    // Reason: depth-prefixed array keeps Sample trivially copyable for
    // the TLS slot and the matrix output paths.
    StackFrame frames[RawSample::kMax];
    int depth;
};
```

### 3.5 `IStackWalker` — contract

```cpp
// Reason: every walker fills a RawSample and is required to be callable
// from a signal handler. Resolution to StackFrame is the harness's job,
// not the walker's, so that walkers stay async-signal-safe.
// Spec: docs/phase2-design.md "Common API" -> Mechanics.
class IStackWalker {
public:
    virtual ~IStackWalker() = default;

    // Reason: writes captured PCs into `out`. Must not allocate, must
    // not call any function that can take a lock the kernel does not
    // guarantee is async-signal-safe.
    virtual int walk(RawSample& out) = 0;

    // Reason: identifying tag the matrix script uses to label cells.
    virtual const char* name() const = 0;
};
```

### 3.6 `FpWalker` — RBP-chain walk

```cpp
// Reason: walks the saved-RBP chain. No library calls, no atomics,
// strictly async-signal-safe. Depends on every frame in the chain being
// built with -fno-omit-frame-pointer; the lab's release_nofp variant
// breaks this assumption deliberately.
// Local: variant under test.
class FpWalker : public IStackWalker {
    int walk(RawSample& out) override {
        // 1. Snapshot RBP at handler entry.
        //    Reason: that's the RBP of the frame that called walk(),
        //    which is the deepest interesting frame to record.
        rbp = read_rbp_via_inline_asm();

        out.depth = 0;
        while (rbp != null && out.depth < RawSample::kMax) {
            // 2. Under SysV x86-64 -fno-omit-frame-pointer:
            //      [rbp + 0] = caller's saved RBP
            //      [rbp + 8] = caller's saved RIP
            saved_rip = *(rbp + 8);
            saved_rbp = *(rbp + 0);

            // 3. Reject backward / null walks.
            //    Reason: a corrupt or omitted-FP chain typically points
            //    to older stack memory or NULL. The stack grows down, so
            //    each saved RBP must sit at a higher address than the
            //    current one. This is the canonical fp-walk safety check.
            //    Local: fp-walk-specific safety check.
            if (saved_rbp <= rbp) break;
            if (saved_rip == null) break;

            out.pcs[out.depth++] = saved_rip;
            rbp = saved_rbp;
        }
        return out.depth;
    }
};
```

### 3.7 `UnwindWalker` — libunwind wrapper

```cpp
// Reason: reads .eh_frame CFI to compute CFA + saved-register locations
// at each PC. Works regardless of -fomit-frame-pointer because the CFI
// encodes the rule directly. The cost is library calls (atomic loads,
// sometimes a mutex) that the kernel does NOT guarantee async-signal-
// safe under TSan — that is the failure mode this lab surfaces.
// Reference: libunwind manual, unw_init_local + unw_step.
class UnwindWalker : public IStackWalker {
    int walk(RawSample& out) override {
        // 1. Capture register context at this point.
        unw_getcontext(&ctx);

        // 2. Initialize a cursor for local (current-process) unwinding.
        //    Reason: UNW_LOCAL_ONLY picks the fast path that reads from
        //    in-memory CFI tables instead of remote-process protocols.
        unw_init_local(&cursor, &ctx);

        out.depth = 0;
        while (out.depth < RawSample::kMax) {
            // 3. Fetch the current frame's PC.
            unw_get_reg(&cursor, UNW_REG_IP, &ip);
            if (ip == 0) break;

            out.pcs[out.depth++] = ip;

            // 4. Step to the caller. Stops at the outermost frame.
            if (unw_step(&cursor) <= 0) break;
        }
        return out.depth;
    }
};
```

### 3.8 `resolver` — PC → (dso, dso_offset)

```cpp
// Reason: bridges the handler's raw PCs to the StackFrame schema the
// rest of the harness uses. Runs OUTSIDE the signal handler, so dladdr
// is allowed even though it can take internal locks.
namespace resolver {

// Reason: resolves one PC. Returns "??" for the dso when the address is
// not backed by any loaded module (a corrupt frame from fp-walk under
// release_nofp lands here).
// Local: minimal-impl-specific.
StackFrame resolve(void* pc) {
    Dl_info info;
    if (dladdr(pc, &info) && info.dli_fname && info.dli_fbase) {
        // Reason: dso_offset = pc - load_base. Stable identifier even
        // after the next ASLR shuffle.
        return { info.dli_fname,
                 (uint64_t)pc - (uint64_t)info.dli_fbase };
    }
    return { "??", (uint64_t)pc };
}

// Reason: bulk convert from RawSample to Sample after the handler exits.
void resolve_all(const RawSample& raw, Sample& out) {
    out.depth = raw.depth;
    for (i in 0 .. raw.depth):
        out.frames[i] = resolve(raw.pcs[i]);
}

}
```

### 3.9 `SignalHarness` — single-thread SIGPROF entry

```cpp
// Reason: routes a SIGPROF into a registered walker and stashes the
// captured RawSample where the worker can pick it up after the handler
// returns. Single-threaded for v1; thread-local storage anchors both the
// walker pointer and the slot.
// Reference: <ck>/src/Storages/System/StorageSystemStackTrace.cpp:381-384
// for the global-slot publish pattern.
namespace SignalHarness {
    // Reason: the handler needs somewhere to publish without allocating.
    // A TLS RawSample lives forever within the thread.
    // Local: minimal-impl-specific.
    thread_local IStackWalker* g_walker;
    thread_local RawSample g_raw;

    void install(IStackWalker* w) {
        // 1. Bind walker to TLS so the handler can find it.
        // 2. Install sigaction with SA_SIGINFO for SIGPROF.
        // 3. Reset raw sample depth.
    }

    void handler(sig, info, ctx) {
        // Reason: trivial dispatch — the walker carries the
        // async-signal-safety responsibility.
        if g_walker: g_walker->walk(g_raw);
    }

    // Reason: post-handler, the worker resolves and publishes the latest
    // sample. Kept off the handler's hot path.
    void publish_to(Sample& out) {
        resolver::resolve_all(g_raw, out);
    }
}
```

### 3.10 `workload` — deterministic five-level chain

```cpp
// Reason: a fixed call chain of known depth and known symbol names lets
// the verifier reason about presence/order. Each level carries gnu::
// noinline + external linkage so neither -O3 inlining nor anonymous-
// namespace internal-linkage hides it from dladdr.
// Local: lab-only fixture.
namespace workload {

// Reason: the verifier looks for these substrings in order, callee-first.
// level0 is excluded because under -O3 it sometimes tail-merges into
// run_chain and loses its frame; the chain from level4..level1 is what
// must always survive.
constexpr const char* kExpected[] = { "level4", "level3", "level2", "level1" };

void leaf();          // calls walker (direct) or raises SIGPROF
int  level4(int x);   // [[gnu::noinline]] — must be its own frame
int  level3(int x);
int  level2(int x);
int  level1(int x);
int  level0(int x);

void run_chain(Mode m);   // installs mode in TLS, calls level0
}
```

### 3.11 `symbolizer` — in-process resolution

```cpp
// Reason: turns a StackFrame back into a function name for the verifier
// and the --print-trace output. Online path; offline path is the
// appendix.
// Local: minimal-impl-specific.
namespace symbolizer {

string symbolize(const StackFrame& f) {
    // 1. Reconstruct the live PC: load_base(f.dso) + f.dso_offset.
    //    Reason: dladdr takes a pointer, not a (dso, offset) pair. We
    //    re-form the absolute PC for the current process. This is safe
    //    because no ASLR shuffle happens within a single process.
    pc = lookup_load_base(f.dso) + f.dso_offset;

    // 2. dladdr -> demangled symbol name.
    if (dladdr(pc, &info) && info.dli_sname):
        return demangle(info.dli_sname);
    return "??";
}
}
```

### 3.12 verifier

```cpp
// Reason: a sample passes when the four expected substrings appear in
// callee-first order somewhere in the resolved chain. Extra system
// frames (gsignal, __libc_start_main) between them are tolerated.
// Local: minimal-impl-specific.
bool verify(const Sample& s) {
    int idx = 0;
    for (i in 0 .. s.depth) {
        if symbolize(s.frames[i]).contains(kExpected[idx]):
            ++idx;
        if idx == 4: return true;
    }
    return false;
}
```

### 3.13 `main` — CLI

```text
min_stack_collect [options]
  --walker  {fp|unwind}        which walker
  --mode    {signal|direct}    collection trigger
  --iters   N                  iterations per run
  --verify                     compare resolved samples to kExpected
  --print-trace                dump last resolved Sample
  --dump-raw                   emit (dso  dso_offset) per frame (for offline)
```

Output line (parsed by `run_matrix.sh`):

```
walker=<W> mode=<M> iters=<N> depth_avg=<D> empty=<E> passed=<P> wrong=<X> result=<PASS|FAIL>
```

### 3.14 `elf_inspect` — libdw classifier

```cpp
// Reason: classifies each function in an ELF by reading the CFA rule
// from .eh_frame at a mid-function PC. Output is derived from the
// binary; no hand-written diagrams. Used to compare release_fp vs
// release_nofp side-by-side.
// Reference: elfutils libdw.h — dwarf_getcfi_elf, dwarf_cfi_addrframe,
// dwarf_frame_cfa.
namespace elf_inspect {

// Reason: the entry PC sits before the prologue runs; the CFI row for
// the entry point always reports "rsp + 8" (the call instruction's
// push). Querying at addr + size/2 lands inside the body, in the
// steady-state row that reflects whether a frame pointer is set up.
// Local: elf_inspect-specific quirk.
Dwarf_Addr query_pc(Func f) = f.addr + f.size / 2;

// Reason: libdw returns CFA as DWARF ops. The two shapes we expect on
// x86-64 are DW_OP_bregN (register encoded in opcode, offset in number)
// and DW_OP_bregx (register in number, offset in number2). Each enum
// branch is the case the parser handles; the catch-all prints the raw
// atom for future debugging.
struct CfaRule {
    int base_reg;        // 6 = rbp, 7 = rsp, -1 = unrecognized
    int64_t offset;
    string text;
};
CfaRule parse_cfa(Dwarf_Op* ops, size_t nops);

// Reason: classification is decisive. (rbp + 16) means frame-pointer
// mode; (rsp + N) means omitted. Anything else is reported verbatim.
enum FrameMode {
    // Reason: CFA = rbp + 16. Compiler set up "push rbp; mov rbp, rsp".
    // fp-walk works; unwind works.
    FramePointer,
    // Reason: CFA = rsp + N for some constant N. RBP is free for any use.
    // fp-walk fails (its assumption is violated); unwind still works
    // because .eh_frame encodes the rsp-based rule.
    FramePointerOmitted,
    // Reason: CFA computation uses a register other than rbp/rsp, or
    // a multi-op expression. Out of scope for this lab; the tool prints
    // the raw rule and points at `readelf --debug-dump=frames-interp`.
    Other,
};
}
```

---

## 4. Build invocation

```
just build VARIANT          # one variant
just build-all              # all four
just run-matrix             # 4 x 2 cells, prints markdown table
just inspect VARIANT        # elf header + selected sections + CFI summary
```

Under the hood:

```
cmake -B build/<v> -DBUILD_VARIANT=<v> -G Ninja -S .
cmake --build build/<v>
```

`elf_inspect` is only built under `release_fp` / `release_nofp` — running it
under a sanitizer would instrument libdw paths for no benefit.

## 5. Expected matrix

| Walker × Variant | asan | tsan | release_fp | release_nofp |
|---|---|---|---|---|
| `fp`     | pass         | pass*    | pass     | **FAIL**  (RBP is not a frame ptr) |
| `unwind` | pass         | FAIL†    | pass     | pass     (libunwind reads .eh_frame) |

\* tsan + fp: passes at small scale; under load and many threads the
"late-handler race under TSan" can corrupt frames (the Phase 2 finding).

† tsan + unwind: passes at small scale in this lab; under Doris's load it
fails with empty frames because libunwind's atomic/pthread interceptors
under TSan are not async-signal-safe.

The two non-trivial cells the lab is designed to surface:

- `release_nofp + fp` — code-generation failure, no sanitizer in play.
  Strongest argument for libunwind on any build that does not pin
  `-fno-omit-frame-pointer`.
- `tsan + unwind` — instrumentation failure inside the signal handler.
  Scale-dependent; reproduces under load.

---

## Appendix A: Offline symbolization with `llvm-symbolizer`

The online flow above resolves symbols in-process via `dladdr`. The
offline flow exists to demonstrate that a `(dso, dso_offset)`-only frame
representation is fully resolvable after the process has exited.

### A.1 Dump frames in the (dso, dso_offset) form

```
$ ./build/release_fp/min_stack_collect \
      --walker unwind --mode signal --iters 1 --dump-raw

dso  dso_offset
./build/release_fp/min_stack_collect  0x3199
./build/release_fp/min_stack_collect  0x31bd
./build/release_fp/min_stack_collect  0x31dd
./build/release_fp/min_stack_collect  0x31fd
./build/release_fp/min_stack_collect  0x321d
./build/release_fp/min_stack_collect  0x324f
./build/release_fp/min_stack_collect  0x3538
/usr/lib/libc.so.6  0x2b6c1
/usr/lib/libc.so.6  0x2b7f9
```

### A.2 Symbolize with `llvm-symbolizer`

Batch form on stdin (one `obj offset` pair per line):

```
$ awk 'NR>1 {print $1, $2}' frames.txt \
  | llvm-symbolizer --demangle --functions=short --output-style=GNU

msc::workload::level4(int)
./build/release_fp/min_stack_collect:?

msc::workload::level3(int)
./build/release_fp/min_stack_collect:?
...
```

Or per-frame:

```
$ llvm-symbolizer \
      --obj=./build/release_fp/min_stack_collect \
      --demangle 0x31bd
msc::workload::level3(int)
```

### A.3 Why offline works on this schema

- The dso path lets the symbolizer open the same ELF used at runtime,
  including its `.symtab` and `.debug_info`.
- The offset is independent of ASLR and remains the same identifier
  forever, as long as that binary is on disk.
- No live process is needed; no core dump is needed; no in-process
  symbol table is needed.

This is the property `(dso, dso_offset)` buys you over absolute PC,
and the reason `StackFrame` drops `pc` entirely.
