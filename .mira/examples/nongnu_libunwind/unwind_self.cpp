#define UNW_LOCAL_ONLY

#include <dlfcn.h>
#include <elf.h>
#include <inttypes.h>
#include <libunwind.h>
#include <link.h>
#include <limits.h>
#include <unistd.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

struct DsoInfo {
    std::string path;
    std::uintptr_t base = 0;
};

struct ResolveRequest {
    std::uintptr_t pc = 0;
    DsoInfo dso;
    bool found = false;
};

using StepFn = int (*)(int);

volatile std::uintptr_t g_sink = 0;

std::string read_link(const char* path) {
    char buffer[PATH_MAX];
    const ssize_t len = ::readlink(path, buffer, sizeof(buffer) - 1);
    if (len < 0) {
        return {};
    }
    buffer[len] = '\0';
    return buffer;
}

const std::string& self_exe_path() {
    static const std::string path = [] {
        std::string resolved = read_link("/proc/self/exe");
        return resolved.empty() ? std::string {"/proc/self/exe"} : resolved;
    }();
    return path;
}

void touch_sink(std::uintptr_t value) {
    const std::uintptr_t previous = g_sink;
    g_sink = previous ^ (value + 0x9e3779b97f4a7c15ULL + (previous << 6U) + (previous >> 2U));
}

int phdr_callback(dl_phdr_info* info, std::size_t, void* data) {
    auto* request = static_cast<ResolveRequest*>(data);
    for (ElfW(Half) i = 0; i < info->dlpi_phnum; ++i) {
        const ElfW(Phdr)& phdr = info->dlpi_phdr[i];
        if (phdr.p_type != PT_LOAD) {
            continue;
        }

        const std::uintptr_t start = static_cast<std::uintptr_t>(info->dlpi_addr) + phdr.p_vaddr;
        const std::uintptr_t end = start + phdr.p_memsz;
        if (request->pc >= start && request->pc < end) {
            const char* name = info->dlpi_name;
            request->dso.path = (name != nullptr && name[0] != '\0') ? name : self_exe_path();
            request->dso.base = static_cast<std::uintptr_t>(info->dlpi_addr);
            request->found = true;
            return 1;
        }
    }
    return 0;
}

DsoInfo resolve_dso(std::uintptr_t pc) {
    ResolveRequest request;
    request.pc = pc;
    (void)::dl_iterate_phdr(phdr_callback, &request);
    if (!request.found) {
        request.dso.path = "<unknown>";
        request.dso.base = 0;
    }
    return request.dso;
}

std::string proc_name(unw_cursor_t* cursor) {
    char name[512];
    unw_word_t offset = 0;
    const int rc = unw_get_proc_name(cursor, name, sizeof(name), &offset);
    if (rc < 0) {
        return "<unknown>";
    }
    return name;
}

int capture_current_stack(int seed) {
    unw_context_t context;
    unw_cursor_t cursor;

    if (unw_getcontext(&context) < 0) {
        std::fprintf(stderr, "unw_getcontext failed\n");
        return 2;
    }
    if (unw_init_local(&cursor, &context) < 0) {
        std::fprintf(stderr, "unw_init_local failed\n");
        return 3;
    }

    std::vector<std::uintptr_t> pcs;
    pcs.reserve(64);

    for (std::size_t index = 0; index < 128; ++index) {
        unw_word_t ip = 0;
        if (unw_get_reg(&cursor, UNW_REG_IP, &ip) < 0) {
            break;
        }
        if (ip == 0) {
            break;
        }

        const auto pc = static_cast<std::uintptr_t>(ip);
        DsoInfo dso = resolve_dso(pc);
        const std::uintptr_t dso_offset = dso.base == 0 ? pc : pc - dso.base;
        const std::string name = proc_name(&cursor);
        pcs.push_back(pc);

        std::printf("FRAME\t%zu\t0x%016" PRIxPTR "\t%s\t0x%016" PRIxPTR "\t%s\n",
                    index,
                    pc,
                    dso.path.c_str(),
                    dso_offset,
                    name.c_str());

        const int step = unw_step(&cursor);
        if (step <= 0) {
            break;
        }
    }

    for (std::uintptr_t pc : pcs) {
        touch_sink(pc);
    }
    return seed + static_cast<int>(pcs.size());
}

} // namespace

extern "C" int lw_capture_self_stack(int seed);
extern "C" int lw_level3(int seed);
extern "C" int lw_level2(int seed);
extern "C" int lw_level1(int seed);

StepFn volatile g_capture_fn = lw_capture_self_stack;
StepFn volatile g_level3_fn = lw_level3;
StepFn volatile g_level2_fn = lw_level2;
StepFn volatile g_level1_fn = lw_level1;

extern "C" int lw_capture_self_stack(int seed) {
    const int result = capture_current_stack(seed + 41);
    touch_sink(static_cast<std::uintptr_t>(result));
    return result + seed;
}

extern "C" int lw_level3(int seed) {
    StepFn fn = g_capture_fn;
    const int result = fn(seed + 31);
    touch_sink(static_cast<std::uintptr_t>(result ^ seed));
    return result + seed + 3;
}

extern "C" int lw_level2(int seed) {
    StepFn fn = g_level3_fn;
    const int result = fn(seed + 23);
    touch_sink(static_cast<std::uintptr_t>(result + seed));
    return result - seed + 2;
}

extern "C" int lw_level1(int seed) {
    StepFn fn = g_level2_fn;
    const int result = fn(seed + 17);
    touch_sink(static_cast<std::uintptr_t>(result * 3 + seed));
    return result ^ (seed + 1);
}

int main(int argc, char** argv) {
    const int seed = argc > 1 ? std::atoi(argv[1]) : 7;
    StepFn fn = g_level1_fn;
    const int result = fn(seed);
    touch_sink(static_cast<std::uintptr_t>(result));
    std::printf("RESULT\t%d\t0x%016" PRIxPTR "\n", result, static_cast<std::uintptr_t>(g_sink));
    return 0;
}
