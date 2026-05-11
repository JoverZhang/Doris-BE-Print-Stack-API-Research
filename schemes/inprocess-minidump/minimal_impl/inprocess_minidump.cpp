#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <dlfcn.h>
#include <libunwind.h>
#include <pthread.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <ucontext.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <thread>

#if !defined(__x86_64__)
#error "inprocess-minidump minimal implementation is Linux x86_64 only"
#endif

static_assert(sizeof(uintptr_t) == 8, "x86_64 snapshot records require 64-bit pointers");

namespace
{
constexpr int kWorkerCount = 2;
constexpr int kCaptureSignal = SIGURG;
constexpr size_t kStackCopyBytes = 64 * 1024;
constexpr int kAckTimeoutMs = 1000;
constexpr int kMaxFrames = 64;

struct Ack
{
    int index;
    uint64_t sequence;
    int status;
    size_t copied_len;
};

struct RegisterSnapshot
{
    uintptr_t rax = 0;
    uintptr_t rdx = 0;
    uintptr_t rcx = 0;
    uintptr_t rbx = 0;
    uintptr_t rsi = 0;
    uintptr_t rdi = 0;
    uintptr_t rbp = 0;
    uintptr_t rsp = 0;
    uintptr_t r8 = 0;
    uintptr_t r9 = 0;
    uintptr_t r10 = 0;
    uintptr_t r11 = 0;
    uintptr_t r12 = 0;
    uintptr_t r13 = 0;
    uintptr_t r14 = 0;
    uintptr_t r15 = 0;
    uintptr_t rip = 0;
};

struct CaptureSlot
{
    std::atomic<int> registered{0};
    std::atomic<int> captured{0};
    std::atomic<uint64_t> request_sequence{0};
    std::atomic<uint64_t> captured_sequence{0};
    std::atomic<int> capture_status{0};

    int index = -1;
    pid_t tid = -1;
    char name[16] = {};

    uintptr_t stack_low = 0;
    uintptr_t stack_high = 0;

    RegisterSnapshot regs;
    ucontext_t context {};
    uintptr_t copied_start = 0;
    size_t copied_len = 0;
    int truncated = 0;

