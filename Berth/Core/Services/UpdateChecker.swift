import AppKit
import Foundation
import Observation

/// 检查更新。数据源只有 GitHub Releases API(请求只发给 api.github.com,无自建服务器、
/// 无遥测);Homebrew 只影响升级引导 —— Caskroom 里有 berth 就给 brew 命令,否则指向下载页。
/// 启动 5 秒后静默检查一次,之后每 24 小时一次;支持「跳过此版本」;设置页可手动检查。
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    struct AvailableUpdate: Equatable {
        /// 去掉 v 前缀的版本号,如 "1.5.0"
        let version: String
        let pageURL: URL
    }

    private(set) var available: AvailableUpdate?
    private(set) var isChecking = false
    /// 手动检查的一次性结果文案(已是最新 / 失败);发现新版时为 nil
    private(set) var manualResult: String?

    private static let apiURL = URL(string: "https://api.github.com/repos/xinghelee/Berth/releases/latest")!

    var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    /// Caskroom 里有 berth 即视为 Homebrew 安装(Apple Silicon 与 Intel 两个前缀)
    nonisolated static var installedViaHomebrew: Bool {
        FileManager.default.fileExists(atPath: "/opt/homebrew/Caskroom/berth")
            || FileManager.default.fileExists(atPath: "/usr/local/Caskroom/berth")
    }

    static let brewUpgradeCommand = "brew update && brew upgrade --cask berth"

    func startAutomaticChecks() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5)) // 不挡启动
            while !Task.isCancelled {
                if UserDefaults.standard.object(forKey: SettingsKeys.autoCheckUpdates) == nil
                    || UserDefaults.standard.bool(forKey: SettingsKeys.autoCheckUpdates) {
                    await self?.check()
                }
                try? await Task.sleep(for: .seconds(24 * 3600))
            }
        }
    }

    func check(manual: Bool = false) async {
        guard !isChecking else { return }
        isChecking = true
        manualResult = nil
        defer { isChecking = false }

        var request = URLRequest(url: Self.apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let latest = Self.parseLatestRelease(data) else {
                if manual { manualResult = String(localized: "检查失败,稍后再试。") }
                return
            }
            guard Self.isNewer(latest.version, than: currentVersion) else {
                available = nil
                if manual { manualResult = String(localized: "已是最新版本。") }
                return
            }
            let skipped = UserDefaults.standard.string(forKey: SettingsKeys.skippedUpdateVersion)
            if manual || latest.version != skipped {
                available = latest
            } else if manual {
                manualResult = String(localized: "已是最新版本。")
            }
        } catch {
            if manual { manualResult = String(localized: "检查失败:网络不可用。") }
        }
    }

    /// 跳过当前提示的版本(下个版本发布时会重新提示)
    func skip(_ update: AvailableUpdate) {
        UserDefaults.standard.set(update.version, forKey: SettingsKeys.skippedUpdateVersion)
        available = nil
    }

    func openReleasePage(_ update: AvailableUpdate) {
        NSWorkspace.shared.open(update.pageURL)
    }

    // MARK: - 纯函数(可测)

    nonisolated static func parseLatestRelease(_ data: Data) -> AvailableUpdate? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String else { return nil }
        let version = normalizedTag(tag)
        guard !version.isEmpty else { return nil }
        let page = (object["html_url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/xinghelee/Berth/releases/latest")!
        return AvailableUpdate(version: version, pageURL: page)
    }

    /// "v1.4.0" → "1.4.0"
    nonisolated static func normalizedTag(_ tag: String) -> String {
        var trimmed = tag.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("v") { trimmed.removeFirst() }
        return trimmed
    }

    /// 数字段逐段比较,段数不齐短侧补 0;预发布后缀忽略("1.5.0-beta" 按 1.5.0)
    nonisolated static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            (version.split(separator: "-").first ?? "")
                .split(separator: ".")
                .map { Int($0) ?? 0 }
        }
        let r = parts(remote)
        let l = parts(local)
        for i in 0..<max(r.count, l.count) {
            let a = i < r.count ? r[i] : 0
            let b = i < l.count ? l[i] : 0
            if a != b { return a > b }
        }
        return false
    }
}
