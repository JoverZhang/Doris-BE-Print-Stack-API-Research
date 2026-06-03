#pragma once

#include <cstddef>
#include <memory>

namespace msc {

static constexpr size_t kMaxFrames = 64;

struct Sample {
    void* frames[kMaxFrames];
    size_t depth = 0;
};

class IStackWalker {
public:
    virtual ~IStackWalker() = default;
    virtual size_t walk(Sample& out) = 0;
    virtual const char* name() const = 0;
};

std::unique_ptr<IStackWalker> make_fp_walker();
std::unique_ptr<IStackWalker> make_unwind_walker();

}  // namespace msc
