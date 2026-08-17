import AppKit
import Citadel
import Foundation
import NIOCore

/// SFTP 文件浏览:复用会话 SSHClient 打开 SFTP,维护当前目录与条目,提供上传/下载/增删改。
@MainActor
@Observable
final class SFTPBrowser {

    struct Entry: Identifiable, Sendable {
        let id = UUID()
        let name: String
        let isDirectory: Bool
        let isSymlink: Bool
        let size: UInt64
        let modified: Date?
        var permissions: UInt32 = 0
        /// 权限低 9 位(rwxrwxrwx)
        var mode: UInt32 { permissions & 0o777 }
    }

    /// 目录下载扫描时使用的轻量条目,与 Citadel 类型解耦,便于覆盖递归与符号链接边界。
    struct DownloadTreeEntry: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case directory, file, symlink }
        let name: String
        let kind: Kind
        let size: UInt64
    }

    struct DownloadTreeFile: Equatable, Sendable {
        let remotePath: String
        let relativeComponents: [String]
        let size: UInt64
    }

    struct DirectoryDownloadPlan: Equatable, Sendable {
        var directories: [[String]] = []
        var files: [DownloadTreeFile] = []
        var totalBytes: UInt64 = 0
        var skippedSymlinks = 0
    }

    /// 目录上传扫描时使用的轻量条目(issue #17),与下载侧对称,便于覆盖递归与符号链接边界
    struct UploadTreeEntry: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case directory, file, symlink }
        let name: String
        let kind: Kind
        let size: UInt64
    }

    struct UploadTreeFile: Equatable, Sendable {
        let localURL: URL
        let relativeComponents: [String]
        let size: UInt64
    }

    struct DirectoryUploadPlan: Equatable, Sendable {
        var directories: [[String]] = []
        var files: [UploadTreeFile] = []
        var totalBytes: UInt64 = 0
        var skippedSymlinks = 0
    }

    enum State: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    /// 一次进行中的传输。并发传输(如连拖两个文件下载)各持独立条目,
    /// 互不覆盖标签/进度,先完成的只清自己,不会把别人的进度条带走。
    struct ActiveTransfer: Identifiable, Equatable {
        let id: UUID
        var label: String
        /// 0...1;nil 表示不确定(扫描中/体积未知)
        var progress: Double?
    }

    private(set) var state: State = .idle
    private(set) var path = "/"
    /// 登录 home,供路径输入的 ~ 展开
    private(set) var homePath = "/"
    private(set) var entries: [Entry] = []
    /// 进行中的传输,按开始顺序排列;空表示空闲
    private(set) var transfers: [ActiveTransfer] = []

    private var sftp: SFTPClient?
    private let opener: () async throws -> SFTPClient
    /// 打开后首先落在哪个目录(取该 pane 终端的当前目录);nil 或列不出来时回落 home
    private let initialPath: String?
    /// 面板已关闭:打开中(await opener)被关时,迟到的 client 要立即关掉,不能泄漏子通道
    private var isClosed = false

    init(initialPath: String? = nil, opener: @escaping () async throws -> SFTPClient) {
        self.initialPath = initialPath
        self.opener = opener
    }

    /// 打开 SFTP 并列出 home 目录。子通道打开可能被服务器无响应地挂住
    /// (sshd 未启用 SFTP 子系统 / MaxSessions 限制),15s 看门狗置失败态可重试。
    func start() async {
        guard sftp == nil, state != .loading else { return }
        state = .loading
        let opening = Task { try await self.opener() }
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, self.state == .loading, self.sftp == nil else { return }
            opening.cancel()
            self.state = .failed(String(localized: "打开 SFTP 超时:服务器可能未启用 SFTP 子系统或已达会话上限,点刷新重试。"))
            // 迟到的 client 直接关掉,不能泄漏子通道
            Task.detached { if let late = try? await opening.value { try? await late.close() } }
        }
        do {
            let client = try await opening.value
            watchdog.cancel()
            if isClosed || state != .loading {
                Task.detached { try? await client.close() }
                return
            }
            sftp = client
            let home = (try? await client.getRealPath(atPath: ".")) ?? "/"
            homePath = home
            // 优先落在该 pane 终端的当前目录;那个目录可能已被删/无权限,失败就回落 home
            if let initialPath, initialPath != home {
                await list(path: initialPath)
                if case .failed = state { await list(path: home) }
            } else {
                await list(path: home)
            }
        } catch {
            // 看门狗超时置败后,opening 被 cancel 抛错到这里,不要覆盖超时提示
            if state == .loading { state = .failed(friendly(error)) }
        }
    }

    /// 已连上则重新列目录;打开失败/未打开(如面板先于连接打开)则重试整个打开流程
    func refresh() async {
        if sftp == nil {
            await start()
        } else {
            await list(path: path)
        }
    }

    func enter(_ entry: Entry) async {
        guard entry.isDirectory || entry.isSymlink else { return }
        await list(path: join(path, entry.name))
    }

    func goUp() async {
        guard path != "/" else { return }
        let parent = (path as NSString).deletingLastPathComponent
        await list(path: parent.isEmpty ? "/" : parent)
    }

    /// 手输路径跳转:支持 ~、~/xxx 与相对当前目录的路径
    func navigate(to newPath: String) async {
        var target = newPath.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        if target == "~" {
            target = homePath
        } else if target.hasPrefix("~/") {
            target = join(homePath, String(target.dropFirst(2)))
        } else if !target.hasPrefix("/") {
            target = join(path, target)
        }
        if target.count > 1, target.hasSuffix("/") { target.removeLast() }
        await list(path: target)
    }

    private func list(path newPath: String) async {
        guard let sftp else { return }
        state = .loading
        do {
            let names = try await sftp.listDirectory(atPath: newPath)
            let components = names.flatMap(\.components)
            let mapped: [Entry] = components.compactMap { component in
                let name = component.filename
                guard name != ".", name != ".." else { return nil }
                let type = fileType(component)
                return Entry(
                    name: name,
                    isDirectory: type == .directory,
                    isSymlink: type == .symlink,
                    size: component.attributes.size ?? 0,
                    modified: component.attributes.accessModificationTime?.modificationTime,
                    permissions: component.attributes.permissions ?? 0
                )
            }
            entries = mapped.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            path = newPath
            state = .ready
        } catch {
            state = .failed(friendly(error))
        }
    }

    // MARK: - 传输

    /// 分块传输的块大小(256KB):够大以摊薄往返开销,又够小以更新进度
    private static let chunkSize = 256 * 1024

    private func beginTransfer(_ label: String, progress: Double? = nil) -> UUID {
        let id = UUID()
        transfers.append(ActiveTransfer(id: id, label: label, progress: progress))
        return id
    }

    private func setTransfer(_ id: UUID, label: String) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].label = label
    }

    private func setTransfer(_ id: UUID, progress: Double?) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].progress = progress
    }

    private func endTransfer(_ id: UUID) {
        transfers.removeAll { $0.id == id }
    }

    func download(_ entry: Entry, to localURL: URL) async {
        do {
            try await performDownload(
                entry,
                remoteDirectory: path,
                to: localURL,
                externalProgress: nil
            )
        } catch {
            state = .failed(friendly(error))
        }
    }

    /// Finder 拖出下载使用。拖拽开始时冻结 remoteDirectory,避免传输过程中切换目录后
    /// 同名文件被解析到新的当前位置。错误必须继续抛给 NSItemProvider,让 Finder 显示失败。
    func downloadForDrag(
        _ entry: Entry,
        remoteDirectory: String,
        to localURL: URL,
        progress: Progress
    ) async throws {
        try await performDownload(
            entry,
            remoteDirectory: remoteDirectory,
            to: localURL,
            externalProgress: progress
        )
    }

    private func performDownload(
        _ entry: Entry,
        remoteDirectory: String,
        to localURL: URL,
        externalProgress: Progress?
    ) async throws {
        guard let sftp else { throw TransferError.sftpUnavailable }

        let remotePath = join(remoteDirectory, entry.name)
        let transferID = beginTransfer(
            entry.isDirectory
                ? String(localized: "扫描 \(entry.name)…")
                : String(localized: "下载 \(entry.name)…"),
            progress: !entry.isDirectory && entry.size > 0 ? 0 : nil
        )
        defer { endTransfer(transferID) }

        if entry.isDirectory {
            try await performDirectoryDownload(
                name: entry.name,
                remotePath: remotePath,
                localURL: localURL,
                sftp: sftp,
                transferID: transferID,
                externalProgress: externalProgress
            )
        } else {
            externalProgress?.totalUnitCount = entry.size > 0 ? Int64(clamping: entry.size) : 1
            _ = try await copyRemoteFile(
                remotePath: remotePath,
                localURL: localURL,
                sftp: sftp
            ) { copied in
                if entry.size > 0 {
                    setTransfer(transferID, progress: min(1, Double(copied) / Double(entry.size)))
                    externalProgress?.completedUnitCount = min(
                        externalProgress?.totalUnitCount ?? 0,
                        Int64(clamping: copied)
                    )
                }
            }
            if entry.size == 0 { externalProgress?.completedUnitCount = 1 }
        }
    }

    private func performDirectoryDownload(
        name: String,
        remotePath: String,
        localURL: URL,
        sftp: SFTPClient,
        transferID: UUID,
        externalProgress: Progress?
    ) async throws {
        let plan = try await Self.makeDirectoryDownloadPlan(remoteRoot: remotePath) { path in
            let names = try await sftp.listDirectory(atPath: path)
            return names.flatMap(\.components).compactMap { component in
                guard component.filename != ".", component.filename != ".." else { return nil }
                let kind: DownloadTreeEntry.Kind = switch fileType(component) {
                case .directory: .directory
                case .symlink: .symlink
                case .file: .file
                }
                return DownloadTreeEntry(
                    name: component.filename,
                    kind: kind,
                    size: component.attributes.size ?? 0
                )
            }
        }

        try Task.checkCancellation()
        let totalUnits = plan.totalBytes > 0 ? Int64(clamping: plan.totalBytes) : 1
        externalProgress?.totalUnitCount = totalUnits
        externalProgress?.completedUnitCount = 0
        setTransfer(transferID, label: plan.skippedSymlinks > 0
            ? String(localized: "下载 \(name)…(跳过 \(plan.skippedSymlinks) 个符号链接)")
            : String(localized: "下载 \(name)…"))
        setTransfer(transferID, progress: plan.totalBytes > 0 ? 0 : nil)

        for components in plan.directories {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(
                at: localURL.appendingPathComponents(components, directory: true),
                withIntermediateDirectories: true
            )
        }

        var completedBytes: UInt64 = 0
        for item in plan.files {
            try Task.checkCancellation()
            let base = completedBytes
            let copied = try await copyRemoteFile(
                remotePath: item.remotePath,
                localURL: localURL.appendingPathComponents(item.relativeComponents, directory: false),
                sftp: sftp
            ) { fileBytes in
                let aggregate = Self.saturatingAdd(base, fileBytes)
                if plan.totalBytes > 0 {
                    setTransfer(transferID, progress: min(1, Double(aggregate) / Double(plan.totalBytes)))
                    externalProgress?.completedUnitCount = min(totalUnits, Int64(clamping: aggregate))
                }
            }
            completedBytes = Self.saturatingAdd(completedBytes, copied)
        }

        setTransfer(transferID, progress: 1)
        externalProgress?.completedUnitCount = totalUnits
    }

    @discardableResult
    private func copyRemoteFile(
        remotePath: String,
        localURL: URL,
        sftp: SFTPClient,
        onProgress: (_ copied: UInt64) -> Void
    ) async throws -> UInt64 {
        let file = try await sftp.openFile(filePath: remotePath, flags: .read)
        defer { Task { try? await file.close() } }
        guard FileManager.default.createFile(atPath: localURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: localURL)
        defer { try? handle.close() }
        return try await Self.copyDownloadChunks(
            chunkSize: Self.chunkSize,
            read: { offset, length in
                let buffer = try await file.read(from: offset, length: length)
                return Data(buffer.readableBytesView)
            },
            write: { data in
                try handle.write(contentsOf: data)
            },
            onProgress: onProgress
        )
    }

    /// 先扫描目录树以获得稳定的本地相对路径和总字节。符号链接不跟随,避免循环与
    /// 把目录树之外的目标意外复制进来。
    static func makeDirectoryDownloadPlan(
        remoteRoot: String,
        list: (_ remotePath: String) async throws -> [DownloadTreeEntry]
    ) async throws -> DirectoryDownloadPlan {
        var plan = DirectoryDownloadPlan()

        func scan(remotePath: String, relativeComponents: [String]) async throws {
            try Task.checkCancellation()
            plan.directories.append(relativeComponents)
            for entry in try await list(remotePath) {
                try Task.checkCancellation()
                guard entry.name != ".", entry.name != ".." else { continue }
                let childRemotePath = remotePath == "/"
                    ? "/\(entry.name)"
                    : "\(remotePath)/\(entry.name)"
                let childComponents = relativeComponents + [entry.name]
                switch entry.kind {
                case .directory:
                    try await scan(remotePath: childRemotePath, relativeComponents: childComponents)
                case .file:
                    plan.files.append(DownloadTreeFile(
                        remotePath: childRemotePath,
                        relativeComponents: childComponents,
                        size: entry.size
                    ))
                    plan.totalBytes = saturatingAdd(plan.totalBytes, entry.size)
                case .symlink:
                    plan.skippedSymlinks += 1
                }
            }
        }

        try await scan(remotePath: remoteRoot, relativeComponents: [])
        return plan
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    /// 上传前先扫描本地目录树(issue #17),与下载 plan 对称:符号链接不跟随,
    /// 避免循环与把树外目标意外上传;list 可注入便于测试。
    static func makeDirectoryUploadPlan(
        localRoot: URL,
        list: (_ url: URL) throws -> [UploadTreeEntry]
    ) throws -> DirectoryUploadPlan {
        var plan = DirectoryUploadPlan()

        func scan(url: URL, relativeComponents: [String]) throws {
            try Task.checkCancellation()
            plan.directories.append(relativeComponents)
            for entry in try list(url) {
                let childURL = url.appendingPathComponent(entry.name)
                let childComponents = relativeComponents + [entry.name]
                switch entry.kind {
                case .directory:
                    try scan(url: childURL, relativeComponents: childComponents)
                case .file:
                    plan.files.append(UploadTreeFile(
                        localURL: childURL,
                        relativeComponents: childComponents,
                        size: entry.size
                    ))
                    plan.totalBytes = saturatingAdd(plan.totalBytes, entry.size)
                case .symlink:
                    plan.skippedSymlinks += 1
                }
            }
        }

        try scan(url: localRoot, relativeComponents: [])
        return plan
    }

    /// 生产用的本地目录列举:先判符号链接(symlink 指向目录时 isDirectory 会随目标为真,
    /// 判断顺序反了就会跟着链接走);按名字排序保证顺序稳定。
    static func listLocalDirectory(_ url: URL) throws -> [UploadTreeEntry] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        )
        return try contents.map { child in
            let values = try child.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            let kind: UploadTreeEntry.Kind = values.isSymbolicLink == true
                ? .symlink
                : (values.isDirectory == true ? .directory : .file)
            return UploadTreeEntry(
                name: child.lastPathComponent,
                kind: kind,
                size: UInt64(clamping: values.fileSize ?? 0)
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 流式分块上传单个本地文件(大文件不整读进内存)。面板与终端拖拽共用。
    @discardableResult
    static func uploadLocalFile(
        _ localURL: URL,
        to remotePath: String,
        sftp: SFTPClient,
        onProgress: (_ copied: UInt64) -> Void = { _ in }
    ) async throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }
        let file = try await sftp.openFile(filePath: remotePath, flags: [.write, .create, .truncate])
        defer { Task { try? await file.close() } }

        var offset: UInt64 = 0
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else { break }
            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.writeBytes(data)
            try await file.write(buffer, at: offset)
            offset += UInt64(data.count)
            onProgress(offset)
        }
        if offset == 0 {
            // 空文件也要建出来
            try await file.write(ByteBufferAllocator().buffer(capacity: 0), at: 0)
        }
        return offset
    }

    /// 递归上传整个目录:扫描出 plan → 建远端目录 → 逐文件流式上传。
    /// createDirectory 的失败不当场报错(目录可能已存在,语义是合并);
    /// 若确实建不出来,随后第一个文件写入会抛出更明确的错误。
    static func performDirectoryUpload(
        localRoot: URL,
        remoteRoot: String,
        sftp: SFTPClient,
        onPlan: (DirectoryUploadPlan) -> Void = { _ in },
        onProgress: (_ copied: UInt64, _ total: UInt64) -> Void = { _, _ in }
    ) async throws {
        let plan = try makeDirectoryUploadPlan(localRoot: localRoot, list: listLocalDirectory)
        onPlan(plan)

        for components in plan.directories {
            try Task.checkCancellation()
            let remote = components.reduce(remoteRoot) { $0 == "/" ? "/\($1)" : "\($0)/\($1)" }
            try? await sftp.createDirectory(atPath: remote)
        }

        var completedBytes: UInt64 = 0
        for item in plan.files {
            try Task.checkCancellation()
            let remote = item.relativeComponents.reduce(remoteRoot) { $0 == "/" ? "/\($1)" : "\($0)/\($1)" }
            let base = completedBytes
            let copied = try await uploadLocalFile(item.localURL, to: remote, sftp: sftp) { fileBytes in
                onProgress(saturatingAdd(base, fileBytes), plan.totalBytes)
            }
            completedBytes = saturatingAdd(completedBytes, copied)
        }
        onProgress(completedBytes, plan.totalBytes)
    }

    /// 持续读取直到服务端明确返回 0 字节。SFTP 单次 read 可以合法地返回少于请求长度的
    /// 数据(常见上限约几十 KB),短读不代表 EOF;把短读当 EOF 会让大文件只下载首个包。
    @discardableResult
    static func copyDownloadChunks(
        chunkSize: Int,
        read: (_ offset: UInt64, _ length: UInt32) async throws -> Data,
        write: (_ data: Data) throws -> Void,
        onProgress: (_ copied: UInt64) -> Void = { _ in }
    ) async throws -> UInt64 {
        precondition(chunkSize > 0 && chunkSize <= Int(UInt32.max))
        var offset: UInt64 = 0
        while true {
            try Task.checkCancellation()
            let data = try await read(offset, UInt32(chunkSize))
            guard !data.isEmpty else { return offset }
            try write(data)
            offset += UInt64(data.count)
            onProgress(offset)
        }
    }

    /// 上传文件或整个目录(issue #17):目录先扫描再递归,文件流式分块不整读进内存
    func upload(from localURL: URL) async {
        guard let sftp else { return }
        let name = localURL.lastPathComponent
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDir)
        let transferID = beginTransfer(isDir.boolValue
            ? String(localized: "扫描 \(name)…")
            : String(localized: "上传 \(name)…"))
        defer { endTransfer(transferID) }
        do {
            if isDir.boolValue {
                try await Self.performDirectoryUpload(
                    localRoot: localURL,
                    remoteRoot: join(path, name),
                    sftp: sftp,
                    onPlan: { plan in
                        setTransfer(transferID, label: plan.skippedSymlinks > 0
                            ? String(localized: "上传 \(name)…(跳过 \(plan.skippedSymlinks) 个符号链接)")
                            : String(localized: "上传 \(name)…"))
                        setTransfer(transferID, progress: plan.totalBytes > 0 ? 0 : nil)
                    },
                    onProgress: { copied, total in
                        if total > 0 {
                            setTransfer(transferID, progress: min(1, Double(copied) / Double(total)))
                        }
                    }
                )
            } else {
                let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? UInt64) ?? 0
                setTransfer(transferID, progress: size > 0 ? 0 : nil)
                try await Self.uploadLocalFile(localURL, to: join(path, name), sftp: sftp) { copied in
                    if size > 0 {
                        setTransfer(transferID, progress: min(1, Double(copied) / Double(size)))
                    }
                }
            }
            await refresh()
        } catch {
            state = .failed(friendly(error))
        }
    }

    // MARK: - 服务端文件编辑(下载 → 本地编辑器 → 保存自动回传)

    /// 正在编辑中的远端文件(远端绝对路径 → 状态),供 UI 显示角标
    private(set) var editing: [String: EditState] = [:]
    enum EditState: Equatable { case syncing, idle, failed }
    @ObservationIgnored private var editTasks: [String: Task<Void, Never>] = [:]
    /// 已在编辑的远端路径 → 本地临时副本(供再次点击时直接重开编辑器)
    @ObservationIgnored private var editLocalURLs: [String: URL] = [:]

    /// 双击文件时:拉到本地临时目录,用默认编辑器打开,轮询本地改动自动回传到原路径。
    /// openInEditor=false 仅供自动化验收(不真的启动编辑器),返回本地临时文件路径。
    @discardableResult
    func editRemotely(_ entry: Entry, openInEditor: Bool = true) -> URL? {
        guard let sftp, !entry.isDirectory else { return nil }
        let remotePath = join(path, entry.name)
        // 已在编辑:直接重开已有本地副本,不再重复下载/新建监听
        if editTasks[remotePath] != nil {
            if let existing = editLocalURLs[remotePath], openInEditor {
                NSWorkspace.shared.open(existing)
            }
            return editLocalURLs[remotePath]
        }

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("berth-edit-\(UUID().uuidString)", isDirectory: true)
        let localURL = dir.appendingPathComponent(entry.name)
        editLocalURLs[remotePath] = localURL

        editing[remotePath] = .syncing
        let task = Task { [weak self] in
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                // 下载
                let file = try await sftp.openFile(filePath: remotePath, flags: .read)
                let buffer = try await file.readAll()
                try? await file.close()
                try Data(buffer.readableBytesView).write(to: localURL)
                await MainActor.run {
                    self?.editing[remotePath] = .idle
                    if openInEditor { NSWorkspace.shared.open(localURL) }
                }
                await self?.watchAndSync(localURL: localURL, remotePath: remotePath, sftp: sftp)
            } catch {
                await MainActor.run { self?.editing[remotePath] = .failed }
            }
            try? FileManager.default.removeItem(at: dir)
        }
        editTasks[remotePath] = task
        return localURL
    }

    /// 轮询本地文件 mtime,变化即回传(对 vim/VSCode 的原子保存-重命名也可靠)
    private func watchAndSync(localURL: URL, remotePath: String, sftp: SFTPClient) async {
        func mtime() -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.modificationDate]) as? Date
        }
        var lastModified = mtime()
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(1200))
            guard FileManager.default.fileExists(atPath: localURL.path) else { continue }
            let current = mtime()
            guard current != lastModified else { continue }
            lastModified = current
            editing[remotePath] = .syncing
            do {
                let data = try Data(contentsOf: localURL)
                let file = try await sftp.openFile(filePath: remotePath, flags: [.write, .create, .truncate])
                var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                buffer.writeBytes(data)
                try await file.write(buffer, at: 0)
                try? await file.close()
                editing[remotePath] = .idle
                if path == (remotePath as NSString).deletingLastPathComponent { await refresh() }
            } catch {
                editing[remotePath] = .failed
            }
        }
    }

    func stopEditing(_ remotePath: String) {
        editTasks[remotePath]?.cancel()
        editTasks[remotePath] = nil
        editLocalURLs[remotePath] = nil
        editing[remotePath] = nil
    }

    // MARK: - chmod / 预览 / 书签

    /// 修改权限(保留文件类型高位,仅换低 12 位)
    func chmod(_ entry: Entry, mode: UInt32) async {
        guard let sftp else { return }
        do {
            var attrs = SFTPFileAttributes()
            attrs.permissions = (entry.permissions & ~0o7777) | (mode & 0o7777)
            try await sftp.setAttributes(at: join(path, entry.name), to: attrs)
            await refresh()
        } catch {
            state = .failed(friendly(error))
        }
    }

    /// 快速预览:下载小文本文件(≤256KB)返回内容;过大或二进制返回 nil
    func previewText(_ entry: Entry) async -> String? {
        guard let sftp, !entry.isDirectory, entry.size <= 256 * 1024 else { return nil }
        do {
            let file = try await sftp.openFile(filePath: join(path, entry.name), flags: .read)
            let buffer = try await file.readAll()
            try? await file.close()
            let data = Data(buffer.readableBytesView)
            // 含 NUL 视为二进制
            if data.prefix(8000).contains(0) { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    // 书签(常用远端目录,全局持久化)
    private static let bookmarksKey = "sftp.bookmarks"
    private(set) var bookmarks: [String] = UserDefaults.standard.stringArray(forKey: SFTPBrowser.bookmarksKey) ?? []

    func toggleBookmark() {
        if let idx = bookmarks.firstIndex(of: path) {
            bookmarks.remove(at: idx)
        } else {
            bookmarks.append(path)
        }
        UserDefaults.standard.set(bookmarks, forKey: Self.bookmarksKey)
    }

    var isCurrentBookmarked: Bool { bookmarks.contains(path) }

    func makeDirectory(name: String) async {
        guard let sftp, !name.isEmpty else { return }
        do {
            try await sftp.createDirectory(atPath: join(path, name))
            await refresh()
        } catch {
            state = .failed(friendly(error))
        }
    }

    func delete(_ entry: Entry) async {
        guard let sftp else { return }
        do {
            let full = join(path, entry.name)
            if entry.isDirectory {
                try await sftp.rmdir(at: full)
            } else {
                try await sftp.remove(at: full)
            }
            await refresh()
        } catch {
            state = .failed(friendly(error))
        }
    }

    func rename(_ entry: Entry, to newName: String) async {
        guard let sftp, !newName.isEmpty, newName != entry.name else { return }
        do {
            try await sftp.rename(at: join(path, entry.name), to: join(path, newName))
            await refresh()
        } catch {
            state = .failed(friendly(error))
        }
    }

    func close() {
        isClosed = true
        for task in editTasks.values { task.cancel() }
        editTasks = [:]
        editLocalURLs = [:]
        editing = [:]
        let client = sftp
        sftp = nil
        Task.detached { try? await client?.close() }
    }

    // MARK: - 工具

    private enum FileType { case directory, symlink, file }

    private enum TransferError: LocalizedError {
        case sftpUnavailable

        var errorDescription: String? {
            switch self {
            case .sftpUnavailable: String(localized: "SFTP 连接不可用")
            }
        }
    }

    private func fileType(_ component: SFTPPathComponent) -> FileType {
        if let permissions = component.attributes.permissions {
            switch permissions & 0o170000 {
            case 0o040000: return .directory
            case 0o120000: return .symlink
            default: return .file
            }
        }
        // permissions 缺失时看 ls -l 首字符
        switch component.longname.first {
        case "d": return .directory
        case "l": return .symlink
        default: return .file
        }
    }

    private func join(_ base: String, _ name: String) -> String {
        base == "/" ? "/\(name)" : "\(base)/\(name)"
    }

    private func friendly(_ error: Error) -> String {
        let raw = String(describing: error)
        if raw.localizedCaseInsensitiveContains("permission") { return String(localized: "权限不足") }
        if raw.localizedCaseInsensitiveContains("noSuchFile") || raw.localizedCaseInsensitiveContains("no such") {
            return String(localized: "文件或目录不存在")
        }
        return String(localized: "SFTP 操作失败:\(raw)")
    }
}

private extension URL {
    func appendingPathComponents(_ components: [String], directory: Bool) -> URL {
        components.enumerated().reduce(self) { url, pair in
            let (index, component) = pair
            return url.appendingPathComponent(
                component,
                isDirectory: index < components.count - 1 || directory
            )
        }
    }
}
