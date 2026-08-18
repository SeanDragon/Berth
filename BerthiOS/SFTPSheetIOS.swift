import SwiftUI
import UniformTypeIdentifiers

/// iOS SFTP 文件面板:复用会话连接开子通道,浏览/上传/下载分享/重命名/删除/新建目录/文本预览。
/// 与 Mac 端共用 SFTPBrowser 核心,这里只做触屏 UI。
struct SFTPSheetIOS: View {
    let session: IOSTerminalSession

    @Environment(\.dismiss) private var dismiss
    @State private var theme = ThemeStore.shared
    @State private var browser: SFTPBrowser?

    @State private var showUploader = false
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var renameTarget: SFTPBrowser.Entry?
    @State private var renameText = ""
    @State private var deleteTarget: SFTPBrowser.Entry?
    @State private var preview: PreviewPayload?
    @State private var shareItem: ShareItem?
    @State private var isEditingPath = false
    @State private var pathText = ""

    private struct PreviewPayload: Identifiable {
        let id = UUID()
        let name: String
        let text: String
    }

    private struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        NavigationStack {
            Group {
                if let browser {
                    content(browser)
                } else {
                    ProgressView()
                }
            }
            .background(theme.current.sidebarBackground)
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "完成")) { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if let browser {
                        Button {
                            Task { await browser.goUp() }
                        } label: {
                            Image(systemName: "arrow.up")
                        }
                        .disabled(browser.path == "/")
                        Menu {
                            Button { showUploader = true } label: {
                                Label(String(localized: "上传文件…"), systemImage: "square.and.arrow.up")
                            }
                            Button { isCreatingFolder = true } label: {
                                Label(String(localized: "新建文件夹…"), systemImage: "folder.badge.plus")
                            }
                            Button {
                                Task { await browser.navigate(to: browser.homePath) }
                            } label: {
                                Label(String(localized: "回到主目录"), systemImage: "house")
                            }
                            Button {
                                pathText = browser.path
                                isEditingPath = true
                            } label: {
                                Label(String(localized: "跳转到路径…"), systemImage: "arrow.right.to.line")
                            }
                            Button {
                                Task { await browser.refresh() }
                            } label: {
                                Label(String(localized: "刷新"), systemImage: "arrow.clockwise")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
        }
        .tint(theme.current.accentColor)
        .preferredColorScheme(theme.current.isDark ? .dark : .light)
        .task {
            if browser == nil {
                let created = SFTPBrowser { try await session.openSFTP() }
                browser = created
                await created.start()
            }
        }
        .onDisappear { browser?.close() }
        .fileImporter(
            isPresented: $showUploader,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { upload(urls) }
        }
        .alert(String(localized: "新建文件夹"), isPresented: $isCreatingFolder) {
            TextField(String(localized: "名称"), text: $newFolderName)
            Button(String(localized: "创建")) {
                let name = newFolderName.trimmingCharacters(in: .whitespaces)
                newFolderName = ""
                guard !name.isEmpty else { return }
                Task { await browser?.makeDirectory(name: name) }
            }
            Button(String(localized: "取消"), role: .cancel) { newFolderName = "" }
        }
        .alert(String(localized: "跳转到路径"), isPresented: $isEditingPath) {
            TextField("/var/www", text: $pathText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(String(localized: "前往")) {
                let target = pathText.trimmingCharacters(in: .whitespaces)
                guard !target.isEmpty else { return }
                Task { await browser?.navigate(to: target) }
            }
            Button(String(localized: "取消"), role: .cancel) {}
        }
        .alert(
            String(localized: "重命名「\(renameTarget?.name ?? "")」"),
            isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
        ) {
            TextField(String(localized: "新名称"), text: $renameText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(String(localized: "重命名")) {
                if let entry = renameTarget {
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty, name != entry.name {
                        Task { await browser?.rename(entry, to: name) }
                    }
                }
                renameTarget = nil
            }
            Button(String(localized: "取消"), role: .cancel) { renameTarget = nil }
        }
        .alert(
            String(localized: "删除「\(deleteTarget?.name ?? "")」?"),
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
        ) {
            Button(String(localized: "删除"), role: .destructive) {
                if let entry = deleteTarget {
                    Task { await browser?.delete(entry) }
                }
                deleteTarget = nil
            }
            Button(String(localized: "取消"), role: .cancel) { deleteTarget = nil }
        } message: {
            Text(deleteTarget?.isDirectory == true
                ? String(localized: "文件夹及其中所有内容将被删除,此操作不可撤销。")
                : String(localized: "此操作不可撤销。"))
        }
        .sheet(item: $preview) { payload in
            NavigationStack {
                ScrollView {
                    Text(payload.text)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .textSelection(.enabled)
                }
                .background(theme.current.chromeBackground)
                .navigationTitle(payload.name)
                .navigationBarTitleDisplayMode(.inline)
            }
            .preferredColorScheme(theme.current.isDark ? .dark : .light)
        }
        .sheet(item: $shareItem) { item in
            ActivityShareSheet(url: item.url)
                .presentationDetents([.medium, .large])
        }
    }

    private var titleText: String {
        guard let browser else { return String(localized: "文件") }
        let last = (browser.path as NSString).lastPathComponent
        return last.isEmpty ? "/" : last
    }

    @ViewBuilder
    private func content(_ browser: SFTPBrowser) -> some View {
        switch browser.state {
        case .idle, .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text(String(localized: "正在打开 SFTP…"))
                    .font(.footnote)
                    .foregroundStyle(theme.current.secondaryText)
            }
        case .failed(let message):
            ContentUnavailableView {
                Label(String(localized: "SFTP 出错"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button(String(localized: "重试")) {
                    Task { await browser.refresh() }
                }
                .buttonStyle(.borderedProminent)
            }
        case .ready:
            List {
                Section {
                    ForEach(browser.entries) { entry in
                        row(entry, browser: browser)
                            .listRowBackground(theme.current.panelBackground)
                    }
                } header: {
                    Text(browser.path)
                        .font(.caption2)
                        .monospaced()
                        .textCase(nil)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .scrollContentBackground(.hidden)
            .refreshable { await browser.refresh() }
            .safeAreaInset(edge: .bottom) {
                if !browser.transfers.isEmpty {
                    transferBar(browser)
                }
            }
            .overlay {
                if browser.entries.isEmpty {
                    Text(String(localized: "空目录"))
                        .font(.footnote)
                        .foregroundStyle(theme.current.secondaryText)
                }
            }
        }
    }

    private func row(_ entry: SFTPBrowser.Entry, browser: SFTPBrowser) -> some View {
        Button {
            if entry.isDirectory {
                Task { await browser.enter(entry) }
            } else {
                previewOrShare(entry, browser: browser)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon(for: entry))
                    .foregroundStyle(entry.isDirectory ? theme.current.accentColor : theme.current.secondaryText)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        if !entry.isDirectory {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                        }
                        if let modified = entry.modified {
                            Text(modified.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(theme.current.secondaryText)
                }
                Spacer()
                if entry.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(theme.current.secondaryText)
                }
            }
        }
        .foregroundStyle(.primary)
        .contextMenu {
            Button {
                downloadAndShare(entry, browser: browser)
            } label: {
                Label(String(localized: "下载并分享…"), systemImage: "square.and.arrow.up")
            }
            if !entry.isDirectory {
                Button {
                    previewOrShare(entry, browser: browser)
                } label: {
                    Label(String(localized: "预览"), systemImage: "eye")
                }
            }
            Button {
                renameText = entry.name
                renameTarget = entry
            } label: {
                Label(String(localized: "重命名…"), systemImage: "pencil")
            }
            Button(role: .destructive) {
                deleteTarget = entry
            } label: {
                Label(String(localized: "删除…"), systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                deleteTarget = entry
            } label: {
                Label(String(localized: "删除"), systemImage: "trash")
            }
        }
    }

    private func transferBar(_ browser: SFTPBrowser) -> some View {
        VStack(spacing: 6) {
            ForEach(browser.transfers) { transfer in
                VStack(alignment: .leading, spacing: 3) {
                    Text(transfer.label)
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(theme.current.secondaryText)
                    if let progress = transfer.progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView()
                    }
                }
            }
        }
        .padding(10)
        .background(.regularMaterial)
    }

    private func icon(for entry: SFTPBrowser.Entry) -> String {
        if entry.isDirectory { return "folder.fill" }
        if entry.isSymlink { return "arrow.triangle.turn.up.right.diamond" }
        return "doc"
    }

    /// 文件点按:小文本直接预览;非文本/过大则下载分享
    private func previewOrShare(_ entry: SFTPBrowser.Entry, browser: SFTPBrowser) {
        Task {
            if let text = await browser.previewText(entry) {
                preview = PreviewPayload(name: entry.name, text: text)
            } else {
                downloadAndShare(entry, browser: browser)
            }
        }
    }

    private func downloadAndShare(_ entry: SFTPBrowser.Entry, browser: SFTPBrowser) {
        Task {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("berth-share-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let localURL = dir.appendingPathComponent(entry.name)
            await browser.download(entry, to: localURL)
            if FileManager.default.fileExists(atPath: localURL.path) {
                shareItem = ShareItem(url: localURL)
            }
        }
    }

    /// Files app 选中的文件先拷进沙箱临时目录再上传:
    /// 安全作用域的访问权在异步上传中途可能失效,拷贝一份最稳
    private func upload(_ urls: [URL]) {
        Task {
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("berth-upload-\(UUID().uuidString)", isDirectory: true)
                let localURL = dir.appendingPathComponent(url.lastPathComponent)
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: localURL)
                } catch {
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    continue
                }
                if scoped { url.stopAccessingSecurityScopedResource() }
                await browser?.upload(from: localURL)
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }
}

/// UIActivityViewController 封装:分享下载到本地的文件/文件夹
private struct ActivityShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
