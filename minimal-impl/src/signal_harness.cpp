#include "signal_harness.h"

#include <cstring>
#include <signal.h>

namespace msc {

namespace {

thread_local IStackWalker* g_walker = nullptr;
thread_local Sample g_sample;

void sigprof_handler(int /*sig*/, siginfo_t* /*info*/, void* /*ctx*/) {
    // Note: g_walker dereference inside a signal handler is safe for the
    // fp walker (pure register/memory reads). It is the libunwind walker
    // that triggers the TSan signal-handler conflict — that's the failure
    // mode this lab is designed to surface.
    if (g_walker) {
        g_walker->walk(g_sample);
    }
}

}  // namespace

void SignalHarness::install(IStackWalker* walker) {
    g_walker = walker;
    g_sample.depth = 0;

    struct sigaction sa;
    std::memset(&sa, 0, sizeof(sa));
    sa.sa_flags = SA_SIGINFO | SA_RESTART;
    sa.sa_sigaction = &sigprof_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGPROF, &sa, nullptr);
}

void SignalHarness::collect_direct() {
    if (g_walker) {
        g_walker->walk(g_sample);
    }
}

const Sample& SignalHarness::last_sample() {
    return g_sample;
}

void SignalHarness::clear_sample() {
    g_sample.depth = 0;
}

}  // namespace msc
