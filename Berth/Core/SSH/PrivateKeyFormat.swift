import CommonCrypto
import Crypto
import Foundation

/// 历史私钥格式归一化。
///
/// Citadel 只认新版 OpenSSH 容器(`-----BEGIN OPENSSH PRIVATE KEY-----`,OpenSSH 6.5 引入、
/// 7.8 起为 ssh-keygen 默认输出)。但用户手上大量私钥是老格式:
///
/// - PKCS#1(`-----BEGIN RSA PRIVATE KEY-----`):OpenSSH 7.8 之前生成的 key、`ssh-keygen -m PEM`、
///   以及几乎所有云厂商(阿里云/腾讯云等)下发的 `.pem`
/// - PKCS#8(`-----BEGIN PRIVATE KEY-----`):部分工具链导出的格式
///
/// 这里把它们解析出 RSA 参数后重新编码成 OpenSSH 容器,交回 Citadel 解析,
/// 用户无需在命令行 `ssh-keygen -p` 转换自己的文件。
enum PrivateKeyFormat {

    /// 归一化结果
    struct Normalized {
        /// OpenSSH 容器格式的私钥文本
        let text: String
        /// 转换过程中已用 passphrase 解密(结果是明文密钥),调用方不应再把 passphrase 交给解析器
        let passphraseConsumed: Bool
        /// 是否发生了格式转换(原文即 OpenSSH 格式时为 false)
        let converted: Bool
    }

    enum ConversionError: LocalizedError, Equatable {
        case notAPrivateKey
        case publicKeyGiven
        case unsupportedAlgorithm(String)
        case encryptedPKCS8
        case missingPassphrase
        case wrongPassphrase
        case unsupportedPEMCipher(String)
        case malformedDER

        var errorDescription: String? {
            switch self {
            case .notAPrivateKey:
                return String(localized: "内容里没有找到私钥。请粘贴完整的私钥文件,包含 -----BEGIN ... PRIVATE KEY----- 首尾两行。")
            case .publicKeyGiven:
                return String(localized: "这是公钥(.pub),不能用于认证。请改用对应的私钥文件(去掉 .pub 后缀的那个)。")
            case .unsupportedAlgorithm(let name):
                return String(localized: "暂不支持 \(name) 密钥。Berth 支持 OpenSSH 格式的 ed25519,以及 OpenSSH / PKCS#1 / PKCS#8 格式的 RSA。")
            case .encryptedPKCS8:
                return String(localized: "这是加密的 PKCS#8 私钥,暂不支持直接导入。请先用 `ssh-keygen -p -f <文件>` 转成 OpenSSH 格式再导入。")
            case .missingPassphrase:
                return String(localized: "这把私钥有 passphrase,请在下方一并填写。")
            case .wrongPassphrase:
                return String(localized: "passphrase 不正确,无法解密这把私钥。")
            case .unsupportedPEMCipher(let name):
                return String(localized: "私钥用了不支持的加密算法 \(name)。请先用 `ssh-keygen -p -f <文件>` 转成 OpenSSH 格式再导入。")
            case .malformedDER:
                return String(localized: "私钥内容损坏或不完整,无法解析。")
            }
        }
    }

    /// 把任意受支持格式的私钥文本转成 OpenSSH 容器格式。
    ///
    /// 已是 OpenSSH 格式的原样返回(仅做换行规整,顺带修掉 CRLF 文件导致的解析失败)。
    /// - Parameter comment: 转换时写入 OpenSSH 容器的注释字段,一般填密钥名
    static func normalized(_ text: String, passphrase: String?, comment: String = "") throws -> Normalized {
        guard let block = pemBlock(in: text) else {
            if text.contains("ssh-rsa ") || text.contains("ssh-ed25519 ") || text.contains("ecdsa-sha2-") {
                throw ConversionError.publicKeyGiven
            }
            throw ConversionError.notAPrivateKey
        }

        switch block.label {
        case "OPENSSH PRIVATE KEY":
            // Citadel 解析前会把 "\n" 全部删掉,但残留的 "\r" 会让首尾标记匹配失败
            // (Windows 换行 / 从网页复制的文本),这里统一规整一遍。
            return Normalized(text: block.canonicalText, passphraseConsumed: false, converted: false)

        case "RSA PRIVATE KEY":
            let der: Data
            var consumed = false
            if let dekInfo = block.headers["DEK-Info"] {
                guard let passphrase, !passphrase.isEmpty else { throw ConversionError.missingPassphrase }
                der = try decryptLegacyPEM(block.der, dekInfo: dekInfo, passphrase: passphrase)
                consumed = true
            } else {
                der = block.der
            }
            let rsa: RSAComponents
            do {
                rsa = try parsePKCS1(der)
            } catch {
                // 口令错时 PKCS#7 去填充大概率会失败,但约 1/256 的概率会碰巧通过,
                // 于是解出一堆乱码落到这里 —— 仍然是口令不对,别报"文件损坏"误导用户
                throw consumed ? ConversionError.wrongPassphrase : error
            }
            return Normalized(
                text: opensshContainer(rsa, comment: comment),
                passphraseConsumed: consumed,
                converted: true
            )

        case "PRIVATE KEY":
            let rsa = try parsePKCS8(block.der)
            return Normalized(
                text: opensshContainer(rsa, comment: comment),
                passphraseConsumed: false,
                converted: true
            )

        case "ENCRYPTED PRIVATE KEY":
            throw ConversionError.encryptedPKCS8

        case "EC PRIVATE KEY":
            throw ConversionError.unsupportedAlgorithm("ECDSA")

        case "DSA PRIVATE KEY":
            throw ConversionError.unsupportedAlgorithm("DSA")

        default:
            throw ConversionError.notAPrivateKey
        }
    }

