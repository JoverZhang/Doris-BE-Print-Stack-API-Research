#include <dlfcn.h>
#include <libunwind.h>
#include <stdint.h>

#include <cxxabi.h>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>

namespace {

constexpr int kMaxFrames = 64;

struct Frame {
  Frame* parent;
  void* pc;
};

std::string demangle(const char* name) {
  if (!name) {
    return "";
  }
  int status = 0;
  char* out = abi::__cxa_demangle(name, nullptr, nullptr, &status);
  std::string result = (status == 0 && out) ? out : name;
  free(out);
  return result;
}

void print_symbol(const char* section, int index, void* pc) {
  Dl_info info;
  std::memset(&info, 0, sizeof(info));
  std::cout << section << "[" << index << "]=" << pc;
  if (dladdr(pc, &info)) {
    std::cout << " object=" << (info.dli_fname ? info.dli_fname : "")
              << " symbol=" << demangle(info.dli_sname);
  }
  std::cout << "\n";
}

int capture_with_frame_pointer(void** out, int max_depth) {
  Frame* frame = reinterpret_cast<Frame*>(__builtin_frame_address(0));
  int depth = 0;
  uintptr_t previous = reinterpret_cast<uintptr_t>(frame);
  while (frame && depth < max_depth) {
    uintptr_t current = reinterpret_cast<uintptr_t>(frame);
    if (current < 4096 || (current & 0xf) != 0) {
      break;
    }
    if (depth > 0 && current <= previous) {
      break;
    }
    out[depth++] = frame->pc;
    previous = current;
    Frame* next = frame->parent;
    if (reinterpret_cast<uintptr_t>(next) - current > (1u << 20)) {
      break;
    }
    frame = next;
  }
  return depth;
}

int capture_with_libunwind(void** out, int max_depth) {
  unw_context_t context;
  unw_cursor_t cursor;
  if (unw_getcontext(&context) < 0 || unw_init_local(&cursor, &context) < 0) {
    return 0;
  }
  int depth = 0;
  while (depth < max_depth && unw_step(&cursor) > 0) {
    unw_word_t ip = 0;
    if (unw_get_reg(&cursor, UNW_REG_IP, &ip) < 0) {
      break;
    }
    out[depth++] = reinterpret_cast<void*>(ip);
  }
  return depth;
}

__attribute__((noinline)) int leaf_capture() {
  void* fp_frames[kMaxFrames];
  void* unwind_frames[kMaxFrames];
  int fp_depth = capture_with_frame_pointer(fp_frames, kMaxFrames);
  int unwind_depth = capture_with_libunwind(unwind_frames, kMaxFrames);

  std::cout << "frame_pointer_depth=" << fp_depth << "\n";
  for (int i = 0; i < fp_depth; ++i) {
    print_symbol("frame_pointer_pc", i, fp_frames[i]);
  }

  std::cout << "libunwind_depth=" << unwind_depth << "\n";
  for (int i = 0; i < unwind_depth; ++i) {
    print_symbol("libunwind_pc", i, unwind_frames[i]);
  }
  return fp_depth + unwind_depth;
}

__attribute__((noinline)) int mid_capture() {
  return leaf_capture();
}

__attribute__((noinline)) int root_capture() {
  return mid_capture();
}

}  // namespace

int main() {
  int total = root_capture();
  std::cout << "total_depth=" << total << "\n";
  return total > 0 ? 0 : 1;
}