    unsigned char stack[kStackCopyBytes] = {};
};

struct WorkerSnapshot
{
    int index = -1;
    pid_t tid = -1;
    char name[16] = {};
    uint64_t sequence = 0;
    int capture_status = 0;
    int ack_status = 0;
    uintptr_t stack_low = 0;
    uintptr_t stack_high = 0;
    RegisterSnapshot regs;
    ucontext_t context {};
    uintptr_t copied_start = 0;
    size_t copied_len = 0;
    int truncated = 0;
    unsigned char stack[kStackCopyBytes] = {};
};

static int g_ack_pipe[2] = {-1, -1};
static int g_release_pipe[kWorkerCount][2] = {{-1, -1}, {-1, -1}};
static std::atomic<bool> g_stop{false};
static CaptureSlot g_slots[kWorkerCount];

static void byte_copy(void * dst, const void * src, size_t n)
{
    auto * d = static_cast<unsigned char *>(dst);
    auto * s = static_cast<const unsigned char *>(src);
    for (size_t i = 0; i < n; ++i)
        d[i] = s[i];
}

static pid_t gettid_syscall()
{
    return static_cast<pid_t>(syscall(SYS_gettid));
}

static int rt_tgsigqueueinfo(pid_t tgid, pid_t tid, int sig, siginfo_t * si)
{
    return static_cast<int>(syscall(SYS_rt_tgsigqueueinfo, tgid, tid, sig, si));
}

static void set_thread_name(const char * name)
{
    prctl(PR_SET_NAME, name, 0, 0, 0);
}

static uintptr_t greg(const ucontext_t * uc, int reg)
{
    return static_cast<uintptr_t>(uc->uc_mcontext.gregs[reg]);
}

static RegisterSnapshot registers_from_ucontext(const ucontext_t * uc)
{
    RegisterSnapshot regs;
    regs.rax = greg(uc, REG_RAX);
    regs.rdx = greg(uc, REG_RDX);
    regs.rcx = greg(uc, REG_RCX);
    regs.rbx = greg(uc, REG_RBX);
    regs.rsi = greg(uc, REG_RSI);
    regs.rdi = greg(uc, REG_RDI);
    regs.rbp = greg(uc, REG_RBP);
    regs.rsp = greg(uc, REG_RSP);
    regs.r8 = greg(uc, REG_R8);
    regs.r9 = greg(uc, REG_R9);
    regs.r10 = greg(uc, REG_R10);
    regs.r11 = greg(uc, REG_R11);
    regs.r12 = greg(uc, REG_R12);
    regs.r13 = greg(uc, REG_R13);
    regs.r14 = greg(uc, REG_R14);
    regs.r15 = greg(uc, REG_R15);
    regs.rip = greg(uc, REG_RIP);
    return regs;
}

static int wait_readable(int fd, int timeout_ms)
{
    pollfd pfd{fd, POLLIN, 0};
    int rc = poll(&pfd, 1, timeout_ms);
    return rc > 0 ? 0 : -1;
}

static void drain_ack_pipe()
{
    Ack ack {};
    while (wait_readable(g_ack_pipe[0], 0) == 0)
    {
        ssize_t n = read(g_ack_pipe[0], &ack, sizeof(ack));
        if (n != static_cast<ssize_t>(sizeof(ack)))
            break;
    }
}

static void capture_handler(int sig, siginfo_t * si, void * ctx)
{
    if (sig != kCaptureSignal || si == nullptr || ctx == nullptr)
        return;

    auto * slot = reinterpret_cast<CaptureSlot *>(si->si_value.sival_ptr);
    if (slot == nullptr || slot->registered.load(std::memory_order_acquire) != 1)
        return;

    auto * uc = reinterpret_cast<ucontext_t *>(ctx);
    uint64_t sequence = slot->request_sequence.load(std::memory_order_acquire);

    slot->captured.store(0, std::memory_order_relaxed);
    byte_copy(&slot->context, uc, sizeof(slot->context));
    slot->regs = registers_from_ucontext(uc);
    slot->copied_start = 0;
    slot->copied_len = 0;
    slot->truncated = 0;

    int status = 1;
    uintptr_t start = slot->regs.rsp;
    uintptr_t end = slot->stack_high;
    if (slot->stack_low == 0 || slot->stack_high <= slot->stack_low || start < slot->stack_low || start > slot->stack_high)
    {
        status = -2;
    }
    else
    {
        size_t n = static_cast<size_t>(end - start);
        if (n > kStackCopyBytes)
        {
            n = kStackCopyBytes;
            slot->truncated = 1;
        }

        slot->copied_start = start;
        slot->copied_len = n;
        byte_copy(slot->stack, reinterpret_cast<const void *>(start), n);
    }

    slot->capture_status.store(status, std::memory_order_release);
    slot->captured_sequence.store(sequence, std::memory_order_release);
    slot->captured.store(1, std::memory_order_release);

    Ack ack{slot->index, sequence, status, slot->copied_len};
    (void)!write(g_ack_pipe[1], &ack, sizeof(ack));

    char release = 0;
    while (read(g_release_pipe[slot->index][0], &release, sizeof(release)) < 0)
    {
    }
}

static void install_capture_handler()
{
    struct sigaction sa {};
    sa.sa_flags = SA_SIGINFO;
    sa.sa_sigaction = capture_handler;
    sigemptyset(&sa.sa_mask);
    if (sigaction(kCaptureSignal, &sa, nullptr) != 0)
    {
        perror("sigaction");
        exit(1);
    }
}

static void register_worker_thread(int index, const char * name)
{
    CaptureSlot & slot = g_slots[index];
    slot.index = index;
    slot.tid = gettid_syscall();
    snprintf(slot.name, sizeof(slot.name), "%s", name);

    pthread_attr_t attr;
    if (pthread_getattr_np(pthread_self(), &attr) == 0)
    {
        void * stack_addr = nullptr;
        size_t stack_size = 0;
        if (pthread_attr_getstack(&attr, &stack_addr, &stack_size) == 0)
        {
            slot.stack_low = reinterpret_cast<uintptr_t>(stack_addr);
            slot.stack_high = slot.stack_low + stack_size;
        }
        pthread_attr_destroy(&attr);
    }

    slot.registered.store(1, std::memory_order_release);
}

static void copy_slot_to_snapshot(const CaptureSlot & slot, WorkerSnapshot * snapshot)
{
    snapshot->index = slot.index;
    snapshot->tid = slot.tid;
    byte_copy(snapshot->name, slot.name, sizeof(snapshot->name));
    snapshot->sequence = slot.captured_sequence.load(std::memory_order_acquire);
    snapshot->capture_status = slot.capture_status.load(std::memory_order_acquire);
    snapshot->stack_low = slot.stack_low;
    snapshot->stack_high = slot.stack_high;
    snapshot->regs = slot.regs;
    snapshot->context = slot.context;
    snapshot->copied_start = slot.copied_start;
    snapshot->copied_len = slot.copied_len;
    snapshot->truncated = slot.truncated;
    byte_copy(snapshot->stack, slot.stack, slot.copied_len);
}

static bool capture_worker(CaptureSlot & slot, uint64_t sequence, WorkerSnapshot * snapshot)
{
    slot.captured.store(0, std::memory_order_release);
    slot.request_sequence.store(sequence, std::memory_order_release);

    siginfo_t si {};
    si.si_code = SI_QUEUE;
    si.si_value.sival_ptr = &slot;

    if (rt_tgsigqueueinfo(getpid(), slot.tid, kCaptureSignal, &si) != 0)
    {
        snapshot->ack_status = -10;
        return false;
    }

    bool matched_ack = false;
    Ack ack {};
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(kAckTimeoutMs);
    while (std::chrono::steady_clock::now() < deadline)
    {
        if (wait_readable(g_ack_pipe[0], 20) != 0)
            continue;
        ssize_t n = read(g_ack_pipe[0], &ack, sizeof(ack));
        if (n != static_cast<ssize_t>(sizeof(ack)))
            continue;
        if (ack.index == slot.index && ack.sequence == sequence)
        {
            matched_ack = true;
            break;
        }
    }

    copy_slot_to_snapshot(slot, snapshot);
    snapshot->ack_status = matched_ack ? ack.status : -11;
    return matched_ack && slot.captured.load(std::memory_order_acquire) == 1 && snapshot->capture_status == 1;
}

static void release_worker(int index)
{
    char release = 1;
    (void)!write(g_release_pipe[index][1], &release, sizeof(release));
}

static void print_symbol(unw_cursor_t * cursor, unw_word_t ip)
{
    char name[256] = {};
    unw_word_t offset = 0;
    if (unw_get_proc_name(cursor, name, sizeof(name), &offset) == 0)
    {
        printf("%s+0x%lx", name, static_cast<unsigned long>(offset));
        return;
    }

    Dl_info info {};
    if (dladdr(reinterpret_cast<void *>(static_cast<uintptr_t>(ip)), &info) && info.dli_sname)
    {
        printf("%s+0x%lx", info.dli_sname, static_cast<unsigned long>(ip - reinterpret_cast<uintptr_t>(info.dli_saddr)));
        return;
    }
    printf("?");
}

static int unwind_snapshot(const WorkerSnapshot & snapshot)
{
    unw_cursor_t cursor;
    ucontext_t context = snapshot.context;
    int rc = unw_init_local2(&cursor, &context, UNW_INIT_SIGNAL_FRAME);
    if (rc < 0)
    {
        printf("unwind_status=FAIL reason=unw_init_local2 rc=%d\n", rc);
        return 0;
    }

    int frames = 0;
    printf("unwind_status=START source=saved_ucontext_worker_parked copied_stack_available=yes\n");
    for (; frames < kMaxFrames; ++frames)
    {
        unw_word_t ip = 0;
        unw_word_t sp = 0;
        unw_get_reg(&cursor, UNW_REG_IP, &ip);
        unw_get_reg(&cursor, UNW_REG_SP, &sp);
        if (ip == 0)
            break;

        printf("  #%02d ip=0x%lx sp=0x%lx symbol=", frames, static_cast<unsigned long>(ip), static_cast<unsigned long>(sp));
        print_symbol(&cursor, ip);
        printf("\n");

        rc = unw_step(&cursor);
        if (rc <= 0)
            break;
    }

    printf("unwind_status=%s frames=%d final_rc=%d\n", frames > 0 ? "OK" : "FAIL", frames, rc);
    return frames;
}

static void print_snapshot(const WorkerSnapshot & snapshot)
{
    printf("\n=== inprocess-minidump snapshot ===\n");
    printf("slot=%d tid=%ld name=%s sequence=%lu ack_status=%d capture_status=%d\n",
        snapshot.index,
        static_cast<long>(snapshot.tid),
        snapshot.name,
        static_cast<unsigned long>(snapshot.sequence),
        snapshot.ack_status,
        snapshot.capture_status);
    printf("registers rip=0x%lx rsp=0x%lx rbp=0x%lx\n",
        static_cast<unsigned long>(snapshot.regs.rip),
        static_cast<unsigned long>(snapshot.regs.rsp),
        static_cast<unsigned long>(snapshot.regs.rbp));
    printf("stack_bounds=[0x%lx,0x%lx) copied=[0x%lx,+%zu] truncated=%d\n",
        static_cast<unsigned long>(snapshot.stack_low),
        static_cast<unsigned long>(snapshot.stack_high),
        static_cast<unsigned long>(snapshot.copied_start),
        snapshot.copied_len,
        snapshot.truncated);
    unwind_snapshot(snapshot);
}

__attribute__((noinline)) static uint64_t deep_leaf(uint64_t x)
{
    volatile uint64_t y = x;
    for (int i = 0; i < 100000; ++i)
        y = y * 1103515245ULL + 12345ULL;
    return y;
}

__attribute__((noinline)) static uint64_t deep_recursive(int depth, uint64_t x)
{
    if (depth <= 0)
        return deep_leaf(x);
    uint64_t y = deep_recursive(depth - 1, x + static_cast<uint64_t>(depth));
    return y ^ (x + static_cast<uint64_t>(depth * 17));
}

static void worker_thread_main(int index)
{
    char name[16];
    snprintf(name, sizeof(name), "worker-%d", index);
    set_thread_name(name);
    register_worker_thread(index, name);

    volatile uint64_t x = static_cast<uint64_t>(index + 1);
    while (!g_stop.load(std::memory_order_relaxed))
    {
        x = deep_recursive(24, x);
        if ((x & 0xfffff) == 0)
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
}
} // namespace

int main()
{
    static_assert(std::atomic<int>::is_always_lock_free, "signal handler uses lock-free atomic<int>");
    static_assert(std::atomic<uint64_t>::is_always_lock_free, "signal handler uses lock-free atomic<uint64_t>");
    set_thread_name("normal");

    if (pipe(g_ack_pipe) != 0)
    {
        perror("pipe");
        return 1;
    }
    for (int i = 0; i < kWorkerCount; ++i)
    {
        if (pipe(g_release_pipe[i]) != 0)
        {
            perror("pipe release");
            return 1;
        }
    }

    install_capture_handler();

    std::thread worker0(worker_thread_main, 0);
    std::thread worker1(worker_thread_main, 1);

    while (true)
    {
        bool all_registered = true;
        for (int i = 0; i < kWorkerCount; ++i)
            all_registered = all_registered && g_slots[i].registered.load(std::memory_order_acquire) == 1;
        if (all_registered)
            break;
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }

    printf("scheme=inprocess-minidump\n");
    printf("arch=x86_64\n");
    printf("compile_frame_pointer_flag=default_no_fno_omit_frame_pointer\n");
    printf("normal_tid=%ld pid=%d worker_count=%d stack_copy_bytes=%zu\n",
        static_cast<long>(gettid_syscall()),
        getpid(),
        kWorkerCount,
        kStackCopyBytes);

    drain_ack_pipe();
    uint64_t sequence = 1;
    WorkerSnapshot snapshots[kWorkerCount];
    for (int i = 0; i < kWorkerCount; ++i)
    {
        bool ok = capture_worker(g_slots[i], sequence, &snapshots[i]);
        printf("capture_result slot=%d ok=%s\n", i, ok ? "yes" : "no");
    }

    for (int i = 0; i < kWorkerCount; ++i)
    {
        print_snapshot(snapshots[i]);
        release_worker(i);
    }

    g_stop.store(true, std::memory_order_release);
    worker0.join();
    worker1.join();

    close(g_ack_pipe[0]);
    close(g_ack_pipe[1]);
    for (int i = 0; i < kWorkerCount; ++i)
    {
        close(g_release_pipe[i][0]);
        close(g_release_pipe[i][1]);
    }
    return 0;
}