    // MARK: - PEM 拆解

    private struct PEMBlock {
        let label: String
        let headers: [String: String]
        let der: Data
        /// 规整过换行的原始 PEM 文本
        let canonicalText: String
    }

    private static func pemBlock(in text: String) -> PEMBlock? {
        // 先统一换行:Swift 里 "\r\n" 是**单个** Character,直接按 "\n" 切会一刀都切不动,
        // 整个 Windows 换行的文件会被当成一行。
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard let beginIndex = lines.firstIndex(where: { $0.hasPrefix("-----BEGIN ") && $0.hasSuffix("-----") }),
              let label = lines[beginIndex]
                  .dropFirst("-----BEGIN ".count)
                  .dropLast("-----".count)
                  .trimmingCharacters(in: .whitespaces)
                  .nonEmpty,
              let endIndex = lines[beginIndex...].firstIndex(where: { $0.hasPrefix("-----END ") })
        else { return nil }

        var headers: [String: String] = [:]
        var base64 = ""
        var inHeaders = true
        for line in lines[(beginIndex + 1)..<endIndex] {
            if inHeaders {
                if line.isEmpty { inHeaders = false; continue }
                // RFC 1421 头部形如 "Proc-Type: 4,ENCRYPTED";base64 正文不含冒号
                if let colon = line.firstIndex(of: ":") {
                    let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                    let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    headers[key] = value
                    continue
                }
                inHeaders = false
            }
            base64 += line
        }

        let canonical = ([lines[beginIndex]] + lines[(beginIndex + 1)...endIndex].filter { !$0.isEmpty })
            .joined(separator: "\n")

        return PEMBlock(
            label: label,
            headers: headers,
            der: Data(base64Encoded: base64) ?? Data(),
            canonicalText: canonical
        )
    }

    // MARK: - DER 解析

    /// RSA 私钥参数(按 OpenSSH 线格式需要的字段;DER INTEGER 内容与 SSH mpint 编码规则一致,直接透传)
    struct RSAComponents {
        let modulus: [UInt8]          // n
        let publicExponent: [UInt8]   // e
        let privateExponent: [UInt8]  // d
        let prime1: [UInt8]           // p
        let prime2: [UInt8]           // q
        let coefficient: [UInt8]      // iqmp = q^-1 mod p
    }

    /// PKCS#8 PrivateKeyInfo:SEQUENCE { version, AlgorithmIdentifier, OCTET STRING(内含 PKCS#1) }
    static func parsePKCS8(_ der: Data) throws -> RSAComponents {
        var outer = DERReader(der)
        var body = DERReader(try outer.read(tag: .sequence))
        _ = try body.read(tag: .integer)                       // version
        var algorithm = DERReader(try body.read(tag: .sequence))
        let oid = try algorithm.read(tag: .objectIdentifier)
        guard oid == Self.rsaEncryptionOID else {
            throw ConversionError.unsupportedAlgorithm(algorithmName(for: oid))
        }
        return try parsePKCS1(Data(try body.read(tag: .octetString)))
    }

