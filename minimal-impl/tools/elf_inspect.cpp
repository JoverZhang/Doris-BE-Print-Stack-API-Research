// elf_inspect: classify each function in an ELF by its .eh_frame CFI rule.
//
// Output is derived entirely from the binary: section sizes from ELF section
// headers, CFA rules and prologue bytes read directly. No hand-drawn diagrams.
//
// Usage:
//   elf_inspect BINARY                       # summary, default filter "msc::"
//   elf_inspect BINARY --func PATTERN        # detail for funcs matching PATTERN
//   elf_inspect BINARY --filter PATTERN      # override default summary filter
//   elf_inspect BINARY --all                 # show every function
//   elf_inspect BINARY --func ... --filter ''  # detail for everything

#include <cxxabi.h>
#include <dwarf.h>
#include <elfutils/libdw.h>
#include <fcntl.h>
#include <gelf.h>
#include <getopt.h>
#include <libelf.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

struct Func {
    Dwarf_Addr addr = 0;
    Dwarf_Word size = 0;
    std::string raw_name;
    std::string demangled;
};

std::string demangle(const char* sym) {
    if (sym == nullptr) return "";
    int status = 0;
    char* d = abi::__cxa_demangle(sym, nullptr, nullptr, &status);
    std::string r = (status == 0 && d != nullptr) ? d : sym;
    std::free(d);
    return r;
}

const char* x86_64_reg_name(int reg) {
    static const char* names[] = {
        "rax", "rdx", "rcx", "rbx", "rsi", "rdi", "rbp", "rsp",
        "r8",  "r9",  "r10", "r11", "r12", "r13", "r14", "r15",
        "rip",
    };
    if (reg >= 0 && reg < static_cast<int>(sizeof(names) / sizeof(names[0]))) {
        return names[reg];
    }
    return "?";
}

// Render a CFA expression. Returns a tagged result so callers can also know
// the underlying register without re-parsing.
struct CfaRule {
    int base_reg = -1;   // 6=rbp, 7=rsp, -1 if non-trivial
    int64_t offset = 0;
    std::string text;
};

CfaRule format_cfa(Dwarf_Op* ops, size_t nops) {
    CfaRule r;
    if (nops == 1 && ops[0].atom >= DW_OP_breg0 &&
        ops[0].atom <= DW_OP_breg31) {
        // DW_OP_bregN: register encoded in opcode, signed offset in number
        r.base_reg = ops[0].atom - DW_OP_breg0;
        r.offset = static_cast<int64_t>(ops[0].number);
    } else if (nops == 1 && ops[0].atom == DW_OP_bregx) {
        // DW_OP_bregx: register in number, signed offset in number2
        r.base_reg = static_cast<int>(ops[0].number);
        r.offset = static_cast<int64_t>(ops[0].number2);
    } else if (nops == 1 && ops[0].atom >= DW_OP_reg0 &&
               ops[0].atom <= DW_OP_reg31) {
        r.base_reg = ops[0].atom - DW_OP_reg0;
        r.text = x86_64_reg_name(r.base_reg);
        return r;
    } else {
        char dbg[80];
        if (nops >= 1) {
            std::snprintf(dbg, sizeof(dbg),
                          "(unhandled: nops=%zu atom=0x%02x)", nops,
                          static_cast<unsigned>(ops[0].atom));
        } else {
            std::snprintf(dbg, sizeof(dbg), "(nops=0)");
        }
        r.text = dbg;
        return r;
    }
    // bregN / bregx: format "reg + offset" or "reg - offset"
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%s %s %lld", x86_64_reg_name(r.base_reg),
                  r.offset >= 0 ? "+" : "-",
                  static_cast<long long>(r.offset >= 0 ? r.offset : -r.offset));
    r.text = buf;
    return r;
}

// Find the .text section that contains `addr`, and copy up to `n` bytes from
// it. Returns the number of bytes actually copied.
size_t read_prologue_bytes(Elf* elf, Dwarf_Addr addr, unsigned char* out,
                           size_t n) {
    Elf_Scn* scn = nullptr;
    while ((scn = elf_nextscn(elf, scn)) != nullptr) {
        GElf_Shdr sh;
        if (gelf_getshdr(scn, &sh) == nullptr) continue;
        if ((sh.sh_flags & SHF_EXECINSTR) == 0) continue;
        if (addr < sh.sh_addr || addr >= sh.sh_addr + sh.sh_size) continue;
        Elf_Data* data = elf_getdata(scn, nullptr);
        if (data == nullptr) return 0;
        size_t off = addr - sh.sh_addr;
        size_t avail = sh.sh_size - off;
        size_t to_read = std::min(n, avail);
        std::memcpy(out, static_cast<unsigned char*>(data->d_buf) + off,
                    to_read);
        return to_read;
    }
    return 0;
}

