import Citadel
import Crypto
import NIOCore
import XCTest
@testable import Berth

/// 老式 PEM 私钥归一化。fixture 用 ssh-keygen 现场生成,不把密钥材料提交进仓库。
final class PrivateKeyFormatTests: XCTestCase {

    // MARK: - 转换正确性

    func testConvertsPKCS1ToOpenSSH() throws {
        let key = try GeneratedKey(mode: "PEM")
        let normalized = try PrivateKeyFormat.normalized(key.privateText, passphrase: nil, comment: "test")

        XCTAssertTrue(normalized.converted)
        XCTAssertFalse(normalized.passphraseConsumed)
        XCTAssertTrue(normalized.text.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"))
        // 转换结果必须能被 Citadel 解出来,且公钥与 ssh-keygen 生成的 .pub 一致
        XCTAssertEqual(try publicBlob(ofRSA: normalized.text), key.publicBlob)
    }

    func testConvertsPKCS8ToOpenSSH() throws {
        let key = try GeneratedKey(mode: "PKCS8")
        let normalized = try PrivateKeyFormat.normalized(key.privateText, passphrase: nil, comment: "test")

        XCTAssertTrue(normalized.converted)
        XCTAssertEqual(try publicBlob(ofRSA: normalized.text), key.publicBlob)
    }

    func testConvertsEncryptedPKCS1() throws {
        let key = try GeneratedKey(mode: "PEM", passphrase: "berth-spike")
        let normalized = try PrivateKeyFormat.normalized(
            key.privateText, passphrase: "berth-spike", comment: "test"
        )

        // 解密后存的是明文密钥,调用方不应再把 passphrase 当解密口令传下去
        XCTAssertTrue(normalized.passphraseConsumed)
        XCTAssertEqual(try publicBlob(ofRSA: normalized.text), key.publicBlob)
    }

    func testEncryptedPKCS1RejectsWrongPassphrase() throws {
        let key = try GeneratedKey(mode: "PEM", passphrase: "berth-spike")
        XCTAssertThrowsError(
            try PrivateKeyFormat.normalized(key.privateText, passphrase: "wrong", comment: "")
        ) { error in
            XCTAssertEqual(error as? PrivateKeyFormat.ConversionError, .wrongPassphrase)
        }
    }

    func testEncryptedPKCS1RequiresPassphrase() throws {
        let key = try GeneratedKey(mode: "PEM", passphrase: "berth-spike")
        XCTAssertThrowsError(
            try PrivateKeyFormat.normalized(key.privateText, passphrase: nil, comment: "")
        ) { error in
            XCTAssertEqual(error as? PrivateKeyFormat.ConversionError, .missingPassphrase)
        }
    }

    // MARK: - 已是 OpenSSH 格式:原样通过

    func testPassesThroughOpenSSHRSA() throws {
        let key = try GeneratedKey(mode: nil)
        let normalized = try PrivateKeyFormat.normalized(key.privateText, passphrase: nil, comment: "")

        XCTAssertFalse(normalized.converted)
        XCTAssertEqual(try publicBlob(ofRSA: normalized.text), key.publicBlob)
    }

    func testPassesThroughOpenSSHEd25519() throws {
        let key = try GeneratedKey(mode: nil, type: "ed25519")
        let normalized = try PrivateKeyFormat.normalized(key.privateText, passphrase: nil, comment: "")

        XCTAssertFalse(normalized.converted)
        XCTAssertNoThrow(try Curve25519.Signing.PrivateKey(sshEd25519: normalized.text))
    }

    /// Citadel 解析前只删 "\n",残留的 "\r" 会让首尾标记匹配失败 —— 归一化顺手修掉
    func testRepairsCRLFLineEndings() throws {
        let key = try GeneratedKey(mode: nil)
        let crlf = key.privateText.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n"

        XCTAssertThrowsError(try Insecure.RSA.PrivateKey(sshRsa: crlf), "前提:Citadel 直接吃 CRLF 会失败")
        let normalized = try PrivateKeyFormat.normalized(crlf, passphrase: nil, comment: "")
        XCTAssertEqual(try publicBlob(ofRSA: normalized.text), key.publicBlob)
    }

    // MARK: - 错误提示

    func testRejectsECDSAWithNamedError() throws {
        let key = try GeneratedKey(mode: "PEM", type: "ecdsa")
        XCTAssertThrowsError(try PrivateKeyFormat.normalized(key.privateText, passphrase: nil)) { error in
            XCTAssertEqual(error as? PrivateKeyFormat.ConversionError, .unsupportedAlgorithm("ECDSA"))
        }
    }

    /// OpenSSH 容器里的 ECDSA 能过归一化(原样放行),要到解析这步才失败 ——
    /// 那时必须还能说清是「不支持 ECDSA」,而不是笼统的「无法解析私钥文件」(issue #12)
    func testDiagnosesOpenSSHECDSA() throws {
        let key = try GeneratedKey(mode: nil, type: "ecdsa")
        let normalized = try PrivateKeyFormat.normalized(key.privateText, passphrase: nil)

        XCTAssertNil(try? Curve25519.Signing.PrivateKey(sshEd25519: normalized.text), "前提:ed25519 解析器吃不下")
        XCTAssertNil(try? Insecure.RSA.PrivateKey(sshRsa: normalized.text), "前提:RSA 解析器吃不下")
        XCTAssertEqual(
            PrivateKeyFormat.failureReason(forOpenSSH: normalized.text, passphraseProvided: false),
            .unsupportedAlgorithm("ECDSA")
        )
    }

    /// 带 passphrase 的 ed25519 口令填错:该报口令不对,而不是密钥类型不支持
    func testDiagnosesWrongPassphrase() throws {
        let key = try GeneratedKey(mode: nil, type: "ed25519", passphrase: "berth-spike")
        let normalized = try PrivateKeyFormat.normalized(key.privateText, passphrase: "wrong")

        XCTAssertNil(try? Curve25519.Signing.PrivateKey(sshEd25519: normalized.text,
                                                        decryptionKey: Data("wrong".utf8)))
        XCTAssertEqual(
            PrivateKeyFormat.failureReason(forOpenSSH: normalized.text, passphraseProvided: true),
            .wrongPassphrase
        )
    }

    func testRejectsPublicKeyWithNamedError() throws {
        let key = try GeneratedKey(mode: nil)
        XCTAssertThrowsError(try PrivateKeyFormat.normalized(key.publicLine, passphrase: nil)) { error in
            XCTAssertEqual(error as? PrivateKeyFormat.ConversionError, .publicKeyGiven)
        }
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try PrivateKeyFormat.normalized("hello world", passphrase: nil)) { error in
            XCTAssertEqual(error as? PrivateKeyFormat.ConversionError, .notAPrivateKey)
        }
    }

