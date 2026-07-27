import Foundation
import Network
import os

/// macOS 15 起,访问同网段地址要过「隐私与安全性 › 本地网络」这道门禁。
///
/// 麻烦之处在于**只有 Network.framework 发起的连接会触发授权请求**。Citadel/NIO 用的是
/// BSD socket,被拦下时内核只返回 EHOSTUNREACH —— 系统既不弹授权框,也不会把 Berth
/// 列进设置里的本地网络列表,用户连打开开关的机会都没有,看到的只是「没有到主机的路由」,
/// 和网线没插长得一模一样。
///
/// 因此:**只在真撞上这个错误时**才用 NWConnection 朝同一地址探一下,把授权请求逼出来。
/// 局域网本来就通的用户不会平白看到弹窗;被挡住的用户点「允许」后连接会自动重试一次。
enum LocalNetworkAccess {
    /// 已经请求过且没拿到授权的地址:别在每次重试时都白等一次超时
    private static let refused = OSAllocatedUnfairLock(initialState: Set<String>())

    /// 没授权时连接会停在 .waiting,系统同时弹出授权框。这个窗口必须留够:
    /// 一旦提前 cancel,请求就撤销了,框也跟着消失。用户点得快就自动重连成功,
    /// 点得慢也不影响 —— 授权已经记下,手动重连即可
    private static let timeout: TimeInterval = 10

    /// 这个错误像不像「局域网地址被系统门禁挡了」
    static func isLikelyBlocked(_ error: Error, host: String) -> Bool {
        guard SSHErrorMapper.isLocalNetworkAddress(host) else { return false }
        let raw = String(describing: error).lowercased()
        return raw.contains("no route to host")
            || raw.contains("network is unreachable")
            || raw.contains("host is down")
    }

    /// 发起一次 Network.framework 连接以触发授权请求。
    /// 返回 true 表示这条路现在通了(授权已给),调用方可以重试真正的 SSH 连接。
    static func requestAccess(host: String, port: Int) async -> Bool {
        let token = "\(host):\(port)"
        let alreadyRefused = refused.withLock { $0.contains(token) }
        guard !alreadyRefused else { return false }

        DebugLog.append("localnet: probing \(token) to raise the authorization prompt")
        let granted = await probe(host: host, port: port)
        DebugLog.append("localnet: probe \(token) granted=\(granted)")
        if !granted {
            refused.withLock { $0.insert(token) }
        }
        return granted
    }

    private static func probe(host: String, port: Int) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(exactly: port) ?? 22) else { return false }
        let connection = NWConnection(
            to: .hostPort(host: NWEndpoint.Host(host), port: nwPort),
            using: .tcp
        )
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let finished = OSAllocatedUnfairLock(initialState: false)
            let finish: (Bool) -> Void = { result in
                let wasFinished = finished.withLock { done -> Bool in
                    defer { done = true }
                    return done
                }
                guard !wasFinished else { return }
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                DebugLog.append("localnet: probe state \(String(describing: state))")
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                // .waiting 恰恰是系统在弹授权框的时刻,这里绝不能收工:
                // 提前 cancel 会把授权请求一起撤掉,用户根本看不到框
                default: break
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { finish(false) }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }
}