// Best-effort interpretation of a few common x86-64 prologue patterns.
// Comments only; the bytes are what they are.
const char* annotate_prologue(const unsigned char* p, size_t n) {
    if (n >= 4 && p[0] == 0x55 && p[1] == 0x48 && p[2] == 0x89 &&
        p[3] == 0xe5) {
        return "push rbp; mov rbp, rsp  (frame-pointer prologue)";
    }
    if (n >= 4 && p[0] == 0x48 && p[1] == 0x83 && p[2] == 0xec) {
        static char buf[64];
        std::snprintf(buf, sizeof(buf),
                      "sub rsp, 0x%02x  (no frame-pointer)", p[3]);
        return buf;
    }
    if (n >= 7 && p[0] == 0x48 && p[1] == 0x81 && p[2] == 0xec) {
        return "sub rsp, imm32  (no frame-pointer)";
    }
    if (n >= 2 && p[0] == 0x41 && (p[1] & 0xf8) == 0x50) {
        return "push r8-r15  (caller-saved push; no fp setup yet)";
    }
    if (n >= 1 && p[0] == 0x53) {
        return "push rbx  (callee-saved; no fp setup)";
    }
    return "(see disassembly for full prologue)";
}

void print_layout_diagram(const CfaRule& cfa, const char* func_name) {
    if (cfa.base_reg == 6 /* rbp */ && cfa.offset == 16) {
        std::printf(
            "  Layout (frame-pointer mode, derived from CFA + SysV x86-64 ABI):\n"
            "    [rbp + 0x08]  caller's saved RIP   <- fp-walk next-pc\n"
            "    [rbp + 0x00]  caller's saved RBP   <- fp-walk next-rbp\n"
            "    [rsp ...   ]  locals/spills\n\n"
            "  fp-walk: reads [rbp+8] for return PC, [rbp+0] for next RBP. OK.\n"
            "  unwind:  reads .eh_frame CFI (CFA=rbp+16) and computes the same. OK.\n");
    } else if (cfa.base_reg == 7 /* rsp */) {
        long long ra_off = cfa.offset - 8;
        std::printf(
            "  Layout (frame-pointer OMITTED, derived from CFA + SysV ABI):\n"
            "    [rsp + 0x%llx]  caller's saved RIP   <- libunwind via .eh_frame\n"
            "    [rsp + 0x00 ]  locals/spills\n\n"
            "  RBP at this point is NOT a frame pointer. It either holds a value\n"
            "  preserved across this call (RBP is callee-saved in SysV x86-64),\n"
            "  or is in active use as a general register.\n\n"
            "  fp-walk: reads [rbp+8] expecting return PC. Result is unrelated\n"
            "           memory; chain stops or diverges. FAILS on %s.\n"
            "  unwind:  computes saved RIP at rsp+0x%llx via .eh_frame. OK.\n",
            static_cast<long long>(ra_off), func_name,
            static_cast<long long>(ra_off));
    } else {
        std::printf(
            "  Layout: CFA rule uses register %s; full analysis omitted for\n"
            "  this code path. Run `readelf --debug-dump=frames-interp` for\n"
            "  the canonical interpreted CFI table.\n",
            x86_64_reg_name(cfa.base_reg));
    }
}

void print_section_summary(Elf* elf) {
    std::printf("== Sections ==\n");
    size_t shstrndx = 0;
    if (elf_getshdrstrndx(elf, &shstrndx) != 0) return;

    Elf_Scn* scn = nullptr;
    while ((scn = elf_nextscn(elf, scn)) != nullptr) {
        GElf_Shdr sh;
        if (gelf_getshdr(scn, &sh) == nullptr) continue;
        const char* name = elf_strptr(elf, shstrndx, sh.sh_name);
        if (name == nullptr) continue;
        if (std::strcmp(name, ".text") == 0 ||
            std::strcmp(name, ".eh_frame") == 0 ||
            std::strcmp(name, ".eh_frame_hdr") == 0 ||
            std::strcmp(name, ".debug_frame") == 0 ||
            std::strcmp(name, ".symtab") == 0 ||
            std::strcmp(name, ".dynsym") == 0) {
            std::printf("  %-16s  size=0x%-8lx  addr=0x%lx\n", name,
                        static_cast<unsigned long>(sh.sh_size),
                        static_cast<unsigned long>(sh.sh_addr));
        }
    }
    std::printf("\n");
}

