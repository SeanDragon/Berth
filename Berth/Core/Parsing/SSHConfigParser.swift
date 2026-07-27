import Foundation

/// ~/.ssh/config 中一个可导入的主机(具体别名,非通配模式)
struct SSHConfigHost: Equatable, Identifiable {
    var alias: String
    var hostname: String
    var user: String?
    var port: Int?
    var identityFile: String?
    var proxyJump: String?
    /// PubkeyAuthentication no 或 PreferredAuthentications 不含 publickey 时为 true
    var prefersPasswordAuth: Bool = false

    var id: String { alias }
}

/// 解析 ~/.ssh/config 时遇到的、值得告诉用户的情况。
/// 刻意不做成「错误」:config 是用户的文件,Berth 只是读不懂其中一部分,
/// 首次导入引导里一次性列出即可,不逐条弹窗。
struct SSHConfigIssue: Identifiable, Equatable {
    enum Kind: Equatable {
        /// 文件存在但读不出来(编码/权限)
        case unreadable(String)
        /// Include 指令未展开,被 include 的主机不会出现在列表里
        case includeNotExpanded(String)
        /// Match 块整体跳过
        case matchBlockSkipped(String)
        /// Host 行后面没跟别名
        case hostWithoutAlias
        /// Port 不是数字,回落到 22
        case invalidPort(String)
        /// 同一别名被定义多次,按 ssh 语义以先出现的为准
        case duplicateAlias(String)
    }

    var kind: Kind
    /// 1-based 行号;文件级问题为 nil
    var line: Int?

    var id: String { "\(line ?? 0):\(summary)" }

    /// 一行人话,直接进 UI
    var summary: String {
        switch kind {
        case .unreadable(let reason):
            return String(localized: "读取失败:\(reason)")
        case .includeNotExpanded(let value):
            return String(localized: "Include \(value) 未展开,其中的主机不会出现在列表里")
        case .matchBlockSkipped(let value):
            return String(localized: "Match \(value) 块已跳过,其中的设置不会生效")
        case .hostWithoutAlias:
            return String(localized: "Host 后面没有别名,该块被忽略")
        case .invalidPort(let value):
            return String(localized: "Port \(value) 不是有效端口,按 22 处理")
        case .duplicateAlias(let alias):
            return String(localized: "别名 \(alias) 重复定义,按先出现的一份处理")
        }
    }
}

/// 一次解析的完整产物:能用的主机 + 读不懂的地方
struct SSHConfigParseResult {
    var hosts: [SSHConfigHost] = []
    var issues: [SSHConfigIssue] = []
}

/// ssh_config 解析器。支持 Host 多别名与通配(*、?、! 取反)、
/// HostName / User / Port / IdentityFile(~ 展开)/ ProxyJump,
/// 参数语义与 ssh 一致:每个参数取「第一次出现」的值。
/// Match 块与 Include 指令暂不支持 —— 跳过,并记进 `SSHConfigIssue` 由 UI 告知用户。
enum SSHConfigParser {

    struct Block {
        var patterns: [String]
        var options: [(key: String, value: String, line: Int)] = []
    }

    static func parse(_ text: String, homeDirectory: String = NSHomeDirectory()) -> [SSHConfigHost] {
        parseDetailed(text, homeDirectory: homeDirectory).hosts
    }

    static func parseDetailed(_ text: String, homeDirectory: String = NSHomeDirectory()) -> SSHConfigParseResult {
        var issues: [SSHConfigIssue] = []
        let blocks = parseBlocks(text, issues: &issues)

        // 具体别名 = 不含通配符、非取反的 pattern
        var aliases: [String] = []
        var seen = Set<String>()
        for block in blocks {
            for pattern in block.patterns
            where !pattern.contains("*") && !pattern.contains("?") && !pattern.hasPrefix("!") {
                if seen.insert(pattern).inserted {
                    aliases.append(pattern)
                } else {
                    issues.append(SSHConfigIssue(kind: .duplicateAlias(pattern), line: nil))
                }
            }
        }

        let hosts = aliases.map { alias -> SSHConfigHost in
            var host = SSHConfigHost(alias: alias, hostname: alias)
            var assigned = Set<String>()

            for block in blocks where matches(alias: alias, patterns: block.patterns) {
                for (key, value, line) in block.options where !assigned.contains(key) {
                    assigned.insert(key)
                    switch key {
                    case "hostname":
                        host.hostname = value
                    case "user":
                        host.user = value
                    case "port":
                        if let port = Int(value), (1...65535).contains(port) {
                            host.port = port
                        } else {
                            issues.append(SSHConfigIssue(kind: .invalidPort(value), line: line))
                        }
                    case "identityfile":
                        host.identityFile = expandTilde(value, home: homeDirectory)
                    case "proxyjump":
                        host.proxyJump = value
                    case "pubkeyauthentication":
                        if value.lowercased() == "no" { host.prefersPasswordAuth = true }
                    case "preferredauthentications":
                        if !value.lowercased().contains("publickey") { host.prefersPasswordAuth = true }
                    default:
                        break
                    }
                }
            }
            return host
        }

        // 同一条重复提示只留一份(通配块里的 Port 会被每个别名各报一次)
        var deduped: [SSHConfigIssue] = []
        for issue in issues where !deduped.contains(issue) { deduped.append(issue) }
        return SSHConfigParseResult(hosts: hosts, issues: deduped)
    }

