#include <cerrno>
#include <cctype>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <iostream>
#include <sstream>
#include <string>
#include <sys/ptrace.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

#include <libunwind-ptrace.h>
#include <libunwind.h>

namespace {

std::vector<pid_t> list_tasks(pid_t pid) {
    std::vector<pid_t> tids;
    std::ostringstream path;
    path << "/proc/" << pid << "/task";
    DIR *dir = opendir(path.str().c_str());
    if (!dir) {
        std::perror("opendir task");
        return tids;
    }

    while (dirent *entry = readdir(dir)) {
        const char *name = entry->d_name;
        bool numeric = *name != '\0';
        for (const char *p = name; *p; ++p) {
            numeric = numeric && std::isdigit(static_cast<unsigned char>(*p));
        }
        if (numeric) {
            tids.push_back(static_cast<pid_t>(std::strtol(name, nullptr, 10)));
        }
    }

    closedir(dir);
    return tids;
}

void attach_and_unwind(pid_t tid) {
    if (ptrace(PTRACE_ATTACH, tid, nullptr, nullptr) != 0) {
        std::cout << "thread=" << tid << " status=attach_failed errno=" << errno << "\n";
        return;
    }

    int status = 0;
    if (waitpid(tid, &status, __WALL) < 0) {
        std::cout << "thread=" << tid << " status=wait_failed errno=" << errno << "\n";
        ptrace(PTRACE_DETACH, tid, nullptr, nullptr);
        return;
    }

    unw_addr_space_t address_space = unw_create_addr_space(&_UPT_accessors, 0);
    void *upt = _UPT_create(tid);
    unw_cursor_t cursor;
    int init_status = unw_init_remote(&cursor, address_space, upt);

    std::cout << "thread=" << tid << " status=attached init=" << init_status << "\n";
    if (init_status == 0) {
        for (int frame = 0; frame < 16; ++frame) {
            unw_word_t ip = 0;
            int reg_status = unw_get_reg(&cursor, UNW_REG_IP, &ip);
            if (reg_status != 0 || ip == 0) {
                break;
            }
            std::cout << "thread=" << tid << " frame=" << frame << " ip=0x"
                      << std::hex << static_cast<unsigned long long>(ip) << std::dec << "\n";
            int step_status = unw_step(&cursor);
            if (step_status <= 0) {
                break;
            }
        }
    }

    _UPT_destroy(upt);
    unw_destroy_addr_space(address_space);
    ptrace(PTRACE_DETACH, tid, nullptr, nullptr);
}

} // namespace

int main(int argc, char **argv) {
    if (argc != 2) {
        std::cerr << "usage: " << argv[0] << " <target-program>\n";
        return 2;
    }

    pid_t child = fork();
    if (child < 0) {
        std::perror("fork");
        return 1;
    }

    if (child == 0) {
        execl(argv[1], argv[1], nullptr);
        std::perror("execl");
        _exit(127);
    }

    sleep(1);

    std::cout << "command=ptrace_remote_unwind <target-program>\n";
    std::cout << "target_pid=" << child << "\n";
    std::cout << "target_threads_begin\n";
    for (pid_t tid : list_tasks(child)) {
        std::cout << "target_tid=" << tid << "\n";
    }
    std::cout << "target_threads_end\n";
    std::cout << "remote_unwind_begin\n";
    for (pid_t tid : list_tasks(child)) {
        attach_and_unwind(tid);
    }
    std::cout << "remote_unwind_end\n";

    kill(child, SIGTERM);
    waitpid(child, nullptr, 0);
    return 0;
}
