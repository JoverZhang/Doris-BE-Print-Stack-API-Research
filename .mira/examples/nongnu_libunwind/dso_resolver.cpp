#include "dso_resolver.h"

#include <elf.h>
#include <link.h>
#include <limits.h>
#include <unistd.h>

namespace {

struct ResolveRequest {
    std::uintptr_t pc = 0;
    DsoInfo dso;
};

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
            request->dso.found = true;
            return 1;
        }
    }
    return 0;
}

} // namespace

std::uintptr_t DsoInfo::offset_of(std::uintptr_t pc) const {
    return base == 0 ? pc : pc - base;
}

DsoInfo resolve_dso(std::uintptr_t pc) {
    ResolveRequest request;
    request.pc = pc;
    (void)::dl_iterate_phdr(phdr_callback, &request);
    if (!request.dso.found) {
        request.dso.path = "<unknown>";
    }
    return request.dso;
}
