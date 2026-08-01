import AppKit
import Citadel
import Foundation
import NIOCore
import SwiftUI
import UniformTypeIdentifiers

/// 拖文件进终端 pane → 上传到会话「当前目录」。
///
/// 目录三层解析(与 AI 助手同一套):OSC 7 上报精确直达;未启用命令集成时借同一条
/// SSH 连接探测 shell 进程 cwd;都拿不到才弹 sheet 询问。上传走会话的 SFTP 子通道,
/// 全程不往 shell 写任何字 —— 终端里正在跑的东西不受打扰。
@MainActor
@Observable
final class TerminalDropUploadModel {

    enum Phase: Equatable {
        case idle
        /// 拖拽悬停中;destination nil = 目录未知,松手后询问
        case targeting(destination: String?)
        case uploading(file: String, index: Int, total: Int, progress: Double?)
        case done(count: Int, directory: String)
        case failed(String)
    }
    private(set) var phase: Phase = .idle

    /// 目录未知时待确认的批次(sheet 让用户填目标目录)
    struct PendingBatch: Identifiable, Equatable {
        let id = UUID()
        let urls: [URL]
    }
    var pendingBatch: PendingBatch?

    /// 远端已有同名文件时待确认的批次
    struct PendingOverwrite: Identifiable, Equatable {
        let id = UUID()
        let urls: [URL]
        let directory: String
        let conflicts: [String]
    }
    var pendingOverwrite: PendingOverwrite?

    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    /// 悬停时预跑目录探测(有一次网络往返,别等松手才开始)
    @ObservationIgnored private var probeTask: Task<String?, Never>?

    // MARK: - 拖拽生命周期

    func dragEntered(session: TerminalSession) {
        dismissTask?.cancel()
        if let cwd = session.currentRemoteDirectory {
            phase = .targeting(destination: cwd)
            return
        }
        phase = .targeting(destination: nil)
        let task = Task { [weak session] in
            let dirs = await session?.probeRemoteWorkingDirectories() ?? []
            return dirs.count == 1 ? dirs.first : nil
        }
        probeTask = task
        Task { [weak self] in
            guard let dir = await task.value else { return }
            if case .targeting = self?.phase { self?.phase = .targeting(destination: dir) }
        }
    }

    func dragExited() {
        if case .targeting = phase { phase = .idle }
    }

    /// onDrop 回调:收集文件 URL,解析目录,发起上传或转入询问
    func handleDrop(_ providers: [NSItemProvider], session: TerminalSession) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else {
            dragExited()
            return false
        }
        guard case .connected = session.state else {
            show(.failed(String(localized: "会话未连接,无法上传。")))
            return true
        }
        Task { await processDrop(fileProviders, session: session) }
        return true
    }

    private func processDrop(_ providers: [NSItemProvider], session: TerminalSession) async {
        let urls = await Self.fileURLs(from: providers)
        let files = urls.filter { url in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            return !isDir.boolValue
        }
        guard !files.isEmpty else {
            show(.failed(String(localized: "暂不支持上传文件夹,请拖入文件。")))
            return
        }

        // 悬停时预解析的结果优先;还在探测中就等它
        var destination: String?
        if case .targeting(let dest) = phase, let dest {
            destination = dest
        } else if let cwd = session.currentRemoteDirectory {
            destination = cwd
        } else if let task = probeTask {
            destination = await task.value
        } else {
            let dirs = await session.probeRemoteWorkingDirectories()
            destination = dirs.count == 1 ? dirs.first : nil
        }
        probeTask = nil

        guard let directory = destination else {
            phase = .idle
            pendingBatch = PendingBatch(urls: files)
            return
        }
        await upload(files, to: directory, session: session)
    }

    // MARK: - 上传

    /// checkConflicts=false 用于用户已确认覆盖的第二次调用
    func upload(_ urls: [URL], to directory: String, session: TerminalSession, checkConflicts: Bool = true) async {
        guard let first = urls.first else { return }
        dismissTask?.cancel()
        phase = .uploading(file: first.lastPathComponent, index: 1, total: urls.count, progress: nil)
        do {
            let sftp = try await session.openSFTP()
            defer { Task.detached { try? await sftp.close() } }

            var resolved = directory
            if resolved == "~" || resolved.hasPrefix("~/") {
                let home = try await sftp.getRealPath(atPath: ".")
                resolved = Self.expandTilde(resolved, home: home)
            }

            if checkConflicts {
                let remoteNames = (try? await sftp.listDirectory(atPath: resolved))?
                    .flatMap(\.components).map(\.filename) ?? []
                let conflicts = Self.conflictingNames(
                    localNames: urls.map(\.lastPathComponent), remoteNames: remoteNames
                )
                if !conflicts.isEmpty {
                    phase = .idle
                    pendingOverwrite = PendingOverwrite(urls: urls, directory: resolved, conflicts: conflicts)
                    return
                }
            }

            for (index, url) in urls.enumerated() {
                phase = .uploading(file: url.lastPathComponent, index: index + 1, total: urls.count, progress: nil)
                try await uploadOne(url, into: resolved, sftp: sftp) { [weak self] progress in
                    self?.phase = .uploading(
                        file: url.lastPathComponent, index: index + 1, total: urls.count, progress: progress
                    )
                }
            }
            show(.done(count: urls.count, directory: resolved))
        } catch {
            show(.failed(String(localized: "上传失败:\(shortDescription(of: error))")))
        }
    }

    /// 覆盖确认的三种走向
    func resolveOverwrite(_ pending: PendingOverwrite, overwrite: Bool, session: TerminalSession) {
        pendingOverwrite = nil
        let urls: [URL]
        if overwrite {
            urls = pending.urls
        } else {
            // 跳过已有:只传不冲突的
            urls = pending.urls.filter { !pending.conflicts.contains($0.lastPathComponent) }
        }
        guard !urls.isEmpty else {
            show(.failed(String(localized: "没有需要上传的文件(同名文件已全部跳过)。")))
            return
        }
        Task { await upload(urls, to: pending.directory, session: session, checkConflicts: false) }
    }

    /// 流式分块上传(256KB),大文件不整读进内存
    private func uploadOne(
        _ localURL: URL, into directory: String, sftp: SFTPClient,
        onProgress: @escaping (Double?) -> Void
    ) async throws {
        let total = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? UInt64) ?? 0
        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }
        let file = try await sftp.openFile(
            filePath: Self.join(directory, localURL.lastPathComponent),
            flags: [.write, .create, .truncate]
        )
        defer { Task { try? await file.close() } }

        let chunkSize = 256 * 1024
        var offset: UInt64 = 0
        while let data = try handle.read(upToCount: chunkSize), !data.isEmpty {
            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.writeBytes(data)
            try await file.write(buffer, at: offset)
            offset += UInt64(data.count)
            onProgress(total > 0 ? min(1, Double(offset) / Double(total)) : nil)
        }
        if offset == 0 {
            // 空文件也要建出来
            try await file.write(ByteBufferAllocator().buffer(capacity: 0), at: 0)
        }
    }

    // MARK: - 工具(纯函数,可测)

    static func conflictingNames(localNames: [String], remoteNames: [String]) -> [String] {
        let remote = Set(remoteNames)
        return localNames.filter { remote.contains($0) }
    }

    static func expandTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return join(home, String(path.dropFirst(2))) }
        return path
    }

    static func join(_ base: String, _ name: String) -> String {
        base == "/" ? "/\(name)" : "\(base)/\(name)"
    }

    static func fileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier)
            if let url = item as? URL {
                urls.append(url)
            } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                urls.append(url)
            }
        }
        return urls
    }

    // MARK: - 展示

    private func show(_ result: Phase) {
        phase = result
        dismissTask?.cancel()
        let lingering: Double
        if case .failed = result { lingering = 6 } else { lingering = 4 }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(lingering))
            guard let self, !Task.isCancelled else { return }
            if self.phase == result { self.phase = .idle }
        }
    }

    private func shortDescription(of error: Error) -> String {
        let raw = String(describing: error)
        if raw.localizedCaseInsensitiveContains("permission") { return String(localized: "目标目录权限不足") }
        return raw.count > 120 ? String(raw.prefix(120)) + "…" : raw
    }
}

