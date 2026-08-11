#ifndef BERTH_PTY_SPAWN_H
#define BERTH_PTY_SPAWN_H

#include <sys/types.h>

/// fork + login_tty + execve 起 PTY 子进程(C 实现,child 段只做 async-signal-safe 调用)。
///
/// 为什么不用 posix_spawn:POSIX_SPAWN_SETSID + file actions 打开 slave 拿不到
/// 控制终端(实测 tcgetpgrp 失败)—— zsh 降级为无作业控制,fish 直接启动退出。
/// 控制终端只能由子进程自己 setsid 后 ioctl(TIOCSCTTY) 获得(login_tty 一步到位)。
///
/// 为什么敢 fork:多线程进程 fork 的死锁来自 child 里碰 malloc/objc/swift 运行时;
/// 本函数 child 段只调 sigprocmask/signal/open/login_tty/chdir/close/execve,
/// 全部在 async-signal-safe 白名单内,参数由调用方在 fork 前备好。
/// 这与 Terminal.app / node-pty / kitty 的做法一致。
///
/// 窗口尺寸(rows/cols)也在 child 里设:macOS 上 slave 打开之前对 master 调
/// TIOCSWINSZ 会 ENOTTY 失败(实测 errno=25),shell 于是以 0×0 启动、退回内置
/// 默认 80×24 折行。child 段 login_tty 之后 fd 0 就是控制终端,这时设才生效。
///
/// 返回 fork 的 pid(父进程视角);-1 = fork 失败。子进程 exec 失败以 127 退出,
/// slave 打开/login_tty 失败以 126 退出。
pid_t berth_pty_spawn(const char *executable,
                      char *const argv[],
                      char *const envp[],
                      const char *slave_path,
                      const char *working_dir,
                      unsigned short rows,
                      unsigned short cols);

#endif
