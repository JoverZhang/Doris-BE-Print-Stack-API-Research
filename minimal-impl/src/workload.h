#pragma once

namespace msc::workload {

enum class Mode {
    Direct,  // workload calls walker inline (no signal)
    Signal,  // workload raises SIGPROF; handler runs walker
};

// Run the canonical 5-level call chain: level0 -> level1 -> ... -> level4
// -> leaf. Collection is triggered at the deepest frame, per `mode`.
void run_chain(Mode mode);

// Function names the verifier expects to find, callee-first, in any
// trace that successfully captured this chain.
extern const char* const kExpectedSubstrings[4];
constexpr int kExpectedCount = 4;

}  // namespace msc::workload
