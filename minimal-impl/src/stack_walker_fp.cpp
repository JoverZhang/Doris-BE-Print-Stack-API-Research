#include "stack_walker.h"

namespace msc {

namespace {

class FpWalker final : public IStackWalker {
public:
    size_t walk(Sample& out) override {
        // Read RBP at point of entry to this function.
        void** rbp;
        asm volatile("movq %%rbp, %0" : "=r"(rbp));

        out.depth = 0;
        void** prev = nullptr;
        while (rbp && out.depth < kMaxFrames) {
            // Frame layout under -fno-omit-frame-pointer (SysV x86-64):
            //   [rbp + 0] = caller's saved RBP
            //   [rbp + 8] = caller's saved RIP
            void* saved_rip = rbp[1];
            void** saved_rbp = static_cast<void**>(rbp[0]);

            // Stack grows down: each saved RBP must be at a higher address
            // than the current one. Bail on any chain that runs the wrong way,
            // which is the canonical fp-walk safety check.
            if (saved_rbp <= rbp) break;
            if (saved_rip == nullptr) break;

            out.frames[out.depth++] = saved_rip;
            prev = rbp;
            rbp = saved_rbp;
            (void)prev;
        }
        return out.depth;
    }

    const char* name() const override { return "fp"; }
};

}  // namespace

std::unique_ptr<IStackWalker> make_fp_walker() {
    return std::make_unique<FpWalker>();
}

}  // namespace msc
