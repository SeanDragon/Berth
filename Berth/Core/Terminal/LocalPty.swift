import Darwin
import Dispatch
import Foundation
import SwiftTerm

/// 本地 PTY 宿主:posix_openpt + posix_spawn。
///
/// 不用 SwiftTerm LocalProcess 的 forkpty:多线程进程里 fork 出的子进程可能死锁在
/// malloc/dyld 锁上(fork 只复制调用线程,其他线程持有的锁永远不会释放),表现为
/// 「重启恢复的本地 Shell 有回显没提示符」—— 回显是内核行规程给的,zsh 根本没活到
/// exec。app 启动恢复标签正是线程最繁忙的时刻,命中率极高;posix_spawn 在内核里
/// 完成 spawn,是多线程进程唯一安全的路径。
///
/// 控制终端:子进程 POSIX_SPAWN_SETSID 成为会话首领后,file actions 按路径 open
/// slave 端(无 O_NOCTTY),内核自动将其设为控制终端,shell 拿到完整作业控制。
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

    /// PTY 输出(主线程回调)
    var onData: (@MainActor ([UInt8]) -> Void)?

    private var io: DispatchIO?
    private var monitor: DispatchSourceProcess?
    private var exited = false
    private var exitHandler: (@MainActor () -> Void)?
    private let readQueue = DispatchQueue(label: "berth.localpty.read")

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
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: master, windowSize: &size)

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_addopen(&fileActions, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&fileActions, 0, 1)
        posix_spawn_file_actions_adddup2(&fileActions, 0, 2)
        posix_spawn_file_actions_addclose(&fileActions, master)
        posix_spawn_file_actions_addchdir_np(&fileActions, directory)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(execName), nil]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer {
            argv.compactMap { $0 }.forEach { free($0) }
            envp.compactMap { $0 }.forEach { free($0) }
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attr)
        }

        var child: pid_t = 0
        let rc = posix_spawn(&child, executable, &fileActions, &attr, &argv, &envp)
        guard rc == 0 else {
            close(master)
            throw SpawnError.spawn(rc)
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
        waitpid(pid, &status, WNOHANG)
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