    /// PKCS#1 RSAPrivateKey:SEQUENCE { version, n, e, d, p, q, exp1, exp2, iqmp }
    static func parsePKCS1(_ der: Data) throws -> RSAComponents {
        var outer = DERReader(der)
        var body = DERReader(try outer.read(tag: .sequence))
        let version = try body.read(tag: .integer)
        // version 1 = multi-prime(三个以上素数),OpenSSH 线格式放不下,极罕见
        guard version == [0x00] else { throw ConversionError.malformedDER }
        let modulus = try body.read(tag: .integer)
        let publicExponent = try body.read(tag: .integer)
        let privateExponent = try body.read(tag: .integer)
        let prime1 = try body.read(tag: .integer)
        let prime2 = try body.read(tag: .integer)
        _ = try body.read(tag: .integer)  // exponent1
        _ = try body.read(tag: .integer)  // exponent2
        let coefficient = try body.read(tag: .integer)
        return RSAComponents(
            modulus: modulus,
            publicExponent: publicExponent,
            privateExponent: privateExponent,
            prime1: prime1,
            prime2: prime2,
            coefficient: coefficient
        )
    }

    private static let rsaEncryptionOID: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]

    private static func algorithmName(for oid: [UInt8]) -> String {
        switch oid {
        case [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]: return "ECDSA"
        case [0x2B, 0x65, 0x70]: return String(localized: "PKCS#8 封装的 Ed25519")
        case [0x2A, 0x86, 0x48, 0xCE, 0x38, 0x04, 0x01]: return "DSA"
        default: return String(localized: "该类型")
        }
    }

    struct DERReader {
        enum Tag: UInt8 {
            case integer = 0x02
            case octetString = 0x04
            case objectIdentifier = 0x06
            case sequence = 0x30
        }

        private let bytes: [UInt8]
        private var index = 0

        init(_ data: Data) { bytes = [UInt8](data) }
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func read(tag: Tag) throws -> [UInt8] {
            guard index < bytes.count, bytes[index] == tag.rawValue else {
                throw ConversionError.malformedDER
            }
            index += 1
            let length = try readLength()
            guard length >= 0, index + length <= bytes.count else { throw ConversionError.malformedDER }
            defer { index += length }
            return Array(bytes[index..<(index + length)])
        }

        private mutating func readLength() throws -> Int {
            guard index < bytes.count else { throw ConversionError.malformedDER }
            let first = bytes[index]
            index += 1
            guard first & 0x80 != 0 else { return Int(first) }
            let count = Int(first & 0x7F)
            // 4 字节足够表达任何现实中的密钥长度;0 是不定长(BER),DER 里不合法
            guard count > 0, count <= 4, index + count <= bytes.count else {
                throw ConversionError.malformedDER
            }
            var length = 0
            for _ in 0..<count {
                length = (length << 8) | Int(bytes[index])
                index += 1
            }
            return length
        }
    }

    // MARK: - 老式 PEM 解密(RFC 1421 + OpenSSL EVP_BytesToKey)

    private static func decryptLegacyPEM(_ der: Data, dekInfo: String, passphrase: String) throws -> Data {
        // DEK-Info: AES-128-CBC,3F2A...(IV 十六进制)
        let parts = dekInfo.split(separator: ",", maxSplits: 1).map(String.init)
        let cipherName = parts.first?.uppercased() ?? ""
        guard parts.count == 2, let iv = hexBytes(parts[1]) else {
            throw ConversionError.unsupportedPEMCipher(cipherName)
        }

        let algorithm: CCAlgorithm
        let keyLength: Int
        let blockSize: Int
        switch cipherName {
        case "AES-128-CBC": algorithm = CCAlgorithm(kCCAlgorithmAES); keyLength = 16; blockSize = kCCBlockSizeAES128
        case "AES-192-CBC": algorithm = CCAlgorithm(kCCAlgorithmAES); keyLength = 24; blockSize = kCCBlockSizeAES128
        case "AES-256-CBC": algorithm = CCAlgorithm(kCCAlgorithmAES); keyLength = 32; blockSize = kCCBlockSizeAES128
        case "DES-EDE3-CBC": algorithm = CCAlgorithm(kCCAlgorithm3DES); keyLength = 24; blockSize = kCCBlockSize3DES
        default: throw ConversionError.unsupportedPEMCipher(cipherName)
        }
        // CCCrypt 会按块长从 IV 指针读满一块,短 IV 会越界读
        guard iv.count == blockSize else { throw ConversionError.unsupportedPEMCipher(cipherName) }

        // OpenSSL 的 EVP_BytesToKey:MD5,1 轮,盐取 IV 前 8 字节
        let salt = Array(iv.prefix(8))
        var key: [UInt8] = []
        var digest: [UInt8] = []
        while key.count < keyLength {
            var md5 = Insecure.MD5()
            md5.update(data: digest)
            md5.update(data: Data(passphrase.utf8))
            md5.update(data: salt)
            digest = Array(md5.finalize())
            key += digest
        }
        key = Array(key.prefix(keyLength))

        var output = [UInt8](repeating: 0, count: der.count + kCCBlockSizeAES128)
        var moved = 0
        let status = der.withUnsafeBytes { input in
            CCCrypt(
                CCOperation(kCCDecrypt),
                algorithm,
                CCOptions(kCCOptionPKCS7Padding),
                key, key.count,
                iv,
                input.baseAddress, der.count,
                &output, output.count,
                &moved
            )
        }
        // passphrase 不对时 PKCS#7 去填充几乎必然失败(kCCAlignmentError/kCCDecodeError)
        guard status == CCCryptorStatus(kCCSuccess) else { throw ConversionError.wrongPassphrase }
        return Data(output.prefix(moved))
    }

    private static func hexBytes(_ string: String) -> [UInt8]? {
        let characters = Array(string.trimmingCharacters(in: .whitespaces))
        guard characters.count % 2 == 0, !characters.isEmpty else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(characters.count / 2)
        for pair in stride(from: 0, to: characters.count, by: 2) {
            guard let byte = UInt8(String(characters[pair...(pair + 1)]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        return bytes
    }

    // MARK: - OpenSSH 容器编码

    /// 按 openssh-key-v1 布局重新编码(cipher/kdf 均为 none,即明文私钥)。
    /// 参考 https://dnaeon.github.io/openssh-private-key-binary-format/
    static func opensshContainer(_ rsa: RSAComponents, comment: String) -> String {
        var publicBlob = Data()
        publicBlob.appendSSHString(Data("ssh-rsa".utf8))
        publicBlob.appendSSHMPInt(rsa.publicExponent)
        publicBlob.appendSSHMPInt(rsa.modulus)

        var privateBlob = Data()
        // check1 == check2:解密成功的自校验字段
        let check = UInt32.random(in: 0...UInt32.max)
        privateBlob.appendSSHUInt32(check)
        privateBlob.appendSSHUInt32(check)
        privateBlob.appendSSHString(Data("ssh-rsa".utf8))
        // 注意顺序与公钥块不同:私钥块是 n, e, d, iqmp, p, q
        privateBlob.appendSSHMPInt(rsa.modulus)
        privateBlob.appendSSHMPInt(rsa.publicExponent)
        privateBlob.appendSSHMPInt(rsa.privateExponent)
        privateBlob.appendSSHMPInt(rsa.coefficient)
        privateBlob.appendSSHMPInt(rsa.prime1)
        privateBlob.appendSSHMPInt(rsa.prime2)
        privateBlob.appendSSHString(Data(comment.utf8))
        // 填充到块大小(cipher none 时为 8),内容是 1,2,3…
        var padding: UInt8 = 1
        while privateBlob.count % 8 != 0 {
            privateBlob.append(padding)
            padding += 1
        }

        var blob = Data("openssh-key-v1".utf8)
        blob.append(0x00)
        blob.appendSSHString(Data("none".utf8))  // ciphername
        blob.appendSSHString(Data("none".utf8))  // kdfname
        blob.appendSSHString(Data())             // kdfoptions
        blob.appendSSHUInt32(1)                  // 密钥数量
        blob.appendSSHString(publicBlob)
        blob.appendSSHString(privateBlob)

        let base64 = blob.base64EncodedString()
        let wrapped = stride(from: 0, to: base64.count, by: 70).map { offset -> String in
            let start = base64.index(base64.startIndex, offsetBy: offset)
            let end = base64.index(start, offsetBy: min(70, base64.count - offset))
            return String(base64[start..<end])
        }
        return ([
            "-----BEGIN OPENSSH PRIVATE KEY-----"
        ] + wrapped + [
            "-----END OPENSSH PRIVATE KEY-----"
        ]).joined(separator: "\n")
    }
}

private extension Data {
    mutating func appendSSHUInt32(_ value: UInt32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendSSHString(_ payload: Data) {
        appendSSHUInt32(UInt32(payload.count))
        append(payload)
    }

    /// SSH mpint:大端、最短编码、最高位为 1 时补前导 0x00(与 DER INTEGER 规则一致)
    mutating func appendSSHMPInt(_ bytes: [UInt8]) {
        var value = bytes
        while value.count > 1 && value[0] == 0x00 && value[1] & 0x80 == 0 {
            value.removeFirst()
        }
        if value == [0x00] { value = [] }
        if let first = value.first, first & 0x80 != 0 {
            value.insert(0x00, at: 0)
        }
        appendSSHString(Data(value))
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
