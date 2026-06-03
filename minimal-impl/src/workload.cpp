#include "workload.h"

#include <signal.h>

#include "signal_harness.h"

// Workload functions are deliberately external-linkage so dladdr() (and
// thus the verifier in main.cpp) can resolve their names from .dynsym.
// The linker is also invoked with -rdynamic for the same reason.
namespace msc::workload {

const char* const kExpectedSubstrings[4] = {
    "level4",
    "level3",
    "level2",
    "level1",
};

namespace {
thread_local Mode g_mode = Mode::Signal;
}

[[gnu::noinline]] void leaf() {
    if (g_mode == Mode::Signal) {
        raise(SIGPROF);
    } else {
        SignalHarness::collect_direct();
    }
}

[[gnu::noinline]] int level4(int x) {
    leaf();
    // The volatile sink prevents the compiler from constant-folding the
    // chain away under -O3 and keeps level4..level1 as distinct frames.
    volatile int sink = x ^ 0x4;
    return sink;
}

[[gnu::noinline]] int level3(int x) {
    int r = level4(x);
    volatile int sink = r ^ 0x3;
    return sink;
}

[[gnu::noinline]] int level2(int x) {
    int r = level3(x);
    volatile int sink = r ^ 0x2;
    return sink;
}

[[gnu::noinline]] int level1(int x) {
    int r = level2(x);
    volatile int sink = r ^ 0x1;
    return sink;
}

[[gnu::noinline]] int level0(int x) {
    int r = level1(x);
    volatile int sink = r ^ 0x0;
    return sink;
}

void run_chain(Mode mode) {
    g_mode = mode;
    SignalHarness::clear_sample();
    volatile int sink = level0(0x42);
    (void)sink;
}

}  // namespace msc::workload
