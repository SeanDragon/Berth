import Crypto
import Citadel
import Foundation
import NIOCore
import SwiftData

/// 密钥库操作:生成 / 导入 / 删除。私钥材料只进 Keychain。
@MainActor
enum KeyStore {

    enum KeyStoreError: LocalizedError {
        case emptyName

        var errorDescription: String? {
            switch self {
            case .emptyName:
                return String(localized: "给密钥起个名字。")
            }
        }
    }

    @discardableResult
    static func generateEd25519(name: String, context: ModelContext) throws -> SSHKeyRecord {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { throw KeyStoreError.emptyName }

        let privateKey = Curve25519.Signing.PrivateKey()
        let comment = "\(NSUserName())@Berth"
        let publicLine = OpenSSHFormat.publicKeyLine(ed25519: privateKey.publicKey, comment: comment)

        let record = SSHKeyRecord(name: trimmedName, keyType: "ssh-ed25519", publicKey: publicLine, storageFormat: .rawEd25519)
        try KeychainStore.save(
            privateKey.rawRepresentation.base64EncodedString(),
            account: KeychainStore.privateKeyAccount(for: record.id)
        )
        context.insert(record)
        try context.save()
        return record
    }

    @discardableResult
    static func importKey(name: String, pemText: String, passphrase: String?, context: ModelContext) throws -> SSHKeyRecord {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { throw KeyStoreError.emptyName }

        // 老式 PKCS#1 / PKCS#8 PEM(云厂商下发的 .pem、OpenSSH 7.8 之前生成的 key)
        // 归一化/解密/诊断统一走 parseForAuth(与两端连接路径同口径),库里存归一化产物。
        let parsed = try PrivateKeyFormat.parseForAuth(pemText, passphrase: passphrase, comment: trimmedName)
        let material = parsed.normalized.text

        let keyType: String
        let publicLine: String
        switch parsed.key {
        case .ed25519(let key):
            keyType = "ssh-ed25519"
            publicLine = OpenSSHFormat.publicKeyLine(ed25519: key.publicKey, comment: trimmedName)
        case .rsa(let key):
            keyType = "ssh-rsa"
            var body = ByteBufferAllocator().buffer(capacity: 1024)
            _ = key.publicKey.write(to: &body)
            publicLine = OpenSSHFormat.publicKeyLine(
                prefix: "ssh-rsa",
                keyBody: Data(body.readableBytesView),
                comment: trimmedName
            )
        }

        let record = SSHKeyRecord(name: trimmedName, keyType: keyType, publicKey: publicLine, storageFormat: .opensshPEM)
        try KeychainStore.save(material, account: KeychainStore.privateKeyAccount(for: record.id))
        // passphrase 已在转换时用掉的话,库里存的是明文密钥,没有再存口令的必要
        if let passphrase, !passphrase.isEmpty, !parsed.normalized.passphraseConsumed {
            try KeychainStore.save(passphrase, account: KeychainStore.keyPassphraseAccount(for: record.id))
        }
        context.insert(record)
        try context.save()
        return record
    }

    static func delete(_ record: SSHKeyRecord, context: ModelContext) {
        KeychainStore.deleteSecrets(forKey: record.id)
        context.delete(record)
        try? context.save()
    }

    /// 使用该密钥的主机数(删除前提示)
    static func hostsUsing(keyID: UUID, context: ModelContext) -> Int {
        let descriptor = FetchDescriptor<Host>(predicate: #Predicate { $0.keyID == keyID })
        return (try? context.fetchCount(descriptor)) ?? 0
    }
}
