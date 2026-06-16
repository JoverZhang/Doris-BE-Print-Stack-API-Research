#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <atomic>
#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <link.h>
#include <poll.h>
#include <thread>
#include <unistd.h>

#include <fcntl.h>
#include <sys/syscall.h>
#include <sys/types.h>

#define WRITE_LITERAL(message) (void)write(STDERR_FILENO, message, sizeof(message) - 1)

extern "C" int unw_backtrace(void** buffer, int size);

enum sync_event {
    S1_T1_IN_CALLBACK,
    S2_T2_READY,
    S4_T2_HANDLER_ENTERED,
    S7_T1_HANDLER_ENTERED,
    S8_RELEASE_T1_CALLBACK,
    S9_T1_HANDLER_RETURNED,
    S9_T1_OUTER_RETURNED,
    S9_T2_HANDLER_RETURNED,
    SYNC_EVENT_COUNT,
};

static int event_pipe[SYNC_EVENT_COUNT][2];
static int t1_signal;
static int t2_signal;
static std::atomic<pid_t> t1_tid{0};
static std::atomic<pid_t> t2_tid{0};

static pid_t current_tid() {
    return static_cast<pid_t>(syscall(SYS_gettid));
}

static void notify(sync_event event) {
    const char byte = 'x';
    (void)write(event_pipe[event][1], &byte, 1);
}

static void init_events() {
    for (int i = 0; i < SYNC_EVENT_COUNT; ++i) {
        if (pipe2(event_pipe[i], O_CLOEXEC) != 0) {
            perror("pipe2");
            exit(2);
        }
    }
}

static bool wait_event(sync_event event, const char* name, int timeout_ms = 2000) {
    pollfd fd {};
    fd.fd = event_pipe[event][0];
    fd.events = POLLIN;

    for (;;) {
        const int rc = poll(&fd, 1, timeout_ms);
        if (rc == 0) {
            std::fprintf(stderr, "wait: timed out waiting for %s\n", name);
            return false;
        }
        if (rc < 0 && errno == EINTR) {
            continue;
        }
        if (rc < 0) {
            std::fprintf(stderr, "poll(%s): %s\n", name, std::strerror(errno));
            return false;
        }

        char byte;
        if (read(event_pipe[event][0], &byte, 1) == 1) {
            return true;
        }
        if (errno != EINTR) {
            std::fprintf(stderr, "read(%s): %s\n", name, std::strerror(errno));
            return false;
        }
    }
}

static bool no_event(sync_event event, const char* name, int timeout_ms) {
    pollfd fd {};
    fd.fd = event_pipe[event][0];
    fd.events = POLLIN;

    const int rc = poll(&fd, 1, timeout_ms);
    if (rc == 0) {
        return true;
    }
    if (rc < 0) {
        std::fprintf(stderr, "poll(%s): %s\n", name, std::strerror(errno));
        return false;
    }

    char byte;
    (void)read(event_pipe[event][0], &byte, 1);
    std::fprintf(stderr, "wait: unexpected event while waiting for no %s\n", name);
    return false;
}

static bool send_signal(pid_t tid, int signal, const char* target) {
    if (syscall(SYS_tgkill, getpid(), tid, signal) != 0) {
        std::fprintf(stderr, "tgkill(%s): %s\n", target, std::strerror(errno));
        return false;
    }
    return true;
}

static void hold_on_deadlock_if_requested() {
    const char* value = std::getenv("HOLD_ON_DEADLOCK_SECONDS");
    const int seconds = value == nullptr ? 0 : std::atoi(value);
    if (seconds > 0) {
        std::fprintf(stderr, "debug: holding deadlocked process for %d seconds\n", seconds);
        sleep(static_cast<unsigned int>(seconds));
    }
}

static void call_unw_backtrace() {
    void* buffer[64];
    (void)unw_backtrace(buffer, 64);
}

static void t1_handler(int, siginfo_t*, void*) {
    // S7: t1 is interrupted before it can leave the callback.
    WRITE_LITERAL("S7 t1 handler: entered; calling unw_backtrace\n");
    notify(S7_T1_HANDLER_ENTERED);

    call_unw_backtrace();

    WRITE_LITERAL("unexpected: t1 handler unw_backtrace returned\n");
    notify(S9_T1_HANDLER_RETURNED);
}

static void t2_handler(int, siginfo_t*, void*) {
    // S4: t2 enters libunwind. It will hold libunwind's cache lock, then wait
    // for the loader lock held by t1.
    WRITE_LITERAL("S4 t2 handler: entered; calling unw_backtrace\n");
    notify(S4_T2_HANDLER_ENTERED);

    call_unw_backtrace();

    WRITE_LITERAL("unexpected: t2 handler unw_backtrace returned\n");
    notify(S9_T2_HANDLER_RETURNED);
}