std::vector<Func> collect_functions(Elf* elf) {
    std::vector<Func> out;
    Elf_Scn* scn = nullptr;
    while ((scn = elf_nextscn(elf, scn)) != nullptr) {
        GElf_Shdr sh;
        if (gelf_getshdr(scn, &sh) == nullptr) continue;
        if (sh.sh_type != SHT_SYMTAB && sh.sh_type != SHT_DYNSYM) continue;
        Elf_Data* data = elf_getdata(scn, nullptr);
        if (data == nullptr) continue;
        size_t nsyms = sh.sh_size / sh.sh_entsize;
        for (size_t i = 0; i < nsyms; ++i) {
            GElf_Sym sym;
            if (gelf_getsym(data, i, &sym) == nullptr) continue;
            if (GELF_ST_TYPE(sym.st_info) != STT_FUNC) continue;
            if (sym.st_value == 0 || sym.st_size == 0) continue;
            const char* name = elf_strptr(elf, sh.sh_link, sym.st_name);
            if (name == nullptr || name[0] == '\0') continue;
            Func f;
            f.addr = sym.st_value;
            f.size = sym.st_size;
            f.raw_name = name;
            f.demangled = demangle(name);
            out.push_back(std::move(f));
        }
        if (!out.empty()) break;  // prefer .symtab over .dynsym
    }
    std::sort(out.begin(), out.end(),
              [](const Func& a, const Func& b) { return a.addr < b.addr; });
    return out;
}

void print_summary(const std::vector<Func>& funcs, Dwarf_CFI* cfi,
                   const std::string& filter) {
    std::printf("== Functions");
    if (!filter.empty()) std::printf(" (filter: \"%s\")", filter.c_str());
    std::printf(" ==\n");
    std::printf("  %-18s %-7s %-20s %s\n", "PC", "Size", "CFA rule", "Function");
    for (const Func& f : funcs) {
        if (!filter.empty() &&
            f.demangled.find(filter) == std::string::npos) {
            continue;
        }
        // Query at mid-function PC: the entry PC sits before the prologue
        // executes, so its CFI row always shows "rsp + 8" (just the call
        // pushed RIP). Mid-function reliably reflects the steady-state
        // rule once the prologue has run.
        Dwarf_Addr query_pc = f.addr + f.size / 2;
        Dwarf_Frame* frame = nullptr;
        CfaRule rule;
        if (dwarf_cfi_addrframe(cfi, query_pc, &frame) == 0) {
            Dwarf_Op* ops = nullptr;
            size_t nops = 0;
            if (dwarf_frame_cfa(frame, &ops, &nops) == 0) {
                rule = format_cfa(ops, nops);
            } else {
                rule.text = "(no CFA info)";
            }
        } else {
            rule.text = "(no FDE)";
        }
        std::printf("  0x%016lx 0x%-5lx %-20s %s\n",
                    static_cast<unsigned long>(f.addr),
                    static_cast<unsigned long>(f.size), rule.text.c_str(),
                    f.demangled.c_str());
    }
    std::printf("\n");
}

