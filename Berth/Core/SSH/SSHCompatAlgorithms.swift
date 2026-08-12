import Citadel
import Crypto

extension SSHAlgorithms {
    /// 老式服务器/堡垒机兼容(issue #12):在 nio-ssh 默认的现代算法(curve25519/ECDH KEX、
    /// AES-GCM、ed25519/ECDSA host key)之外追加:
    /// - KEX:diffie-hellman-group14-sha256 / -sha1(阿里云等堡垒机常只支持 DH)
    /// - 加密:aes128-ctr(不支持 GCM 的老 sshd)
    /// - host key:RSA(rsa-sha2-512/256 + 遗留 ssh-rsa,vendor 补丁提供验签)
    /// `.add` 是追加,现代算法仍排在前:对端两边都支持时永远优先选新算法。
    static let berthCompatibility: SSHAlgorithms = {
        var algorithms = SSHAlgorithms()
        algorithms.keyExchangeAlgorithms = .add([
            DiffieHellmanGroup14Sha256.self,
            DiffieHellmanGroup14Sha1.self,
        ])
        algorithms.transportProtectionSchemes = .add([
            AES128CTR.self,
        ])
        algorithms.publicKeyAlgorihtms = .add([
            (Insecure.RSA.PublicKey.self, Insecure.RSA.Signature.self),
        ])
        return algorithms
    }()
}
