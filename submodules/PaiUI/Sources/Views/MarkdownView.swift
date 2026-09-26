import SwiftUI

/// Markdown as blocks: headings, lists, quotes, fenced code, rules and paragraphs, with the
/// inline syntax (bold, italic, code, links) left to the system parser. Enough for CLAUDE.md,
/// memory files and skills; not a full renderer.
@available(iOS 16.0, *)
struct MarkdownView: View {
    let text: String

    private enum Block: Identifiable {
        case heading(Int, String)
        case paragraph(String)
        case bullet(Int, String, ordered: String?)
        case quote(String)
        case code(String, lang: String?)
        case rule
        case table([[String]])

        var id: String {
            switch self {
            case let .heading(level, text): return "h\(level):\(text)"
            case let .paragraph(text): return "p:\(text)"
            case let .bullet(depth, text, ordered): return "b\(depth):\(ordered ?? ""):\(text)"
            case let .quote(text): return "q:\(text)"
            case let .code(text, _): return "c:\(text)"
            case .rule: return "rule"
            case let .table(rows): return "t:\(rows.flatMap { $0 }.joined(separator: "|"))"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, block in
                view(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(_ block: Block) -> some View {
        switch block {
        case let .heading(level, text):
            inline(text)
                .font(level == 1 ? .title2.weight(.bold) : level == 2 ? .title3.weight(.semibold) : .headline)
                .padding(.top, level <= 2 ? 6 : 2)
        case let .paragraph(text):
            inline(text).font(.callout)
        case let .bullet(depth, text, ordered):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(ordered.map { "\($0)." } ?? "•").font(.callout).foregroundStyle(.secondary).frame(minWidth: 14, alignment: .trailing)
                inline(text).font(.callout)
            }
            .padding(.leading, CGFloat(depth) * 16)
        case let .quote(text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.5)).frame(width: 3)
                inline(text).font(.callout).foregroundStyle(.secondary)
            }
        case let .code(text, _):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(.paiMono).textSelection(.enabled).padding(10)
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .rule:
            Divider()
        case let .table(rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                inline(cell).font(index == 0 ? .footnote.weight(.semibold) : .footnote)
                            }
                        }
                        if index == 0 { Divider() }
                    }
                }
                .padding(8)
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    /// Inline markdown through the system parser; text that does not parse shows as it is.
    private func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }

    private static func parse(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        var codeLang: String?
        var table: [[String]] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
        }
        func flushTable() {
            if !table.isEmpty {
                blocks.append(.table(table))
                table = []
            }
        }

        for rawLine in source.components(separatedBy: "\n") {
            let line = rawLine.replacingOccurrences(of: "\r", with: "")
            if var code_ = code {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    blocks.append(.code(code_.joined(separator: "\n"), lang: codeLang))
                    code = nil
                } else {
                    code_.append(line)
                    code = code_
                }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flushParagraph(); flushTable()
                code = []
                let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                codeLang = lang.isEmpty ? nil : lang
                continue
            }
            if trimmed.isEmpty {
                flushParagraph(); flushTable()
                continue
            }
            if trimmed.hasPrefix("|") {
                flushParagraph()
                let cells = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                // The separator row under the header is markup, not data.
                if cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0 == "-" || $0 == ":" } }) { continue }
                table.append(cells)
                continue
            }
            flushTable()
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.rule)
                continue
            }
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix { $0 == "#" }.count
                if level <= 6, trimmed.dropFirst(level).first == " " {
                    flushParagraph()
                    blocks.append(.heading(level, String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)))
                    continue
                }
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
                continue
            }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            let depth = indent / 2
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                blocks.append(.bullet(depth, String(trimmed.dropFirst(2)), ordered: nil))
                continue
            }
            if let dot = trimmed.firstIndex(of: "."), trimmed[..<dot].allSatisfy(\.isNumber), !trimmed[..<dot].isEmpty, trimmed[trimmed.index(after: dot)...].hasPrefix(" ") {
                flushParagraph()
                blocks.append(.bullet(depth, String(trimmed[trimmed.index(after: dot)...]).trimmingCharacters(in: .whitespaces), ordered: String(trimmed[..<dot])))
                continue
            }
            paragraph.append(trimmed)
        }
        if let code_ = code { blocks.append(.code(code_.joined(separator: "\n"), lang: codeLang)) }
        flushParagraph(); flushTable()
        return blocks
    }
}