void print_detail(const std::vector<Func>& funcs, Elf* elf, Dwarf_CFI* cfi,
                  const std::string& pattern) {
    bool any = false;
    for (const Func& f : funcs) {
        if (f.demangled.find(pattern) == std::string::npos) continue;
        any = true;
        std::printf("== %s ==\n", f.demangled.c_str());
        std::printf("  PC range:  0x%016lx .. 0x%016lx  (size 0x%lx)\n",
                    static_cast<unsigned long>(f.addr),
                    static_cast<unsigned long>(f.addr + f.size),
                    static_cast<unsigned long>(f.size));

        unsigned char buf[16];
        size_t n = read_prologue_bytes(elf, f.addr, buf, sizeof(buf));
        std::printf("  Prologue: ");
        for (size_t i = 0; i < n; ++i) std::printf("%02x ", buf[i]);
        std::printf("\n");
        std::printf("            %s\n", annotate_prologue(buf, n));

        // Query at mid-function — see note in print_summary().
        Dwarf_Addr query_pc = f.addr + f.size / 2;
        Dwarf_Frame* frame = nullptr;
        if (dwarf_cfi_addrframe(cfi, query_pc, &frame) != 0) {
            std::printf("  CFI:      (no FDE covers this PC)\n\n");
            continue;
        }
        Dwarf_Op* ops = nullptr;
        size_t nops = 0;
        if (dwarf_frame_cfa(frame, &ops, &nops) != 0) {
            std::printf("  CFI:      (no CFA expression)\n\n");
            continue;
        }
        CfaRule rule = format_cfa(ops, nops);
        std::printf("  CFA rule: %s\n", rule.text.c_str());
        const char* tag = (rule.base_reg == 6 && rule.offset == 16)
                              ? "frame-pointer mode"
                              : (rule.base_reg == 7 ? "frame-pointer OMITTED"
                                                    : "other");
        std::printf("            %s\n\n", tag);

        print_layout_diagram(rule, f.demangled.c_str());
        std::printf("\n");
    }
    if (!any) {
        std::printf("(no functions matched pattern \"%s\")\n", pattern.c_str());
    }
}

void usage(const char* argv0) {
    std::printf(
        "usage: %s BINARY [options]\n"
        "  --func PATTERN     show detailed CFI + layout for matching funcs\n"
        "  --filter PATTERN   summary filter (default: \"msc::\")\n"
        "  --all              equivalent to --filter \"\"\n"
        "  --help             this message\n",
        argv0);
}

}  // namespace

int main(int argc, char** argv) {
    std::string func_pattern;
    std::string filter = "msc::";
    bool all = false;

    static struct option opts[] = {
        {"func", required_argument, nullptr, 'f'},
        {"filter", required_argument, nullptr, 'F'},
        {"all", no_argument, nullptr, 'a'},
        {"help", no_argument, nullptr, 'h'},
        {nullptr, 0, nullptr, 0},
    };

    int c;
    while ((c = getopt_long(argc, argv, "", opts, nullptr)) != -1) {
        switch (c) {
            case 'f':
                func_pattern = optarg;
                break;
            case 'F':
                filter = optarg;
                break;
            case 'a':
                all = true;
                break;
            case 'h':
                usage(argv[0]);
                return 0;
            default:
                usage(argv[0]);
                return 2;
        }
    }
    if (all) filter = "";

    if (optind >= argc) {
        usage(argv[0]);
        return 2;
    }
    const char* path = argv[optind];

    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        std::fprintf(stderr, "open %s: %s\n", path, std::strerror(errno));
        return 1;
    }

    elf_version(EV_CURRENT);
    Elf* elf = elf_begin(fd, ELF_C_READ, nullptr);
    if (elf == nullptr) {
        std::fprintf(stderr, "elf_begin: %s\n", elf_errmsg(elf_errno()));
        close(fd);
        return 1;
    }
    if (elf_kind(elf) != ELF_K_ELF) {
        std::fprintf(stderr, "%s: not an ELF object\n", path);
        elf_end(elf);
        close(fd);
        return 1;
    }

    Dwarf* dw = dwarf_begin_elf(elf, DWARF_C_READ, nullptr);
    if (dw == nullptr) {
        std::fprintf(stderr, "dwarf_begin_elf: %s\n", dwarf_errmsg(-1));
        elf_end(elf);
        close(fd);
        return 1;
    }
    Dwarf_CFI* cfi = dwarf_getcfi_elf(elf);
    if (cfi == nullptr) {
        std::fprintf(stderr,
                     "no .eh_frame section found in %s (build with -g)\n",
                     path);
        dwarf_end(dw);
        elf_end(elf);
        close(fd);
        return 1;
    }

    std::printf("ELF: %s\n\n", path);
    print_section_summary(elf);

    std::vector<Func> funcs = collect_functions(elf);
    print_summary(funcs, cfi, filter);

    if (!func_pattern.empty()) {
        print_detail(funcs, elf, cfi, func_pattern);
    }

    dwarf_end(dw);
    elf_end(elf);
    close(fd);
    return 0;
}
