#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "doris_stacktrace_internal.h"

#include <elf.h>
#include <libunwind.h>
#include <link.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ucontext.h>

#include <algorithm>
#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

// Generic (non-local) libunwind FDE table search. Not declared in any libunwind
// header but exported from libunwind-x86_64.so as _Ux86_64_dwarf_search_unwind_table.
extern "C" int _Ux86_64_dwarf_search_unwind_table(unw_addr_space_t as,
                                                  unw_word_t       ip,
                                                  unw_dyn_info_t  *di,
                                                  unw_proc_info_t *pi,
                                                  int              need_unwind_info,
                                                  void            *arg);

namespace doris::stacktrace::internal {

namespace {

// DW_EH_PE encoding constants.
constexpr unsigned char kEhPeOmit    = 0xff;
constexpr unsigned char kEhPeFormatMask = 0x0f;
constexpr unsigned char kEhPeApplMask   = 0x70;
constexpr unsigned char kEhPeUdata4  = 0x03;
constexpr unsigned char kEhPeSdata4  = 0x0b;
constexpr unsigned char kEhPePcrel   = 0x10;
constexpr unsigned char kEhPeDatarel = 0x30;

struct LoadSegment {
  std::uintptr_t vstart;
  std::uintptr_t vend;
};

struct DsoInfo {
  std::uintptr_t           text_start;
  std::uintptr_t           text_end;
  std::uintptr_t           eh_frame_hdr_addr;
  std::uintptr_t           table_addr;
  unsigned                 fde_count;
  std::vector<LoadSegment> load_segments;
  std::string              name;
};

struct DsoCache {
  std::mutex            mu;
  std::vector<DsoInfo>  dsos;  // sorted by text_start

  const DsoInfo *find_by_ip(std::uintptr_t ip) const {
    auto it = std::upper_bound(dsos.begin(), dsos.end(), ip,
        [](std::uintptr_t v, const DsoInfo &d) { return v < d.text_start; });
    if (it == dsos.begin()) return nullptr;
    --it;
    return (ip >= it->text_start && ip < it->text_end) ? &*it : nullptr;
  }

