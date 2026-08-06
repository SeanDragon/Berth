#include "BerthPtySpawn.h"

#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <util.h>

pid_t berth_pty_spawn(const char *executable,
                      char *const argv[],
                      char *const envp[],
                      const char *slave_path,
                      const char *working_dir)
{
    pid_t pid = fork();
    if (pid != 0) {
        return pid; /* 父进程(或 fork 失败 -1) */
    }

    /* ---- child:此处起只允许 async-signal-safe 调用 ---- */

    /* 信号环境归零:GUI app 的掩码/忽略处置不能带给 shell */
    sigset_t empty;
    sigemptyset(&empty);
    sigprocmask(SIG_SETMASK, &empty, NULL);
    for (int sig = 1; sig < NSIG; sig++) {
        signal(sig, SIG_DFL);
    }

    int fd = open(slave_path, O_RDWR);
    if (fd < 0) {
        _exit(126);
    }
    /* setsid + TIOCSCTTY + dup2 到 0/1/2(+关闭原 fd):shell 拿到完整作业控制 */
    if (login_tty(fd) < 0) {
        _exit(126);
    }

    if (working_dir != NULL) {
        (void)chdir(working_dir);
    }

    /* 收掉继承的杂项 fd(master、DispatchIO、kqueue 等),0/1/2 保留 */
    for (int i = 3; i < 256; i++) {
        close(i);
    }

    execve(executable, argv, envp);
    _exit(127);
}
