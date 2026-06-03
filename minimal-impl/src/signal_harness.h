#pragma once

#include "stack_walker.h"

namespace msc {

// Single-threaded signal-driven collection harness.
//
// Usage:
//   install(walker);                         // once, sets SIGPROF handler
//   workload::run_chain(Mode::Signal);       // workload calls raise(SIGPROF)
//   const Sample& s = last_sample();         // handler stashed result here
class SignalHarness {
public:
    static void install(IStackWalker* walker);

    // Direct (non-signal) collection from the calling thread.
    static void collect_direct();

    // The most recent sample written by the SIGPROF handler or by
    // collect_direct(). Storage is thread-local.
    static const Sample& last_sample();

    // Reset the sample's depth to 0 between iterations.
    static void clear_sample();
};

}  // namespace msc
