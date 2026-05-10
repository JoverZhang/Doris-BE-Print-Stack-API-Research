#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <sys/syscall.h>
#include <unistd.h>

namespace {

std::atomic<bool> g_stop{false};
std::atomic<uint64_t> g_sink{0};
std::mutex g_block_mutex;
std::mutex g_print_mutex;

long tid() {
    return syscall(SYS_gettid);
}

void print_role(const char *role, int id) {
    std::lock_guard<std::mutex> lock(g_print_mutex);
    std::cout << "thread role=" << role << " id=" << id
              << " tid=" << tid() << std::endl;
}

__attribute__((noinline)) uint64_t target_leaf(uint64_t seed) {
    double x = static_cast<double>(seed % 2048) + 0.125;
    for (int i = 0; i < 256; ++i) {
        x = std::sin(x) + std::cos(x * 0.25) + std::sqrt(x + 8.0);
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL +
               static_cast<uint64_t>(x);
    }
    return seed ^ static_cast<uint64_t>(x * 1000000.0);
}

__attribute__((noinline)) uint64_t target_level_three(uint64_t seed) {
    return target_leaf(seed + 3);
}

__attribute__((noinline)) uint64_t target_level_two(uint64_t seed) {
    return target_level_three(seed + 2);
}

__attribute__((noinline)) uint64_t target_level_one(uint64_t seed) {
    return target_level_two(seed + 1);
}

void cpu_worker(int id) {
    print_role("cpu", id);
    uint64_t local = static_cast<uint64_t>(id + 1);
    while (!g_stop.load(std::memory_order_relaxed)) {
        local ^= target_level_one(local + static_cast<uint64_t>(id));
    }
    g_sink.fetch_add(local, std::memory_order_relaxed);
}

void sleep_worker(int id) {
    print_role("sleep", id);
    while (!g_stop.load(std::memory_order_relaxed)) {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
}

void mutex_block_worker(int id) {
    print_role("mutex_blocked", id);
    std::unique_lock<std::mutex> lock(g_block_mutex);
    if (!g_stop.load(std::memory_order_relaxed)) {
        g_sink.fetch_add(static_cast<uint64_t>(id), std::memory_order_relaxed);
    }
}

int parse_int_arg(char **argv, int argc, const std::string &name, int fallback) {
    for (int i = 1; i + 1 < argc; ++i) {
        if (argv[i] == name) {
            return std::atoi(argv[i + 1]);
        }
    }
    return fallback;
}

}  // namespace

int main(int argc, char **argv) {
    const int cpu_threads = parse_int_arg(argv, argc, "--cpu-threads", 2);
    const int sleep_threads = parse_int_arg(argv, argc, "--sleep-threads", 2);
    const int blocked_threads = parse_int_arg(argv, argc, "--blocked-threads", 2);
    const int seconds = parse_int_arg(argv, argc, "--seconds", 8);

    std::cout << "pid=" << getpid()
              << " main_tid=" << tid()
              << " cpu_threads=" << cpu_threads
              << " sleep_threads=" << sleep_threads
              << " blocked_threads=" << blocked_threads
              << " seconds=" << seconds << std::endl;

    std::vector<std::thread> threads;
    threads.reserve(static_cast<size_t>(cpu_threads + sleep_threads + blocked_threads));

    g_block_mutex.lock();
    for (int i = 0; i < cpu_threads; ++i) {
        threads.emplace_back(cpu_worker, i);
    }
    for (int i = 0; i < sleep_threads; ++i) {
        threads.emplace_back(sleep_worker, i);
    }
    for (int i = 0; i < blocked_threads; ++i) {
        threads.emplace_back(mutex_block_worker, i);
    }

    std::this_thread::sleep_for(std::chrono::seconds(seconds));
    g_stop.store(true, std::memory_order_relaxed);
    g_block_mutex.unlock();
    for (auto &thread : threads) {
        thread.join();
    }
    std::cout << "sink=" << g_sink.load(std::memory_order_relaxed) << std::endl;
    return 0;
}