  bool address_readable(std::uintptr_t addr, std::size_t bytes) const {
    auto it = std::upper_bound(dsos.begin(), dsos.end(), addr,
        [](std::uintptr_t v, const DsoInfo &d) { return v < d.text_start; });
    if (it == dsos.begin()) return false;
    --it;
    for (const auto &seg : it->load_segments) {
      if (addr >= seg.vstart && addr + bytes <= seg.vend) return true;
    }
    return false;
  }
};

DsoCache &cache() {
  static DsoCache c;
  return c;
}

bool decode_eh_frame_hdr(std::uintptr_t hdr_addr, std::uintptr_t hdr_end,
                         unsigned *out_fde_count, std::uintptr_t *out_table) {
  if (hdr_end < hdr_addr + 4) return false;
  const unsigned char *p = reinterpret_cast<const unsigned char *>(hdr_addr);
  unsigned char version          = p[0];
  unsigned char eh_frame_ptr_enc = p[1];
  unsigned char fde_count_enc    = p[2];
  unsigned char table_enc        = p[3];
  if (version != 1) return false;
  if (fde_count_enc == kEhPeOmit || table_enc == kEhPeOmit) return false;

  std::uintptr_t cursor = hdr_addr + 4;

  // Skip eh_frame_ptr. We only support the two encodings GCC/ld emit:
  // pcrel|sdata4 (0x1b) and absptr (0x00). Both are 4 or 8 bytes wide.
  if (eh_frame_ptr_enc != kEhPeOmit) {
    unsigned char fmt = eh_frame_ptr_enc & kEhPeFormatMask;
    if (fmt == kEhPeUdata4 || fmt == kEhPeSdata4) {
      cursor += 4;
    } else if (fmt == 0x00 /* absptr */) {
      cursor += sizeof(std::uintptr_t);
    } else if (fmt == 0x04 /* udata8 */ || fmt == 0x0c /* sdata8 */) {
      cursor += 8;
    } else {
      return false;
    }
  }

  // fde_count: typically udata4.
  if (cursor + 4 > hdr_end) return false;
  unsigned char fde_fmt = fde_count_enc & kEhPeFormatMask;
  if (fde_fmt != kEhPeUdata4) return false;
  std::uint32_t fde_count;
  memcpy(&fde_count, reinterpret_cast<const void *>(cursor), 4);
  cursor += 4;

  // table_enc must be datarel|sdata4 (0x3b) for the binary-search table format
  // that libunwind's dwarf_search_unwind_table accepts via UNW_INFO_FORMAT_REMOTE_TABLE.
  if (table_enc != (kEhPeDatarel | kEhPeSdata4)) return false;

  *out_fde_count = fde_count;
  *out_table     = cursor;
  return true;
}

int phdr_callback(struct dl_phdr_info *info, std::size_t, void *data) {
  auto *out = static_cast<std::vector<DsoInfo> *>(data);
  std::uintptr_t base = static_cast<std::uintptr_t>(info->dlpi_addr);

  DsoInfo dso{};
  dso.name             = info->dlpi_name ? info->dlpi_name : "";
  dso.text_start       = UINTPTR_MAX;
  dso.text_end         = 0;
  dso.eh_frame_hdr_addr = 0;
  dso.fde_count        = 0;
  dso.table_addr       = 0;

  std::uintptr_t eh_frame_hdr_end = 0;

  for (ElfW(Half) i = 0; i < info->dlpi_phnum; ++i) {
    const ElfW(Phdr) &ph = info->dlpi_phdr[i];
    if (ph.p_type == PT_LOAD) {
      LoadSegment seg;
      seg.vstart = base + ph.p_vaddr;
      seg.vend   = base + ph.p_vaddr + ph.p_memsz;
      dso.load_segments.push_back(seg);
      if (ph.p_flags & PF_X) {
        dso.text_start = std::min(dso.text_start, seg.vstart);
        dso.text_end   = std::max(dso.text_end,   seg.vend);
      }
    } else if (ph.p_type == PT_GNU_EH_FRAME) {
      dso.eh_frame_hdr_addr = base + ph.p_vaddr;
      eh_frame_hdr_end      = base + ph.p_vaddr + ph.p_memsz;
    }
  }

  if (dso.text_start == UINTPTR_MAX || dso.text_end == 0) return 0;
  if (dso.eh_frame_hdr_addr == 0) {
    // No unwind info advertised for this DSO; record load segments but mark FDE
    // unavailable so find_proc_info returns -UNW_ENOINFO.
    out->push_back(std::move(dso));
    return 0;
  }
  if (!decode_eh_frame_hdr(dso.eh_frame_hdr_addr, eh_frame_hdr_end,
                           &dso.fde_count, &dso.table_addr)) {
    dso.fde_count  = 0;
    dso.table_addr = 0;
  }
  out->push_back(std::move(dso));
  return 0;
}

// Remote unwind register cache. Holds the current cursor view of the
// callee-restored registers. Initial values come from the snapshot's ucontext.
struct RegCache {
  std::uint64_t r[32];  // indexed by libunwind regnum
  bool          valid[32];
};

struct UnwindArg {
  SnapshotFrame *frame;
  RegCache       regs;
};

int unw_to_greg(unw_regnum_t r) {
  switch (r) {
    case UNW_X86_64_RAX: return REG_RAX;
    case UNW_X86_64_RDX: return REG_RDX;
    case UNW_X86_64_RCX: return REG_RCX;
    case UNW_X86_64_RBX: return REG_RBX;
    case UNW_X86_64_RSI: return REG_RSI;
    case UNW_X86_64_RDI: return REG_RDI;
    case UNW_X86_64_RBP: return REG_RBP;
    case UNW_X86_64_RSP: return REG_RSP;
    case UNW_X86_64_R8:  return REG_R8;
    case UNW_X86_64_R9:  return REG_R9;
    case UNW_X86_64_R10: return REG_R10;
    case UNW_X86_64_R11: return REG_R11;
    case UNW_X86_64_R12: return REG_R12;
    case UNW_X86_64_R13: return REG_R13;
    case UNW_X86_64_R14: return REG_R14;
    case UNW_X86_64_R15: return REG_R15;
    case UNW_X86_64_RIP: return REG_RIP;
    default: return -1;
  }
}

int my_find_proc_info(unw_addr_space_t as, unw_word_t ip,
                      unw_proc_info_t *pi, int need_unwind_info, void *arg) {
  unw_dyn_info_t di;
  memset(&di, 0, sizeof(di));
  {
    std::lock_guard<std::mutex> g(cache().mu);
    const DsoInfo *dso = cache().find_by_ip(static_cast<std::uintptr_t>(ip));
    if (!dso || dso->fde_count == 0 || dso->table_addr == 0) return -UNW_ENOINFO;
    di.format            = UNW_INFO_FORMAT_REMOTE_TABLE;
    di.start_ip          = dso->text_start;
    di.end_ip            = dso->text_end;
    di.u.rti.name_ptr    = 0;  // informational only; avoid pointer into cache string
    di.u.rti.segbase     = dso->eh_frame_hdr_addr;
    di.u.rti.table_data  = dso->table_addr;
    di.u.rti.table_len   = (static_cast<unw_word_t>(dso->fde_count) * 8) / sizeof(unw_word_t);
  }
  // Lock released before recursing into dwarf_search_unwind_table; that call
  // will invoke my_access_mem which takes the same mutex.
  return _Ux86_64_dwarf_search_unwind_table(as, ip, &di, pi, need_unwind_info, arg);
}

void my_put_unwind_info(unw_addr_space_t, unw_proc_info_t *pi, void *) {
  if (pi->unwind_info) {
    free(pi->unwind_info);
    pi->unwind_info = nullptr;
  }
}

int my_get_dyn_info_list(unw_addr_space_t, unw_word_t *, void *) {
  return -UNW_ENOINFO;
}

int my_access_mem(unw_addr_space_t, unw_word_t addr, unw_word_t *valp,
                  int write, void *arg) {
  if (write) return -UNW_EINVAL;
  auto *u = static_cast<UnwindArg *>(arg);
  SnapshotFrame *f = u->frame;

  // Stack reads must come from the copy. Reads outside the window terminate
  // the trace because the worker may have reused that memory.
  if (addr >= f->copy_start && addr + sizeof(unw_word_t) <= f->copy_start + f->copy_len) {
    byte_copy(valp, f->buffer + (addr - f->copy_start), sizeof(unw_word_t));
    return 0;
  }

  // Code / .eh_frame / .eh_frame_hdr reads live in our own process address
  // space. Allow them as long as they fall inside a known PT_LOAD segment.
  bool readable;
  {
    std::lock_guard<std::mutex> g(cache().mu);
    readable = cache().address_readable(static_cast<std::uintptr_t>(addr), sizeof(unw_word_t));
  }
  if (readable) {
    memcpy(valp, reinterpret_cast<const void *>(addr), sizeof(unw_word_t));
    return 0;
  }
  return -UNW_EUNSPEC;
}

int my_access_reg(unw_addr_space_t, unw_regnum_t reg, unw_word_t *valp,
                  int write, void *arg) {
  if (reg < 0 || reg >= 32) return -UNW_EBADREG;
  auto *u = static_cast<UnwindArg *>(arg);
  if (write) {
    u->regs.r[reg]     = *valp;
    u->regs.valid[reg] = true;
    return 0;
  }
  if (!u->regs.valid[reg]) return -UNW_EBADREG;
  *valp = u->regs.r[reg];
  return 0;
}

int my_access_fpreg(unw_addr_space_t, unw_regnum_t, unw_fpreg_t *, int, void *) {
  return -UNW_EINVAL;
}

int my_resume(unw_addr_space_t, unw_cursor_t *, void *) {
  return -UNW_EINVAL;
}

int my_get_proc_name(unw_addr_space_t, unw_word_t, char *, std::size_t,
                     unw_word_t *, void *) {
  return -UNW_EINVAL;
}

unw_accessors_t make_accessors() {
  unw_accessors_t a;
  memset(&a, 0, sizeof(a));
  a.find_proc_info         = my_find_proc_info;
  a.put_unwind_info        = my_put_unwind_info;
  a.get_dyn_info_list_addr = my_get_dyn_info_list;
  a.access_mem             = my_access_mem;
  a.access_reg             = my_access_reg;
  a.access_fpreg           = my_access_fpreg;
  a.resume                 = my_resume;
  a.get_proc_name          = my_get_proc_name;
  return a;
}

void init_reg_cache(UnwindArg *u) {
  const greg_t *g = u->frame->ctx.uc_mcontext.gregs;
  for (int i = 0; i < 32; ++i) u->regs.valid[i] = false;
  auto set = [&](unw_regnum_t r, std::uint64_t v) {
    u->regs.r[r]     = v;
    u->regs.valid[r] = true;
  };
  set(UNW_X86_64_RAX, g[REG_RAX]);
  set(UNW_X86_64_RDX, g[REG_RDX]);
  set(UNW_X86_64_RCX, g[REG_RCX]);
  set(UNW_X86_64_RBX, g[REG_RBX]);
  set(UNW_X86_64_RSI, g[REG_RSI]);
  set(UNW_X86_64_RDI, g[REG_RDI]);
  set(UNW_X86_64_RBP, g[REG_RBP]);
  set(UNW_X86_64_RSP, g[REG_RSP]);
  set(UNW_X86_64_R8,  g[REG_R8]);
  set(UNW_X86_64_R9,  g[REG_R9]);
  set(UNW_X86_64_R10, g[REG_R10]);
  set(UNW_X86_64_R11, g[REG_R11]);
  set(UNW_X86_64_R12, g[REG_R12]);
  set(UNW_X86_64_R13, g[REG_R13]);
  set(UNW_X86_64_R14, g[REG_R14]);
  set(UNW_X86_64_R15, g[REG_R15]);
  set(UNW_X86_64_RIP, g[REG_RIP]);
}

}  // namespace

void rebuild_dso_cache() {
  std::vector<DsoInfo> built;
  dl_iterate_phdr(phdr_callback, &built);
  std::sort(built.begin(), built.end(),
            [](const DsoInfo &a, const DsoInfo &b) { return a.text_start < b.text_start; });
  std::lock_guard<std::mutex> g(cache().mu);
  cache().dsos = std::move(built);
}

UnwindResult remote_unwind(SnapshotFrame *frame, int max_frames) {
  UnwindResult out{};
  out.truncated = false;

  unw_accessors_t  accs = make_accessors();
  unw_addr_space_t as   = unw_create_addr_space(&accs, 0);
  if (!as) { out.truncated = true; return out; }

  UnwindArg arg;
  arg.frame = frame;
  init_reg_cache(&arg);

  unw_cursor_t cursor;
  if (unw_init_remote(&cursor, as, &arg) != 0) {
    unw_destroy_addr_space(as);
    out.truncated = true;
    return out;
  }

  int n = 0;
  do {
    unw_word_t ip = 0;
    if (unw_get_reg(&cursor, UNW_REG_IP, &ip) < 0) break;
    out.pcs.push_back(static_cast<std::uintptr_t>(ip));
    ++n;
    if (n >= max_frames) { out.truncated = true; break; }
    int rc = unw_step(&cursor);
    if (rc <= 0) {
      if (rc < 0) out.truncated = true;
      break;
    }
  } while (true);

  unw_destroy_addr_space(as);
  return out;
}

}  // namespace doris::stacktrace::internal
