#include "stack_walker.h"

#define UNW_LOCAL_ONLY
#include <libunwind.h>

namespace msc {

namespace {

class UnwindWalker final : public IStackWalker {
public:
    size_t walk(Sample& out) override {
        out.depth = 0;

        unw_context_t ctx;
        if (unw_getcontext(&ctx) != 0) return 0;

        unw_cursor_t cursor;
        if (unw_init_local(&cursor, &ctx) != 0) return 0;

        // libunwind reads .eh_frame CFI to compute CFA + saved regs at each
        // PC, so it works regardless of whether the caller used -fno-omit-
        // frame-pointer. Cost: function calls (atomic load, sometimes mutex)
        // that the kernel does NOT guarantee async-signal-safe under TSan.
        while (out.depth < kMaxFrames) {
            unw_word_t ip = 0;
            if (unw_get_reg(&cursor, UNW_REG_IP, &ip) != 0) break;
            if (ip == 0) break;
            out.frames[out.depth++] = reinterpret_cast<void*>(ip);
            int ret = unw_step(&cursor);
            if (ret <= 0) break;
        }
        return out.depth;
    }

    const char* name() const override { return "unwind"; }
};

}  // namespace

std::unique_ptr<IStackWalker> make_unwind_walker() {
    return std::make_unique<UnwindWalker>();
}

}  // namespace msc
