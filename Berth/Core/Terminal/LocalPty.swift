import Darwin
import Dispatch
import Foundation
import SwiftTerm

/// 本地 PTY 宿主:posix_openpt + C 层 fork/login_tty/execve(BerthPtySpawn.c)。
///
/// 不用 SwiftTerm LocalProcess 的 forkpty:它 fork 后还在子进程里跑 Swift 运行时
/// 代码,多线程 GUI 进程里会死锁在 malloc/dyld 锁上,表现为「重启恢复的本地 Shell
/// 有回显没提示符」(回显是内核行规程给的,shell 根本没活到 exec)。
/// 也不用 posix_spawn:SETSID + file actions 打开 slave 拿不到控制终端(实测
/// tcgetpgrp 失败),zsh 降级为无作业控制,fish 直接启动退出(issue #10)。
/// 正解是 C 函数里 fork,child 段只做 async-signal-safe 调用,login_tty 一步
/// 完成 setsid + TIOCSCTTY + dup2 —— 与 Terminal.app / node-pty 同款。
/// onData / whenExited 回调统一投递主线程。
final class LocalPty: @unchecked Sendable {
    enum SpawnError: Error {
        case pty(Int32)
        case spawn(Int32)
    }

    private(set) var masterFD: Int32 = -1
    private(set) var pid: pid_t = 0
    /// 子进程仍在运行(主线程读写)
    private(set) var running = false
    /// 子进程退出码(WEXITSTATUS;信号终止时为 nil),诊断秒退用
    private(set) var exitStatus: Int32?
    /// spawn 时刻,判定「启动即退」
    let spawnedAt = Date()

    /// PTY 输出(主线程回调)
    var onData: (@MainActor ([UInt8]) -> Void)?

    private var io: DispatchIO?
    private var monitor: DispatchSourceProcess?
    private var exited = false
    private var exitHandler: (@MainActor () -> Void)?
    private let readQueue = DispatchQueue(label: "berth.localpty.read")
    /// 最近一次请求的窗口尺寸(readQueue 上读写)。fork 后到 child login_tty 前这段
    /// 窗口期,父进程对 master 的 TIOCSWINSZ 要么 ENOTTY 失败要么被 child 的
    /// 初始化 ioctl 盖掉 —— 首次收到输出(child 必然已挂上 slave)时重放一次兜底。
    private var lastRequestedSize: (cols: Int, rows: Int)?
    private var replayedInitialSize = false

    init(
        executable: String,
        execName: String,
        environment: [String],
        directory: String,
        cols: Int,
        rows: Int
    ) throws {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0,
              let slaveCString = ptsname(master) else {
            if master >= 0 { close(master) }
            throw SpawnError.pty(errno)
        }
        let slavePath = String(cString: slaveCString)

        // 初始窗口尺寸交给 child 设:slave 打开之前对 master 调 TIOCSWINSZ 在 macOS 上
        // 必然 ENOTTY 失败,shell 会以 0×0 启动(zsh 退回 80×24),表现为折行列数不对。
        // fork 前把 child 需要的一切备成 C 内存,child 段零分配
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(execName), nil]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer {
            argv.compactMap { $0 }.forEach { free($0) }
            envp.compactMap { $0 }.forEach { free($0) }
        }

        let child = berth_pty_spawn(
            executable, &argv, &envp, slavePath, directory,
            UInt16(max(0, rows)), UInt16(max(0, cols))
        )
        guard child > 0 else {
            close(master)
            throw SpawnError.spawn(errno)
        }

        pid = child
        masterFD = master
        running = true
        startReading(fd: master)
        startMonitor()
    }

    deinit {
        monitor?.cancel()
        io?.close()
    }

    // MARK: - I/O

    func send(_ bytes: [UInt8]) {
        guard running, masterFD >= 0 else { return }
        let fd = masterFD
        bytes.withUnsafeBytes { ptr in
            let data = DispatchData(bytes: ptr)
            DispatchIO.write(toFileDescriptor: fd, data: data, runningHandlerOn: readQueue) { _, _ in }
        }
    }

    func resize(cols: Int, rows: Int) {
        guard masterFD >= 0 else { return }
        readQueue.async { [self] in lastRequestedSize = (cols, rows) }
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: masterFD, windowSize: &size)
    }

    /// SIGTERM;退出事件由 monitor 正常送达(不像 LocalProcess.terminate 会掐掉监视器)
    func terminate() {
        guard pid > 0 else { return }
        kill(pid, SIGTERM)
    }

    /// 注册退出回调(主线程);进程已先一步退出则立即补发
    @MainActor
    func whenExited(_ handler: @escaping @MainActor () -> Void) {
        if exited { handler() } else { exitHandler = handler }
    }

    // MARK: - 内部

    private func startReading(fd: Int32) {
        let channel = DispatchIO(type: .stream, fileDescriptor: fd, queue: readQueue) { _ in
            close(fd)
        }
        channel.setLimit(lowWater: 1)
        io = channel
        armRead(channel)
    }

    private func armRead(_ channel: DispatchIO) {
        channel.read(offset: 0, length: 128 * 1024, queue: readQueue) { [weak self] done, data, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                // 首次输出 = child 必然已 login_tty:重放窗口期可能丢失/被盖的尺寸
                if !self.replayedInitialSize {
                    self.replayedInitialSize = true
                    if let size = self.lastRequestedSize, self.masterFD >= 0 {
                        var ws = winsize(ws_row: UInt16(size.rows), ws_col: UInt16(size.cols), ws_xpixel: 0, ws_ypixel: 0)
                        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: self.masterFD, windowSize: &ws)
                    }
                }
                let bytes = [UInt8](data)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.onData?(bytes) }
                }
            }
            guard done else { return }
            if error == 0, let data, !data.isEmpty {
                self.armRead(channel)   // 一次读满,续读
            }
            // EOF / 错误:停止读环;退出统一由 monitor 送达
        }
    }

    private func startMonitor() {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in self?.processExited() }
        source.activate()
        monitor = source
        // 竞态兜底:进程可能在监视器挂上之前就退出(exit 事件不会补发)
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid {
            DispatchQueue.main.async { [weak self] in self?.processExited() }
        }
    }

    /// 主队列回调:置状态、收尸、通知(幂等)
    private func processExited() {
        guard !exited else { return }
        exited = true
        running = false
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid, (status & 0x7F) == 0 {
            exitStatus = (status >> 8) & 0xFF  // WEXITSTATUS
        }
        monitor?.cancel()
        monitor = nil
        io?.close()
        io = nil
        masterFD = -1
        MainActor.assumeIsolated {
            exitHandler?()
            exitHandler = nil
        }
    }
}
