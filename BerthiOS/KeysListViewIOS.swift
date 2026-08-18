import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// iOS 密钥管理:生成 ed25519 / 粘贴或从「文件」导入 OpenSSH 私钥 / 复制公钥 / 删除。
/// 私钥只进 Keychain,与 Mac 版共用同一套 KeyStore。
struct KeysListViewIOS: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SSHKeyRecord.name) private var keys: [SSHKeyRecord]
    @State private var theme = ThemeStore.shared

    @State private var isGenerating = false
    @State private var isImporting = false
    @State private var newKeyName = ""
    @State private var importText = ""
    @State private var importPassphrase = ""
    @State private var message: String?
    @State private var keyPendingDeletion: SSHKeyRecord?
    @State private var isPickingFile = false

    var body: some View {
        NavigationStack {
            Group {
                if keys.isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "密钥库是空的"), systemImage: "key")
                    } description: {
                        Text(String(localized: "生成一把新密钥,或导入现有的 OpenSSH 私钥。\n私钥只保存在 macOS Keychain,不落盘。"))
                    }
                } else {
                    List {
                        ForEach(keys) { key in
                            keyRow(key)
                                .listRowBackground(theme.current.panelBackground)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.current.sidebarBackground)
            .navigationTitle(String(localized: "密钥"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "完成")) { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Button { isGenerating = true } label: {
                            Label(String(localized: "生成 ed25519 密钥"), systemImage: "sparkles")
                        }
                        Button { isImporting = true } label: {
                            Label(String(localized: "导入现有密钥…"), systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert(String(localized: "生成 ed25519 密钥"), isPresented: $isGenerating) {
                TextField(String(localized: "名称"), text: $newKeyName)
                Button(String(localized: "生成")) { generate() }
                Button(String(localized: "取消"), role: .cancel) {}
            }
            .sheet(isPresented: $isImporting) { importSheet }
            .alert(
                String(localized: "删除密钥「\(keyPendingDeletion?.name ?? "")」?"),
                isPresented: Binding(get: { keyPendingDeletion != nil }, set: { if !$0 { keyPendingDeletion = nil } })
            ) {
                Button(String(localized: "删除"), role: .destructive) {
                    if let key = keyPendingDeletion { KeyStore.delete(key, context: modelContext) }
                    keyPendingDeletion = nil
                }
                Button(String(localized: "取消"), role: .cancel) { keyPendingDeletion = nil }
            } message: {
                Text(deletionWarning)
            }
        }
        .tint(theme.current.accentColor)
        .preferredColorScheme(theme.current.isDark ? .dark : .light)
    }

    private var deletionWarning: String {
        guard let key = keyPendingDeletion else { return "" }
        let count = KeyStore.hostsUsing(keyID: key.id, context: modelContext)
        if count > 0 {
            return String(localized: "有 \(count) 台主机正在使用该密钥,删除后它们将无法连接。Keychain 中的私钥会一并删除,此操作不可撤销。")
        }
        return String(localized: "Keychain 中的私钥会一并删除,此操作不可撤销。")
    }

    private func keyRow(_ key: SSHKeyRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(key.name).fontWeight(.medium)
                Spacer()
                Text(key.keyType)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(theme.current.accentSoft, in: Capsule())
            }
            Text(key.publicKey)
                .font(.caption2)
                .monospaced()
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(theme.current.secondaryText)
        }
        .contextMenu {
            Button {
                UIPasteboard.general.string = key.publicKey
                message = String(localized: "已复制")
            } label: {
                Label(String(localized: "复制公钥"), systemImage: "doc.on.doc")
            }
            Button(role: .destructive) {
                keyPendingDeletion = key
            } label: {
                Label(String(localized: "删除…"), systemImage: "trash")
            }
        }
    }

    private var importSheet: some View {
        NavigationStack {
            Form {
                Section(String(localized: "导入私钥")) {
                    TextField(String(localized: "名称"), text: $newKeyName)
                    TextField(String(localized: "粘贴 OpenSSH 私钥内容(-----BEGIN OPENSSH PRIVATE KEY-----)"), text: $importText, axis: .vertical)
                        .lineLimit(4...10)
                        .font(.system(size: 11, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        isPickingFile = true
                    } label: {
                        Label(String(localized: "从「文件」选择私钥…"), systemImage: "folder")
                    }
                    SecureField(String(localized: "Passphrase(没有则不填)"), text: $importPassphrase)
                }
                .listRowBackground(theme.current.panelBackground)
                if let message {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            .fileImporter(
                isPresented: $isPickingFile,
                allowedContentTypes: [.item]
            ) { result in
                if case .success(let url) = result { loadKeyFile(url) }
            }
            .scrollContentBackground(.hidden)
            .background(theme.current.sidebarBackground)
            .navigationTitle(String(localized: "导入密钥"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { isImporting = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "导入")) { importKey() }
                }
            }
        }
        .tint(theme.current.accentColor)
        .preferredColorScheme(theme.current.isDark ? .dark : .light)
    }

    private func generate() {
        do {
            _ = try KeyStore.generateEd25519(
                name: newKeyName.isEmpty ? "id_ed25519" : newKeyName,
                context: modelContext
            )
            newKeyName = ""
        } catch {
            message = error.localizedDescription
        }
    }

    /// 从「文件」读取私钥内容填入文本框(名称默认取文件名);私钥都很小,>64KB 直接拒绝
    private func loadKeyFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 64 * 1024 else {
                message = String(localized: "文件过大,看起来不是私钥。")
                return
            }
            guard let text = String(data: data, encoding: .utf8) else {
                message = String(localized: "无法读取该文件:不是文本格式的私钥。")
                return
            }
            importText = text
            if newKeyName.isEmpty { newKeyName = url.lastPathComponent }
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    private func importKey() {
        do {
            _ = try KeyStore.importKey(
                name: newKeyName.isEmpty ? String(localized: "导入的密钥") : newKeyName,
                pemText: importText,
                passphrase: importPassphrase.isEmpty ? nil : importPassphrase,
                context: modelContext
            )
            newKeyName = ""
            importText = ""
            importPassphrase = ""
            isImporting = false
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
}
