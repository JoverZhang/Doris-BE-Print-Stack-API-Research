#define _GNU_SOURCE

#include <dlfcn.h>
#include <link.h>
#include <stddef.h>
#include <unistd.h>

typedef int (*real_dl_iterate_phdr_t)(
        int (*callback)(struct dl_phdr_info *, size_t, void *), void *);

static real_dl_iterate_phdr_t real_dl_iterate_phdr;

static void log_line(const char *msg) {
    const char *p = msg;

    while (*p != '\0') {
        ++p;
    }
    (void)write(STDERR_FILENO, msg, (size_t)(p - msg));
}

int dl_iterate_phdr(
        int (*callback)(struct dl_phdr_info *, size_t, void *), void *data) {
    if (real_dl_iterate_phdr == NULL) {
        log_line("phdr_wrap: resolving dl_iterate_phdr with dlsym\n");
        real_dl_iterate_phdr = (real_dl_iterate_phdr_t)dlsym(
                RTLD_NEXT, "dl_iterate_phdr");
        if (real_dl_iterate_phdr == NULL) {
            log_line("phdr_wrap: dlsym returned NULL\n");
            return -1;
        }
        log_line("phdr_wrap: resolved dl_iterate_phdr\n");
    }

    return real_dl_iterate_phdr(callback, data);
}
