import AppKit
import Foundation
import UniformTypeIdentifiers

/// SFTP 面板拖出下载的 NSItemProvider 工厂。Finder 在用户真正放下后才请求文件表示:
/// 先下载到独立临时目录,交给 NSItemProvider 复制,并在宽限期后清理临时副本。
/// 单独成型是为了让自动化验收能不经 Finder 直接 loadFileRepresentation 走同一条路
/// (文件与文件夹的表示都在这里注册)。
@MainActor
enum SFTPDragProvider {
    static func make(
        entry: SFTPBrowser.Entry,
        remoteDirectory: String,
        browser: SFTPBrowser?
    ) -> NSItemProvider {
        let provider = NSItemProvider()

        let pathExtension = (entry.name as NSString).pathExtension
        let inferredType = entry.isDirectory || pathExtension.isEmpty
            ? nil
            : UTType(filenameExtension: pathExtension)
        let contentType = entry.isDirectory ? UTType.folder : (inferredType ?? .data)
        // Finder 会按 UTI 自动补首选扩展名;这里给基名可避免 foo.json.json。
        // 未知扩展名会回落 public.data,它不会自动补扩展,因此仍保留完整名称。
        provider.suggestedName = entry.isDirectory || inferredType?.preferredFilenameExtension == nil
            ? entry.name
            : (entry.name as NSString).deletingPathExtension

        provider.registerFileRepresentation(
            forTypeIdentifier: contentType.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            let total = !entry.isDirectory && entry.size > 0 ? Int64(clamping: entry.size) : 1
            let progress = Progress(totalUnitCount: total)
            let task = Task { @MainActor in
                let temporaryDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Berth-Drag-\(UUID().uuidString)", isDirectory: true)
                let localURL = temporaryDirectory.appendingPathComponent(
                    entry.name,
                    isDirectory: entry.isDirectory
                )

                do {
                    guard let browser else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    try FileManager.default.createDirectory(
                        at: temporaryDirectory,
                        withIntermediateDirectories: true
                    )
                    try await browser.downloadForDrag(
                        entry,
                        remoteDirectory: remoteDirectory,
                        to: localURL,
                        progress: progress
                    )
                    completion(localURL, false, nil)
                    // 文件表示的接收方可能在 completion 返回后才开始复制。给 Finder 足够的
                    // 取用时间,再清理由 Berth 创建的临时副本;系统临时目录也会兜底清理。
                    Task.detached {
                        try? await Task.sleep(for: .seconds(30 * 60))
                        try? FileManager.default.removeItem(at: temporaryDirectory)
                    }
                } catch {
                    completion(nil, false, error)
                    try? FileManager.default.removeItem(at: temporaryDirectory)
                }
            }
            progress.cancellationHandler = { task.cancel() }
            return progress
        }
        return provider
    }
}
