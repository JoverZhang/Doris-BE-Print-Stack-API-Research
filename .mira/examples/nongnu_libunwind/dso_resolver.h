#pragma once

#include <cstdint>
#include <string>

struct DsoInfo {
    std::string path;
    std::uintptr_t base = 0;
    bool found = false;

    std::uintptr_t offset_of(std::uintptr_t pc) const;
};

DsoInfo resolve_dso(std::uintptr_t pc);
