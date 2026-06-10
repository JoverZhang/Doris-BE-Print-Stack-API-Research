#ifndef JEMALLOC_LLVM_UNW_BACKTRACE_H
#define JEMALLOC_LLVM_UNW_BACKTRACE_H
#include_next <libunwind.h>
int unw_backtrace(void **buffer, int size);
#endif
