#define _GNU_SOURCE

#include "phdr_cache.h"

#include <dlfcn.h>
#include <libgen.h>
#include <libunwind.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef int (*plugin_entry_t)(const char *label);

static const int kMaxFrames = 64;

static const char *safe_str(const char *value) {
    return value == NULL || value[0] == '\0' ? "-" : value;
}

static void plugin_path(char *buf, size_t size, const char *name) {
    const char *dir = getenv("PHDR_PLUGIN_DIR");
    if (dir == NULL || dir[0] == '\0') {
        dir = ".build/out";
    }
    snprintf(buf, size, "%s/%s", dir, name);
}

static void *load_plugin(const char *soname) {
    char path[1024];
    plugin_path(path, sizeof(path), soname);

    fprintf(stderr, "LOAD\t%s\n", path);
    void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) {
        fprintf(stderr, "dlopen failed: %s\n", dlerror());
        exit(2);
    }
    return handle;
}

static plugin_entry_t find_entry(void *handle, const char *name) {
    dlerror();
    void *sym = dlsym(handle, name);
    const char *error = dlerror();
    if (error != NULL) {
        fprintf(stderr, "dlsym failed for %s: %s\n", name, error);
        exit(2);
    }
    return (plugin_entry_t)sym;
}

__attribute__((noinline, visibility("default"))) int capture_stack(const char *label) {
    unw_context_t context;
    unw_cursor_t cursor;

    printf("BEGIN\t%s\n", label);
    int rc = unw_getcontext(&context);
    if (rc != 0) {
        printf("INIT_ERROR\tunw_getcontext\t%d\n", rc);
        fflush(stdout);
        return rc;
    }

    rc = unw_init_local(&cursor, &context);
    if (rc != 0) {
        printf("INIT_ERROR\tunw_init_local\t%d\n", rc);
        fflush(stdout);
        return rc;
    }

    for (int i = 0; i < kMaxFrames; ++i) {
        unw_word_t ip = 0;
        unw_word_t off = 0;
        char symbol[256];
        Dl_info dli;

        int reg_rc = unw_get_reg(&cursor, UNW_REG_IP, &ip);
        if (reg_rc != 0 || ip == 0) {
            printf("REG_ERROR\t%d\t%d\t0x%lx\n", i, reg_rc, (unsigned long)ip);
            fflush(stdout);
            return reg_rc == 0 ? -1 : reg_rc;
        }

        symbol[0] = '\0';
        int name_rc = unw_get_proc_name(&cursor, symbol, sizeof(symbol), &off);
        memset(&dli, 0, sizeof(dli));
        dladdr((void *)(uintptr_t)ip, &dli);

        printf("FRAME\t%d\t0x%lx\t%s\t%s\t%d\t0x%lx\n", i, (unsigned long)ip,
               safe_str(dli.dli_fname), name_rc == 0 ? symbol : "<unknown>", name_rc,
               (unsigned long)off);
        fflush(stdout);

        int step_rc = unw_step(&cursor);
        printf("STEP\t%d\t%d\n", i, step_rc);
        fflush(stdout);
        if (step_rc <= 0) {
            printf("STOP\t%d\n", step_rc);
            fflush(stdout);
            return 0;
        }
    }

    printf("STOP\tframe-limit\n");
    fflush(stdout);
    return 0;
}

static int call_plugin(void *handle, const char *entry_name, const char *label) {
    plugin_entry_t entry = find_entry(handle, entry_name);
    fprintf(stderr, "CALL\t%s\t%s\n", entry_name, label);
    return entry(label);
}

static int run_complete(void) {
    void *plugin = load_plugin("libplugin_a.so");
    if (phdr_cache_update() != 0) {
        fprintf(stderr, "phdr_cache_update failed\n");
        return 2;
    }
    phdr_cache_dump(stderr);
    return call_plugin(plugin, "plugin_a_entry", "complete");
}

static int run_missing_plugin(void) {
    phdr_cache_omit_substring("libplugin_a.so");
    if (phdr_cache_update() != 0) {
        fprintf(stderr, "phdr_cache_update failed\n");
        return 2;
    }
    phdr_cache_clear_filters();
    phdr_cache_dump(stderr);

    void *plugin = load_plugin("libplugin_a.so");
    return call_plugin(plugin, "plugin_a_entry", "missing-plugin");
}

static int run_stale_dlclose(void) {
    void *plugin_a = load_plugin("libplugin_a.so");
    if (phdr_cache_update() != 0) {
        fprintf(stderr, "phdr_cache_update failed\n");
        return 2;
    }
    phdr_cache_dump(stderr);

    fprintf(stderr, "DLCLOSE\tlibplugin_a.so\n");
    dlclose(plugin_a);

    void *plugin_b = load_plugin("libplugin_b.so");
    return call_plugin(plugin_b, "plugin_b_entry", "stale-dlclose");
}

static int run_poison_plugin(void) {
    void *plugin = load_plugin("libplugin_a.so");
    if (phdr_cache_update() != 0) {
        fprintf(stderr, "phdr_cache_update failed\n");
        return 2;
    }
    int changed = phdr_cache_poison_substring("libplugin_a.so");
    fprintf(stderr, "POISON\tlibplugin_a.so\tchanged=%d\n", changed);
    phdr_cache_dump(stderr);
    return call_plugin(plugin, "plugin_a_entry", "poison-plugin");
}

static int run_missing_main(void) {
    void *plugin = load_plugin("libplugin_a.so");
    phdr_cache_omit_main(1);
    if (phdr_cache_update() != 0) {
        fprintf(stderr, "phdr_cache_update failed\n");
        return 2;
    }
    phdr_cache_clear_filters();
    phdr_cache_dump(stderr);
    return call_plugin(plugin, "plugin_a_entry", "missing-main");
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <complete|missing-plugin|stale-dlclose|poison-plugin|missing-main>\n",
                basename(argv[0]));
        return 2;
    }

    const char *scenario = argv[1];
    fprintf(stderr, "SCENARIO\t%s\n", scenario);

    if (strcmp(scenario, "complete") == 0) {
        return run_complete();
    }
    if (strcmp(scenario, "missing-plugin") == 0) {
        return run_missing_plugin();
    }
    if (strcmp(scenario, "stale-dlclose") == 0) {
        return run_stale_dlclose();
    }
    if (strcmp(scenario, "poison-plugin") == 0) {
        return run_poison_plugin();
    }
    if (strcmp(scenario, "missing-main") == 0) {
        return run_missing_main();
    }

    fprintf(stderr, "unknown scenario: %s\n", scenario);
    return 2;
}