    static func parseFile(at path: String) -> [SSHConfigHost] {
        parseFileDetailed(at: path).hosts
    }

    /// 文件不存在不算问题(还没写过 config 的新用户),返回空结果
    static func parseFileDetailed(at path: String) -> SSHConfigParseResult {
        guard FileManager.default.fileExists(atPath: path) else { return SSHConfigParseResult() }
        do {
            return parseDetailed(try String(contentsOfFile: path, encoding: .utf8))
        } catch {
            // 不是 UTF-8:让系统猜一次编码,再不行才作为问题上报
            var encoding = String.Encoding.utf8
            if let text = try? String(contentsOfFile: path, usedEncoding: &encoding) {
                return parseDetailed(text)
            }
            return SSHConfigParseResult(
                issues: [SSHConfigIssue(kind: .unreadable(error.localizedDescription), line: nil)]
            )
        }
    }

    // MARK: - 内部

    private static func parseBlocks(_ text: String, issues: inout [SSHConfigIssue]) -> [Block] {
        var blocks: [Block] = []
        var current: Block?
        var inUnsupportedMatchBlock = false

        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let lineNumber = index + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            // 行内注释:ssh_config 不支持行内 #,保守起见不剥离(路径可能含 #)

            let (key, value) = splitKeyValue(line)
            guard !key.isEmpty else { continue }

            switch key {
            case "host":
                if let block = current { blocks.append(block) }
                let patterns = splitPatterns(value)
                current = patterns.isEmpty ? nil : Block(patterns: patterns)
                // 无别名的 Host 块整体作废,块内选项别漏进全局 Host *
                inUnsupportedMatchBlock = patterns.isEmpty
                if patterns.isEmpty {
                    issues.append(SSHConfigIssue(kind: .hostWithoutAlias, line: lineNumber))
                }
            case "match":
                if let block = current { blocks.append(block) }
                current = nil
                inUnsupportedMatchBlock = true
                issues.append(SSHConfigIssue(kind: .matchBlockSkipped(value), line: lineNumber))
            case "include":
                issues.append(SSHConfigIssue(kind: .includeNotExpanded(value), line: lineNumber))
            default:
                guard !inUnsupportedMatchBlock else { continue }
                if current == nil {
                    // 文件顶部、任何 Host 块之前的全局参数,等价于 Host *
                    current = Block(patterns: ["*"])
                }
                current?.options.append((key, value, lineNumber))
            }
        }
        if let block = current { blocks.append(block) }
        return blocks
    }

    /// `Key Value` 或 `Key=Value`,key 大小写不敏感,value 保留原样(去外层引号)
    private static func splitKeyValue(_ line: String) -> (String, String) {
        let separators = CharacterSet(charactersIn: " \t=")
        guard let range = line.rangeOfCharacter(from: separators) else {
            return (line.lowercased(), "")
        }
        let key = String(line[..<range.lowerBound]).lowercased()
        var value = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        if line[range.lowerBound] != "=" , value.hasPrefix("=") {
            value = String(value.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        return (key, value)
    }

    private static func splitPatterns(_ value: String) -> [String] {
        value
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { pattern in
                var text = String(pattern)
                if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
                    text = String(text.dropFirst().dropLast())
                }
                return text
            }
            .filter { !$0.isEmpty }
    }

    /// ssh 语义:取反 pattern 命中即整块不适用;否则任一正向 pattern 命中即适用
    static func matches(alias: String, patterns: [String]) -> Bool {
        var matched = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                if wildcardMatch(alias, pattern: String(pattern.dropFirst())) {
                    return false
                }
            } else if wildcardMatch(alias, pattern: pattern) {
                matched = true
            }
        }
        return matched
    }

    /// * 匹配任意串,? 匹配单个字符
    static func wildcardMatch(_ text: String, pattern: String) -> Bool {
        let textChars = Array(text)
        let patternChars = Array(pattern)

        var dp = Array(
            repeating: Array(repeating: false, count: patternChars.count + 1),
            count: textChars.count + 1
        )
        dp[0][0] = true
        for p in 1...max(patternChars.count, 1) where patternChars.count >= p {
            if patternChars[p - 1] == "*" { dp[0][p] = dp[0][p - 1] }
        }
        guard !patternChars.isEmpty else { return textChars.isEmpty }

        for t in 1...max(textChars.count, 1) where textChars.count >= t {
            for p in 1...patternChars.count {
                let pc = patternChars[p - 1]
                if pc == "*" {
                    dp[t][p] = dp[t - 1][p] || dp[t][p - 1]
                } else if pc == "?" || pc == textChars[t - 1] {
                    dp[t][p] = dp[t - 1][p - 1]
                }
            }
        }
        return dp[textChars.count][patternChars.count]
    }

    private static func expandTilde(_ path: String, home: String) -> String {
        guard path.hasPrefix("~") else { return path }
        if path == "~" { return home }
        if path.hasPrefix("~/") {
            return home + String(path.dropFirst(1))
        }
        return path
    }
}
