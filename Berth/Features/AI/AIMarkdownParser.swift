import Foundation

/// AI 回复的轻量 Markdown 分块:围栏代码块、标题、列表、引用、分隔线与正文段落。
/// 行内样式(粗体/斜体/行内代码/链接)交给 AttributedString 渲染。刻意不做表格与
/// 嵌套列表 —— 侧栏宽度放不下,保持原文比伪装成渲染更诚实;嵌套项拍平为同级。
enum AIMarkdownBlock: Equatable {
    case text(String)
    case heading(level: Int, text: String)
    case list(items: [AIListItem])
    case quote(String)
    case divider
    /// language 为围栏后的语言标记(如 bash),没有则为 nil
    case code(language: String?, code: String)
}

/// 一条列表项:marker 为渲染用的符号("•" 或原编号如 "3."),内容仍走行内渲染
struct AIListItem: Equatable {
    let marker: String
    let text: String
}

enum AIMarkdownParser {
    static func parse(_ raw: String) -> [AIMarkdownBlock] {
        var blocks: [AIMarkdownBlock] = []
        var textLines: [String] = []
        var listItems: [AIListItem] = []
        var quoteLines: [String] = []
        var codeLines: [String] = []
        var language: String?
        var inCode = false

        func flushText() {
            let text = textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.text(text)) }
            textLines = []
        }
        func flushList() {
            if !listItems.isEmpty { blocks.append(.list(items: listItems)) }
            listItems = []
        }
        func flushQuote() {
            let text = quoteLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.quote(text)) }
            quoteLines = []
        }
        func flushProse() {
            flushText()
            flushList()
            flushQuote()
        }
        func flushCode() {
            let code = codeLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !code.isEmpty { blocks.append(.code(language: language, code: code)) }
            codeLines = []
            language = nil
        }

        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCode {
                    flushCode()
                    inCode = false
                } else {
                    flushProse()
                    let marker = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    language = marker.isEmpty ? nil : marker
                    inCode = true
                }
                continue
            }
            if inCode {
                codeLines.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushProse()
            } else if let heading = headingBlock(trimmed) {
                flushProse()
                blocks.append(heading)
            } else if isDivider(trimmed) {
                flushProse()
                blocks.append(.divider)
            } else if let item = listItem(trimmed) {
                flushText()
                flushQuote()
                listItems.append(item)
            } else if trimmed.hasPrefix(">") {
                flushText()
                flushList()
                quoteLines.append(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
            } else {
                flushList()
                flushQuote()
                textLines.append(line)
            }
        }
        // 流式过程中围栏常常还没闭合,未闭合部分照样按代码块渲染
        if inCode { flushCode() } else { flushProse() }
        return blocks
    }

    // MARK: - 行分类

    /// "## 标题"(1-6 个 #,后必须跟空格,否则当正文,比如 "#标签")
    private static func headingBlock(_ line: String) -> AIMarkdownBlock? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix(while: { $0 == "#" })
        guard hashes.count <= 6 else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .heading(level: hashes.count, text: text)
    }

    /// "---" / "***" / "___"(3 个及以上同一字符)
    private static func isDivider(_ line: String) -> Bool {
        guard line.count >= 3 else { return false }
        return line.allSatisfy { $0 == "-" }
            || line.allSatisfy { $0 == "*" }
            || line.allSatisfy { $0 == "_" }
    }

    /// "- 项" / "* 项" / "+ 项" / "3. 项" / "3) 项"。
    /// 有序编号限 1-3 位数字,挡住 "2024. 全年总结" 这类年份开头的正文误判。
    private static func listItem(_ line: String) -> AIListItem? {
        if let first = line.first, "-*+".contains(first) {
            let rest = line.dropFirst()
            guard rest.first == " " else { return nil }
            let text = rest.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return AIListItem(marker: "•", text: text)
        }
        let digits = line.prefix(while: \.isNumber)
        guard (1...3).contains(digits.count) else { return nil }
        var rest = line.dropFirst(digits.count)
        guard let punctuation = rest.first, punctuation == "." || punctuation == ")" else { return nil }
        rest = rest.dropFirst()
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return AIListItem(marker: "\(digits).", text: text)
    }
}
