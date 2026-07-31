import Foundation

/// AI 回复的极简 Markdown 分段:只区分正文与围栏代码块(```),正文交给
/// AttributedString 的行内 Markdown 渲染,代码块单独出卡片(可复制/发送到终端)。
enum AIMarkdownBlock: Equatable {
    case text(String)
    /// language 为围栏后的语言标记(如 bash),没有则为 nil
    case code(language: String?, code: String)
}

enum AIMarkdownParser {
    static func parse(_ raw: String) -> [AIMarkdownBlock] {
        var blocks: [AIMarkdownBlock] = []
        var textLines: [String] = []
        var codeLines: [String] = []
        var language: String?
        var inCode = false

        func flushText() {
            let text = textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.text(text)) }
            textLines = []
        }
        func flushCode() {
            let code = codeLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !code.isEmpty { blocks.append(.code(language: language, code: code)) }
            codeLines = []
            language = nil
        }

        for line in raw.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    flushCode()
                    inCode = false
                } else {
                    flushText()
                    let marker = line.trimmingCharacters(in: .whitespaces).dropFirst(3)
                        .trimmingCharacters(in: .whitespaces)
                    language = marker.isEmpty ? nil : marker
                    inCode = true
                }
                continue
            }
            if inCode { codeLines.append(line) } else { textLines.append(line) }
        }
        // 流式过程中围栏常常还没闭合,未闭合部分照样按代码块渲染
        if inCode { flushCode() } else { flushText() }
        return blocks
    }
}
