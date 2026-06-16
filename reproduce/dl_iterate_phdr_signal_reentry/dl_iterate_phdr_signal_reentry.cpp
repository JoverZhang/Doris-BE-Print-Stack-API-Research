#define _GNU_SOURCE

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <link.h>
#include <thread>
#include <unistd.h>

#include <sys/syscall.h>
#include <sys/types.h>

#define WRITE_LITERAL(message) (void)write(STDERR_FILENO, message, sizeof(message) - 1)

static int realtime_signal = 0;
static std::atomic_bool t1_ready{false};
static std::atomic<pid_t> t2_tid{0};

static pid_t current_tid() {
    return static_cast<pid_t>(syscall(SYS_gettid));
}

static void install_signal_handler() {
    struct sigaction action {};

    action.sa_flags = SA_SIGINFO;
    action.sa_sigaction = [](int, siginfo_t*, void*) {
        WRITE_LITERAL("t2 handler: calling nested `dl_iterate_phdr`\n");

        dl_iterate_phdr([](struct dl_phdr_info*, size_t, void*) -> int {
            WRITE_LITERAL("unexpected: nested callback was reached\n");
            _exit(1);
        }, nullptr);

        WRITE_LITERAL("unexpected: nested `dl_iterate_phdr` returned\n");
        _exit(1);
    };

    sigemptyset(&action.sa_mask);
    sigaddset(&action.sa_mask, realtime_signal);

    if (sigaction(realtime_signal, &action, nullptr) != 0) {
        perror("sigaction");
        exit(2);
    }
}

int main() {
    realtime_signal = SIGRTMIN;
    install_signal_handler();

    // Goal: keep `t1` inside a `dl_iterate_phdr` callback, then interrupt `t2`
    // with a realtime signal whose handler re-enters `dl_iterate_phdr`.
    std::thread([]() {
        dl_iterate_phdr([](struct dl_phdr_info*, size_t, void*) -> int {
            // Hold the loader lock while `t2` tries to enter nested `dl_iterate_phdr`.
            WRITE_LITERAL("t1: stopped inside outer `dl_iterate_phdr` callback\n");
            t1_ready.store(true, std::memory_order_release);

            for (;;)
                std::this_thread::yield();
        }, nullptr);
    }).detach();

    std::thread([]() {
        t2_tid.store(current_tid(), std::memory_order_release);
        WRITE_LITERAL("t2: waiting for realtime signal\n");

        for (;;)
            pause();
    }).detach();

    while (!t1_ready.load(std::memory_order_acquire) ||
           t2_tid.load(std::memory_order_acquire) == 0)
        std::this_thread::yield();

    WRITE_LITERAL("main: sending realtime signal to t2\n");
    if (syscall(SYS_tgkill, getpid(), t2_tid.load(std::memory_order_acquire), realtime_signal) != 0) {
        perror("tgkill");
        return 2;
    }

    std::this_thread::sleep_for(std::chrono::seconds(3));
    WRITE_LITERAL("result: nested `dl_iterate_phdr` did not return; deadlock reproduced\n");
    return 124;
}