// MARK: - 覆盖层

/// 挂在终端 pane 上的拖放视觉反馈:悬停高亮卡片 + 右下角进度/结果通气泡
struct TerminalDropOverlay: View {
    let model: TerminalDropUploadModel

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if case .targeting(let destination) = model.phase {
                ZStack {
                    Rectangle().fill(Color.black.opacity(0.28))
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                        .padding(6)
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.up.doc.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(theme.accentColor)
                        if let destination {
                            Text("上传到")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Text(destination)
                                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                                .lineLimit(2)
                                .truncationMode(.head)
                        } else {
                            Text("松手后选择上传目录")
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
                    .frame(maxWidth: 420)
                }
                .transition(.opacity)
            }

            toast
                .padding(12)
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.15), value: model.phase)
    }

    @ViewBuilder
    private var toast: some View {
        switch model.phase {
        case .uploading(let file, let index, let total, let progress):
            HStack(spacing: 8) {
                if let progress {
                    ProgressView(value: progress).progressViewStyle(.circular).controlSize(.small)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(total > 1 ? "上传 \(file)(\(index)/\(total))…" : "上传 \(file)…")
                    .font(.system(size: 11.5))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(.regularMaterial))
        case .done(let count, let directory):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("已上传 \(count) 个文件到 \(directory)")
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(.regularMaterial))
        case .failed(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 11.5))
                    .lineLimit(2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
        case .idle, .targeting:
            EmptyView()
        }
    }
}

/// 目录未知时的询问 sheet:预填 ~,顺带指路命令集成
struct DropDestinationSheet: View {
    let batch: TerminalDropUploadModel.PendingBatch
    let model: TerminalDropUploadModel
    let session: TerminalSession
    @Environment(\.dismiss) private var dismiss

    @State private var directory = "~"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("上传到哪个目录?")
                .font(.headline)
            Text("无法确定终端当前目录。在服务器信息面板(⌘I)启用命令集成后,下次拖放可自动上传到你所在的目录。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("远端目录", text: $directory)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5, design: .monospaced))
                .onSubmit(submit)
            HStack {
                Text(batch.urls.count > 1 ? "\(batch.urls.count) 个文件" : batch.urls.first?.lastPathComponent ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                Button("上传", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(directory.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func submit() {
        let target = directory.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        dismiss()
        Task { await model.upload(batch.urls, to: target, session: session) }
    }
}