    func testRejectsTruncatedPEM() throws {
        let key = try GeneratedKey(mode: "PEM")
        var lines = key.privateText.split(separator: "\n").map(String.init)
        lines.removeSubrange(3..<10)  // 砍掉一段 base64,保留首尾标记
        XCTAssertThrowsError(
            try PrivateKeyFormat.normalized(lines.joined(separator: "\n"), passphrase: nil)
        ) { error in
            XCTAssertEqual(error as? PrivateKeyFormat.ConversionError, .malformedDER)
        }
    }

    /// DEK-Info 的 IV 短于块长时必须拒收 —— CCCrypt 会按块长读 IV,短 IV 是越界读
    func testRejectsTruncatedDEKInfoIV() {
        let pem = """
        -----BEGIN RSA PRIVATE KEY-----
        Proc-Type: 4,ENCRYPTED
        DEK-Info: AES-128-CBC,0102

        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        -----END RSA PRIVATE KEY-----
        """
        XCTAssertThrowsError(try PrivateKeyFormat.normalized(pem, passphrase: "x")) { error in
            XCTAssertEqual(error as? PrivateKeyFormat.ConversionError, .unsupportedPEMCipher("AES-128-CBC"))
        }
    }

    // MARK: - 辅助

    /// 从 OpenSSH 格式文本解出 RSA 私钥,回写公钥 blob(e‖n)用于和 .pub 比对
    private func publicBlob(ofRSA text: String) throws -> Data {
        let key = try Insecure.RSA.PrivateKey(sshRsa: text)
        var buffer = ByteBufferAllocator().buffer(capacity: 1024)
        _ = key.publicKey.write(to: &buffer)
        return Data(buffer.readableBytesView)
    }

    /// 用 ssh-keygen 在临时目录生成一把密钥
    private struct GeneratedKey {
        let privateText: String
        let publicLine: String
        /// .pub 里 base64 解出来的 blob,去掉开头的 "ssh-rsa" 类型串,只留 e‖n
        let publicBlob: Data

        init(mode: String?, type: String = "rsa", passphrase: String = "") throws {
            let directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("berth-keytest-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let path = directory.appendingPathComponent("id").path
            var arguments = ["-t", type, "-N", passphrase, "-C", "berth-test", "-q", "-f", path]
            if type == "rsa" { arguments += ["-b", "2048"] }
            if let mode { arguments += ["-m", mode] }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw XCTSkip("ssh-keygen 生成 \(type)/\(mode ?? "openssh") 失败")
            }

            privateText = try String(contentsOfFile: path, encoding: .utf8)
            publicLine = try String(contentsOfFile: path + ".pub", encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let fields = publicLine.split(separator: " ")
            let blob = try XCTUnwrap(Data(base64Encoded: String(fields[1])))
            // blob = string(keytype) ‖ e ‖ n,去掉首个 SSH string 后与 Citadel 的 write(to:) 对齐
            let typeLength = Int(blob.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            publicBlob = blob.dropFirst(4 + typeLength)
        }
    }
}
