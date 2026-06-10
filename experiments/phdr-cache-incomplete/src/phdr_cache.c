#define _GNU_SOURCE

#include "phdr_cache.h"

#include <dlfcn.h>
#include <elf.h>
#include <link.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef int (*real_dl_iterate_phdr_t)(int (*callback)(struct dl_phdr_info *, size_t, void *),
                                      void *);

struct cached_phdr {
    struct dl_phdr_info info;
    char *name;
};

static real_dl_iterate_phdr_t real_dl_iterate_phdr;
static struct cached_phdr *entries;
static size_t entry_count;
static size_t entry_cap;
static int cache_active;
static int filter_omit_main;
static const char *filter_omit_substring;

static real_dl_iterate_phdr_t get_real_dl_iterate_phdr(void) {
    if (real_dl_iterate_phdr == NULL) {
        real_dl_iterate_phdr =
                (real_dl_iterate_phdr_t)dlsym(RTLD_NEXT, "dl_iterate_phdr");
        if (real_dl_iterate_phdr == NULL) {
            fprintf(stderr, "real dl_iterate_phdr not found\n");
            abort();
        }
    }
    return real_dl_iterate_phdr;
}

static int should_skip(const struct dl_phdr_info *info) {
    const char *name = info->dlpi_name == NULL ? "" : info->dlpi_name;

    if (filter_omit_main && name[0] == '\0') {
        return 1;
    }
    if (filter_omit_substring != NULL && strstr(name, filter_omit_substring) != NULL) {
        return 1;
    }
    return 0;
}

static void clear_entries(void) {
    for (size_t i = 0; i < entry_count; ++i) {
        free(entries[i].name);
    }
    free(entries);
    entries = NULL;
    entry_count = 0;
    entry_cap = 0;
}

static int reserve_one(void) {
    if (entry_count < entry_cap) {
        return 0;
    }

    size_t next_cap = entry_cap == 0 ? 32 : entry_cap * 2;
    struct cached_phdr *next = realloc(entries, next_cap * sizeof(*entries));
    if (next == NULL) {
        return -1;
    }
    entries = next;
    entry_cap = next_cap;
    return 0;
}

static int collect_callback(struct dl_phdr_info *info, size_t size, void *data) {
    (void)size;
    (void)data;

    if (should_skip(info)) {
        return 0;
    }
    if (reserve_one() != 0) {
        return 1;
    }

    struct cached_phdr *entry = &entries[entry_count++];
    entry->info = *info;
    const char *name = info->dlpi_name == NULL ? "" : info->dlpi_name;
    entry->name = strdup(name);
    if (entry->name == NULL) {
        return 1;
    }
    entry->info.dlpi_name = entry->name;
    return 0;
}

void phdr_cache_clear_filters(void) {
    filter_omit_main = 0;
    filter_omit_substring = NULL;
}

void phdr_cache_omit_main(int enabled) {
    filter_omit_main = enabled;
}

void phdr_cache_omit_substring(const char *needle) {
    filter_omit_substring = needle;
}

int phdr_cache_update(void) {
    cache_active = 0;
    clear_entries();

    int rc = get_real_dl_iterate_phdr()(collect_callback, NULL);
    if (rc != 0) {
        clear_entries();
        return rc;
    }

    cache_active = 1;
    return 0;
}

int phdr_cache_poison_substring(const char *needle) {
    int changed = 0;

    for (size_t i = 0; i < entry_count; ++i) {
        const char *name = entries[i].info.dlpi_name == NULL ? "" : entries[i].info.dlpi_name;
        if (strstr(name, needle) != NULL) {
            entries[i].info.dlpi_phdr = (const ElfW(Phdr) *)0x1;
            ++changed;
        }
    }
    return changed;
}

void phdr_cache_dump(FILE *out) {
    fprintf(out, "CACHE\tactive=%d\tentries=%zu\n", cache_active, entry_count);
    for (size_t i = 0; i < entry_count; ++i) {
        const struct dl_phdr_info *info = &entries[i].info;
        fprintf(out, "CACHE\t%zu\tbase=0x%lx\tphdr=%p\tphnum=%u\tname=%s\n", i,
                (unsigned long)info->dlpi_addr, (const void *)info->dlpi_phdr,
                (unsigned)info->dlpi_phnum,
                info->dlpi_name == NULL || info->dlpi_name[0] == '\0' ? "<main>"
                                                                       : info->dlpi_name);
    }
}

int dl_iterate_phdr(int (*callback)(struct dl_phdr_info *info, size_t size, void *data),
                    void *data) {
    if (!cache_active) {
        return get_real_dl_iterate_phdr()(callback, data);
    }

    int result = 0;
    for (size_t i = 0; i < entry_count; ++i) {
        result = callback(&entries[i].info, offsetof(struct dl_phdr_info, dlpi_adds), data);
        if (result != 0) {
            break;
        }
    }
    return result;
}
