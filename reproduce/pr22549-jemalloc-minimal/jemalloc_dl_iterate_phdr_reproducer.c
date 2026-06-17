#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <dlfcn.h>
#include <jemalloc/jemalloc.h>
#include <link.h>
#include <stddef.h>
#include <unistd.h>
#include <unwind.h>

#define WRITE_LITERAL(message) (void)write(STDERR_FILENO, message, sizeof(message) - 1)

// Adapted from Doris be/src/runtime/memory/jemalloc_hook.cpp.
void* doris_malloc(size_t size) {
    return jemalloc(size);
}

void doris_free(void* ptr) {
    jefree(ptr);
}

void* doris_realloc(void* ptr, size_t size) {
    return jerealloc(ptr, size);
}

void* doris_calloc(size_t count, size_t size) {
    return jecalloc(count, size);
}

#define ALIAS(doris_fn) __attribute__((alias(#doris_fn), used))
void* malloc(size_t size) ALIAS(doris_malloc);
void free(void* ptr) ALIAS(doris_free);
void* realloc(void* ptr, size_t size) ALIAS(doris_realloc);
void* calloc(size_t count, size_t size) ALIAS(doris_calloc);

// Keep the proof independent of the host libgcc implementation.
static int unwind_phdr_callback(struct dl_phdr_info* info, size_t size, void* data) {
    (void)info;
    (void)size;
    (void)data;
    return 0;
}

_Unwind_Reason_Code _Unwind_Backtrace(_Unwind_Trace_Fn trace, void* trace_argument) {
    (void)trace;
    (void)trace_argument;
    WRITE_LITERAL("shim: _Unwind_Backtrace entered\n");
    dl_iterate_phdr(unwind_phdr_callback, NULL);
    WRITE_LITERAL("shim: _Unwind_Backtrace returned\n");
    return _URC_END_OF_STACK;
}

_Unwind_Ptr _Unwind_GetIP(struct _Unwind_Context* context) {
    (void)context;
    return 0;
}

// Adapted from Doris be/src/common/phdr_cache.cpp.
typedef int (*DLIterateFunction)(int (*callback)(struct dl_phdr_info* info, size_t size, void* data),
                                 void* data);

__attribute__((noinline)) static DLIterateFunction getOriginalDLIteratePHDR(void) {
    void* func = dlsym(RTLD_NEXT, "dl_iterate_phdr");
    if (func == NULL) {
        WRITE_LITERAL("error: dlsym(RTLD_NEXT, \"dl_iterate_phdr\") failed\n");
        _exit(2);
    }
    return (DLIterateFunction)func;
}

__attribute__((visibility("default"))) __attribute__((noinline)) int
dl_iterate_phdr(int (*callback)(struct dl_phdr_info* info, size_t size, void* data), void* data) {
    return getOriginalDLIteratePHDR()(callback, data);
}

__attribute__((constructor)) static void trigger_jemalloc_before_main(void) {
    WRITE_LITERAL("constructor: malloc before main\n");
    void* ptr = malloc(24);
    if (ptr == NULL) {
        WRITE_LITERAL("error: malloc returned null\n");
        _exit(2);
    }
    WRITE_LITERAL("constructor: malloc returned\n");
}

int main(void) {
    WRITE_LITERAL("main: reached\n");
    return 0;
}
