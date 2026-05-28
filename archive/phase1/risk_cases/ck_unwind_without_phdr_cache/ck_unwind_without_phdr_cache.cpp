#include <dlfcn.h>
#include <libunwind.h>
#include <link.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <vector>

#ifndef RISK_USE_PHDR_CACHE
#define RISK_USE_PHDR_CACHE 0
#endif

namespace
{
using DLIteratePHDR = int (*)(int (*)(dl_phdr_info *, size_t, void *), void *);

pthread_mutex_t fake_loader_lock = PTHREAD_MUTEX_INITIALIZER;
volatile sig_atomic_t fake_loader_lock_held = 0;
volatile sig_atomic_t handler_entered = 0;
volatile sig_atomic_t handler_completed = 0;
volatile sig_atomic_t wrapper_calls = 0;
volatile sig_atomic_t slow_path_calls = 0;
volatile sig_atomic_t cache_path_calls = 0;
volatile sig_atomic_t reentered_while_lock_held = 0;
volatile sig_atomic_t captured_frames = 0;

std::vector<dl_phdr_info> * phdr_cache = nullptr;
volatile sig_atomic_t phdr_cache_ready = 0;

template <size_t N>
void write_literal(const char (& text)[N])
{
    (void)!write(STDOUT_FILENO, text, N - 1);
}

void write_number(const char * key, long value)
{
    char buf[128];
    int n = snprintf(buf, sizeof(buf), "%s=%ld\n", key, value);
    if (n > 0)
        (void)!write(STDOUT_FILENO, buf, static_cast<size_t>(n));
}

DLIteratePHDR real_dl_iterate_phdr()
{
    static DLIteratePHDR fn = reinterpret_cast<DLIteratePHDR>(dlsym(RTLD_NEXT, "dl_iterate_phdr"));
    if (!fn)
    {
        write_literal("status=ERROR\nreason=dlsym_RTLD_NEXT_dl_iterate_phdr_failed\n");
        _exit(97);
    }
    return fn;
}

int collect_phdr(dl_phdr_info * info, size_t, void * data)
{
    auto * cache = reinterpret_cast<std::vector<dl_phdr_info> *>(data);
    cache->push_back(*info);
    return 0;
}

void update_phdr_cache_like_clickhouse()
{
    auto * cache = new std::vector<dl_phdr_info>();
    real_dl_iterate_phdr()(collect_phdr, cache);
    phdr_cache = cache;
    phdr_cache_ready = 1;
}

void signal_handler(int, siginfo_t *, void *)
{
    handler_entered = 1;
    write_literal("handler_entered=yes\n");

    void * frames[64];
    int n = unw_backtrace(frames, 64);
    if (n > 0)
        captured_frames = n;

    handler_completed = 1;
    write_literal("handler_completed=yes\n");
}

void install_handlers()
{
    struct sigaction sa {};
    sa.sa_sigaction = signal_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_SIGINFO;
    if (sigaction(SIGUSR1, &sa, nullptr) != 0)
    {
        perror("sigaction(SIGUSR1)");
        exit(2);
    }

}
} // namespace

extern "C" int dl_iterate_phdr(int (* callback)(dl_phdr_info *, size_t, void *), void * data)
{
    ++wrapper_calls;

#if RISK_USE_PHDR_CACHE
    if (phdr_cache_ready && phdr_cache)
    {
        ++cache_path_calls;
        for (auto info : *phdr_cache)
        {
            int ret = callback(&info, sizeof(info), data);
            if (ret != 0)
                return ret;
        }
        return 0;
    }
#endif

    ++slow_path_calls;
    if (fake_loader_lock_held)
    {
        ++reentered_while_lock_held;
        write_literal("dl_iterate_phdr_reentered_while_lock_held=yes\n");
    }

    pthread_mutex_lock(&fake_loader_lock);
    int ret = real_dl_iterate_phdr()(callback, data);
    pthread_mutex_unlock(&fake_loader_lock);
    return ret;
}

int main()
{
    setvbuf(stdout, nullptr, _IONBF, 0);

#if RISK_USE_PHDR_CACHE
    puts("case=safe_with_phdr_cache");
    update_phdr_cache_like_clickhouse();
    puts("phdr_cache_ready=yes");
#else
    puts("case=unsafe_no_phdr_cache");
    puts("phdr_cache_ready=no");
#endif

    install_handlers();

    puts("trigger=raise_SIGUSR1_while_fake_loader_lock_is_held");
    pthread_mutex_lock(&fake_loader_lock);
    fake_loader_lock_held = 1;
    raise(SIGUSR1);
    fake_loader_lock_held = 0;
    pthread_mutex_unlock(&fake_loader_lock);

#if RISK_USE_PHDR_CACHE
    if (handler_completed && cache_path_calls > 0 && reentered_while_lock_held == 0)
    {
        puts("status=PASS");
        puts("reason=handler_unwind_completed_through_cache_backed_dl_iterate_phdr");
    }
    else
    {
        puts("status=FAIL");
        puts("reason=expected_handler_to_complete_through_phdr_cache");
    }
#else
    if (!handler_completed && reentered_while_lock_held > 0)
    {
        puts("status=EXPECTED_TIMEOUT");
        puts("reason=handler_unwind_reentered_slow_dl_iterate_phdr_while_loader_lock_was_held");
    }
    else
    {
        puts("status=FAIL");
        puts("reason=unsafe_case_did_not_reproduce_reentry_timeout");
    }
#endif

    printf("handler_entered=%d\n", handler_entered);
    printf("handler_completed=%d\n", handler_completed);
    printf("wrapper_calls=%d\n", wrapper_calls);
    printf("slow_path_calls=%d\n", slow_path_calls);
    printf("cache_path_calls=%d\n", cache_path_calls);
    printf("reentered_while_lock_held=%d\n", reentered_while_lock_held);
    printf("captured_frames=%d\n", captured_frames);

#if RISK_USE_PHDR_CACHE
    return handler_completed && cache_path_calls > 0 ? 0 : 1;
#else
    return !handler_completed && reentered_while_lock_held > 0 ? 0 : 1;
#endif
}
