import Foundation

/// AI 回复的轻量 Markdown 分块:围栏代码块、标题、列表、引用、分隔线、GFM 表格与正文段落。
/// 行内样式(粗体/斜体/行内代码/链接)交给 AttributedString 渲染。嵌套列表拍平为同级。
enum AIMarkdownBlock: Equatable {
    case text(String)
    case heading(level: Int, text: String)
    case list(items: [AIListItem])
    case quote(String)
    case divider
    case table(AIMarkdownTable)
    /// language 为围栏后的语言标记(如 bash),没有则为 nil
    case code(language: String?, code: String)
}

/// 一条列表项:marker 为渲染用的符号("•" 或原编号如 "3."),内容仍走行内渲染
struct AIListItem: Equatable {
    let marker: String
    let text: String
}

enum AITableAlignment: Equatable {
    case leading
    case center
    case trailing
}

struct AIMarkdownTable: Equatable {
    let headers: [String]
    let alignments: [AITableAlignment]
    let rows: [[String]]
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

        let lines = raw.components(separatedBy: .newlines)
        var index = 0
        while index < lines.count {
            let line = lines[index]
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
                index += 1
                continue
            }
            if inCode {
                codeLines.append(line)
                index += 1
                continue
            }

            if let (table, consumed) = tableBlock(in: lines, startingAt: index) {
                flushProse()
                blocks.append(.table(table))
                index += consumed
                continue
            } else if trimmed.isEmpty {
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
            index += 1
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

    // MARK: - GFM 表格

    /// 表头下一行必须是 `---` / `:---:` / `---:` 组成的分隔行。
    /// 数据行列数不足时补空格,多出的列忽略,以保持流式回复中的网格稳定。
    private static func tableBlock(
        in lines: [String],
        startingAt start: Int
    ) -> (AIMarkdownTable, Int)? {
        guard start + 1 < lines.count,
              let headers = tableCells(lines[start]),
              headers.count >= 2,
              let alignments = tableAlignments(lines[start + 1]),
              headers.count == alignments.count
        else { return nil }

        var rows: [[String]] = []
        var cursor = start + 2
        while cursor < lines.count {
            guard !lines[cursor].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let cells = tableCells(lines[cursor])
            else { break }

            let clipped = Array(cells.prefix(headers.count))
            rows.append(clipped + Array(repeating: "", count: headers.count - clipped.count))
            cursor += 1
        }

        return (
            AIMarkdownTable(headers: headers, alignments: alignments, rows: rows),
            cursor - start
        )
    }

    private static func tableAlignments(_ line: String) -> [AITableAlignment]? {
        guard let cells = tableCells(line), cells.count >= 2 else { return nil }
        var result: [AITableAlignment] = []
        for cell in cells {
            var marker = cell.trimmingCharacters(in: .whitespaces)
            let leadingColon = marker.first == ":"
            if leadingColon { marker.removeFirst() }
            let trailingColon = marker.last == ":"
            if trailingColon { marker.removeLast() }
            guard marker.count >= 3, marker.allSatisfy({ $0 == "-" }) else { return nil }
            switch (leadingColon, trailingColon) {
            case (true, true): result.append(.center)
            case (false, true): result.append(.trailing)
            default: result.append(.leading)
            }
        }
        return result
    }

    /// 按未转义、且不在行内代码中的 `|` 拆列;支持有/无首尾竖线两种 GFM 写法。
    private static func tableCells(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }

        var cells: [String] = []
        var current = ""
        var escaped = false
        var inCode = false
        var separators = 0

        for character in trimmed {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                current.append(character)
                escaped = true
            } else if character == "`" {
                current.append(character)
                inCode.toggle()
            } else if character == "|", !inCode {
                cells.append(current)
                current = ""
                separators += 1
            } else {
                current.append(character)
            }
        }
        cells.append(current)

        guard separators > 0 else { return nil }
        if trimmed.hasPrefix("|"), cells.first?.isEmpty == true { cells.removeFirst() }
        if hasUnescapedTrailingPipe(trimmed), cells.last?.isEmpty == true { cells.removeLast() }
        let result = cells.map { $0.trimmingCharacters(in: .whitespaces) }
        return result.isEmpty ? nil : result
    }

    private static func hasUnescapedTrailingPipe(_ line: String) -> Bool {
        guard line.last == "|" else { return false }
        let precedingBackslashes = line.dropLast().reversed().prefix(while: { $0 == "\\" }).count
        return precedingBackslashes.isMultiple(of: 2)
    }
}

/// 围栏内容有时只是 AI 为保持对齐而包起来的表格,这类内容不能显示“发送到终端”。
enum AICodeBlockClassifier {
    static func looksLikeTable(_ code: String) -> Bool {
        let lines = code.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else { return false }

        let hasASCIIBorder = lines.contains { line in
            let plusCount = line.filter { $0 == "+" }.count
            return plusCount >= 2 && line.allSatisfy { "+-=:.".contains($0) }
        }
        let hasPipeRow = lines.contains { $0.filter { $0 == "|" }.count >= 2 }
        if hasASCIIBorder && hasPipeRow { return true }

        let boxBorderCharacters = CharacterSet(charactersIn: "┌┬┐├┼┤└┴┘─╭╮╰╯╔╦╗╠╬╣╚╩╝═")
        let hasUnicodeBorder = lines.contains { line in
            line.unicodeScalars.contains { boxBorderCharacters.contains($0) }
        }
        let hasUnicodeRow = lines.contains { $0.contains("│") || $0.contains("║") }
        if hasUnicodeBorder && hasUnicodeRow { return true }

        if lines.contains(where: isMarkdownTableSeparator) { return true }
        if lines.contains(where: isWhitespaceTableSeparator) { return true }

        // 无分隔行的数据库/命令输出:至少三行且竖线数量稳定,避免把一两条 shell 管道误判成表格。
        let pipeCounts = lines.map { $0.filter { $0 == "|" }.count }
        if pipeCounts.count >= 3,
           let first = pipeCounts.first,
           first > 0,
           pipeCounts.allSatisfy({ $0 == first }) {
            return true
        }
        return false
    }

    private static func isMarkdownTableSeparator(_ line: String) -> Bool {
        guard line.contains("|") else { return false }
        let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "| "))
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard cells.count >= 2 else { return false }
        return cells.allSatisfy { cell in
            let marker = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return marker.count >= 3 && marker.allSatisfy { $0 == "-" }
        }
    }

    private static func isWhitespaceTableSeparator(_ line: String) -> Bool {
        let columns = line.split(whereSeparator: \.isWhitespace)
        guard columns.count >= 2 else { return false }
        return columns.allSatisfy { column in
            column.count >= 2 && column.allSatisfy { $0 == "-" }
        }
    }
}
