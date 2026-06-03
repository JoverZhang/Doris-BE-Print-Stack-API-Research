#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cxxabi.h>
#include <dlfcn.h>
#include <getopt.h>
#include <memory>
#include <string>

#include "signal_harness.h"
#include "stack_walker.h"
#include "workload.h"

namespace {

std::string symbolize(void* pc) {
    Dl_info info;
    if (dladdr(pc, &info) != 0 && info.dli_sname != nullptr) {
        int status = 0;
        char* demangled =
            abi::__cxa_demangle(info.dli_sname, nullptr, nullptr, &status);
        std::string result = (status == 0 && demangled != nullptr)
                                 ? demangled
                                 : info.dli_sname;
        std::free(demangled);
        return result;
    }
    char buf[24];
    std::snprintf(buf, sizeof(buf), "??@%p", pc);
    return buf;
}

bool verify_sample(const msc::Sample& s) {
    int idx = 0;
    for (size_t i = 0; i < s.depth && idx < msc::workload::kExpectedCount; ++i) {
        std::string sym = symbolize(s.frames[i]);
        if (sym.find(msc::workload::kExpectedSubstrings[idx]) !=
            std::string::npos) {
            ++idx;
        }
    }
    return idx == msc::workload::kExpectedCount;
}

void print_trace(const msc::Sample& s) {
    for (size_t i = 0; i < s.depth; ++i) {
        std::printf("  #%-2zu %p  %s\n", i, s.frames[i],
                    symbolize(s.frames[i]).c_str());
    }
}

void usage(const char* argv0) {
    std::printf(
        "usage: %s [options]\n"
        "  --walker {fp|unwind}     walker implementation (default: fp)\n"
        "  --mode   {signal|direct} collection trigger (default: signal)\n"
        "  --iters  N               number of iterations (default: 100)\n"
        "  --verify                 verify each sample against expected chain\n"
        "  --print-trace            print the last collected trace\n"
        "  --help                   this message\n",
        argv0);
}

}  // namespace

int main(int argc, char** argv) {
    std::string walker_name = "fp";
    std::string mode_name = "signal";
    int iters = 100;
    bool verify_flag = false;
    bool print_trace_flag = false;

    static struct option opts[] = {
        {"walker", required_argument, nullptr, 'w'},
        {"mode", required_argument, nullptr, 'm'},
        {"iters", required_argument, nullptr, 'i'},
        {"verify", no_argument, nullptr, 'v'},
        {"print-trace", no_argument, nullptr, 'p'},
        {"help", no_argument, nullptr, 'h'},
        {nullptr, 0, nullptr, 0},
    };

    int c;
    while ((c = getopt_long(argc, argv, "", opts, nullptr)) != -1) {
        switch (c) {
            case 'w':
                walker_name = optarg;
                break;
            case 'm':
                mode_name = optarg;
                break;
            case 'i':
                iters = std::atoi(optarg);
                break;
            case 'v':
                verify_flag = true;
                break;
            case 'p':
                print_trace_flag = true;
                break;
            case 'h':
                usage(argv[0]);
                return 0;
            default:
                usage(argv[0]);
                return 2;
        }
    }

    std::unique_ptr<msc::IStackWalker> walker;
    if (walker_name == "fp") {
        walker = msc::make_fp_walker();
    } else if (walker_name == "unwind") {
        walker = msc::make_unwind_walker();
    } else {
        std::fprintf(stderr, "unknown walker: %s\n", walker_name.c_str());
        return 2;
    }

    msc::workload::Mode mode;
    if (mode_name == "signal") {
        mode = msc::workload::Mode::Signal;
    } else if (mode_name == "direct") {
        mode = msc::workload::Mode::Direct;
    } else {
        std::fprintf(stderr, "unknown mode: %s\n", mode_name.c_str());
        return 2;
    }

    msc::SignalHarness::install(walker.get());

    int empty = 0;
    int passed = 0;
    int wrong = 0;
    size_t depth_sum = 0;

    for (int i = 0; i < iters; ++i) {
        msc::workload::run_chain(mode);
        const msc::Sample& s = msc::SignalHarness::last_sample();
        depth_sum += s.depth;
        if (s.depth == 0) {
            ++empty;
        } else if (verify_flag && verify_sample(s)) {
            ++passed;
        } else if (verify_flag) {
            ++wrong;
        } else {
            ++passed;  // non-verify run: any non-empty trace counts as ok
        }
    }

    if (print_trace_flag) {
        std::printf("last trace:\n");
        print_trace(msc::SignalHarness::last_sample());
    }

    double avg_depth = iters > 0 ? static_cast<double>(depth_sum) / iters : 0.0;
    const char* result = (verify_flag ? (passed == iters ? "PASS" : "FAIL")
                                      : (empty == 0 ? "PASS" : "FAIL"));
    std::printf(
        "walker=%s mode=%s iters=%d depth_avg=%.1f empty=%d passed=%d "
        "wrong=%d result=%s\n",
        walker_name.c_str(), mode_name.c_str(), iters, avg_depth, empty,
        passed, wrong, result);

    return std::strcmp(result, "PASS") == 0 ? 0 : 1;
}
