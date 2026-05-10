#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <mutex>
#include <thread>
#include <vector>

#include <sys/syscall.h>
#include <unistd.h>

namespace {

std::atomic<bool> g_stop{false};
std::atomic<uint64_t> g_sink{0};
std::mutex g_print_mutex;

long tid() {
    return syscall(SYS_gettid);
}

void handle_signal(int) {
    g_stop.store(true, std::memory_order_relaxed);
}

__attribute__((noinline)) uint64_t target_leaf(uint64_t value) {
    for (int i = 0; i < 2048; ++i) {
        value = value * 6364136223846793005ULL + 1442695040888963407ULL;
        value ^= value >> 17;
    }
    return value;
}

__attribute__((noinline)) uint64_t target_level_three(uint64_t value) {
    return target_leaf(value + 3);
}

__attribute__((noinline)) uint64_t target_level_two(uint64_t value) {
    return target_level_three(value + 2);
}

__attribute__((noinline)) uint64_t target_level_one(uint64_t value) {
    return target_level_two(value + 1);
}

void cpu_worker(int id) {
    {
        std::lock_guard<std::mutex> lock(g_print_mutex);
        std::cout << "thread role=cpu id=" << id << " tid=" << tid() << std::endl;
    }
    uint64_t local = static_cast<uint64_t>(id + 1);
    while (!g_stop.load(std::memory_order_relaxed)) {
        local ^= target_level_one(local);
    }
    g_sink.fetch_add(local, std::memory_order_relaxed);
}

void sleep_worker(int id) {
    {
        std::lock_guard<std::mutex> lock(g_print_mutex);
        std::cout << "thread role=sleep id=" << id << " tid=" << tid() << std::endl;
    }
    while (!g_stop.load(std::memory_order_relaxed)) {
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
    }
}

} // namespace

int main() {
    std::signal(SIGTERM, handle_signal);
    std::signal(SIGINT, handle_signal);

    {
        std::lock_guard<std::mutex> lock(g_print_mutex);
        std::cout << "pid=" << getpid() << " main_tid=" << tid() << std::endl;
    }

    std::vector<std::thread> threads;
    threads.emplace_back(cpu_worker, 0);
    threads.emplace_back(cpu_worker, 1);
    threads.emplace_back(sleep_worker, 0);
    threads.emplace_back(sleep_worker, 1);

    while (!g_stop.load(std::memory_order_relaxed)) {
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
    }

    for (auto &thread : threads) {
        thread.join();
    }

    {
        std::lock_guard<std::mutex> lock(g_print_mutex);
        std::cout << "sink=" << g_sink.load(std::memory_order_relaxed) << std::endl;
    }
    return 0;
}