static void install_handler(int signal, void (*handler)(int, siginfo_t*, void*)) {
    struct sigaction action {};
    action.sa_flags = SA_SIGINFO | SA_RESTART;
    action.sa_sigaction = handler;
    sigemptyset(&action.sa_mask);
    sigaddset(&action.sa_mask, signal);

    if (sigaction(signal, &action, nullptr) != 0) {
        perror("sigaction");
        exit(2);
    }
}

int main() {
    std::setvbuf(stderr, nullptr, _IONBF, 0);

    t1_signal = SIGRTMIN;
    t2_signal = SIGRTMIN + 1;
    if (t2_signal > SIGRTMAX) {
        WRITE_LITERAL("not enough realtime signals on this system\n");
        return 2;
    }

    init_events();
    install_handler(t1_signal, t1_handler);
    install_handler(t2_signal, t2_handler);

    // t1
    std::thread([]() {
        t1_tid.store(current_tid(), std::memory_order_release);

        dl_iterate_phdr([](struct dl_phdr_info*, size_t, void*) {
            // S1: t1 is inside dl_iterate_phdr's callback. glibc's loader lock is held.
            WRITE_LITERAL("S1 t1: inside dl_iterate_phdr callback; loader lock is held\n");
            notify(S1_T1_IN_CALLBACK);

            (void)wait_event(S8_RELEASE_T1_CALLBACK, "S8 release t1 callback", -1);

            WRITE_LITERAL("S8 t1: callback release flag observed; callback can return\n");
            return 1;
        }, nullptr);

        WRITE_LITERAL("unexpected: t1 outer dl_iterate_phdr returned\n");
        notify(S9_T1_OUTER_RETURNED);
    }).detach();

    // t2
    std::thread([]() {
        t2_tid.store(current_tid(), std::memory_order_release);

        // S2: t2 is ready. It does nothing until main sends the realtime signal.
        WRITE_LITERAL("S2 t2: waiting for realtime signal\n");
        notify(S2_T2_READY);

        for (;;) {
            pause();
        }
    }).detach();

    if (!wait_event(S1_T1_IN_CALLBACK, "S1 t1 callback") ||
        !wait_event(S2_T2_READY, "S2 t2 ready")) {
        return 2;
    }

    // S3: make t2 enter unw_backtrace while t1 still holds the loader lock.
    WRITE_LITERAL("S3 main: signal t2\n");
    // @see t2_handler()
    if (!send_signal(t2_tid.load(std::memory_order_acquire), t2_signal, "t2") ||
        !wait_event(S4_T2_HANDLER_ENTERED, "S4 t2 handler")) {
        return 2;
    }

    // S5: t2 has not returned, so it is blocked under unw_backtrace.
    if (!no_event(S9_T2_HANDLER_RETURNED, "t2 handler return", 200)) {
        WRITE_LITERAL("result: invalid test; t2 returned before t1 released the loader lock\n");
        return 1;
    }
    WRITE_LITERAL("S5 main: t2 did not return; it is blocked in unw_backtrace\n");

    // S6: interrupt t1 while t2 is blocked.
    WRITE_LITERAL("S6 main: signal t1 while t2 is blocked in unw_backtrace\n");
    if (!send_signal(t1_tid.load(std::memory_order_acquire), t1_signal, "t1") ||
        !wait_event(S7_T1_HANDLER_ENTERED, "S7 t1 handler")) {
        return 2;
    }

    // S8: release the callback flag. Deadlock means t1 still cannot return to
    // the callback, because it is stuck in the signal handler.
    WRITE_LITERAL("S8 main: release t1 callback flag\n");
    notify(S8_RELEASE_T1_CALLBACK);

    // S9: none of these should happen in the deadlock.
    const bool t1_handler_done = wait_event(S9_T1_HANDLER_RETURNED, "t1 handler return");
    const bool t1_outer_done = wait_event(S9_T1_OUTER_RETURNED, "t1 outer return");
    const bool t2_handler_done = wait_event(S9_T2_HANDLER_RETURNED, "t2 handler return");

    if (!t1_handler_done && !t1_outer_done && !t2_handler_done) {
        WRITE_LITERAL("S9 result: libunwind signal reentry deadlock reproduced\n");
        hold_on_deadlock_if_requested();
        return 124;
    }

    WRITE_LITERAL("result: deadlock not reproduced; at least one blocked path returned\n");
    return 1;
}
