import SwiftUI

extension Color {
    /// One accent for "needs you", one for dictation; running uses the app accent.
    static let paiWaiting = Color(red: 0.93, green: 0.62, blue: 0.10)
    static let paiRecording = Color(red: 0.90, green: 0.25, blue: 0.30)
    static let paiIdle = Color.secondary.opacity(0.55)
}

extension Font {
    static let paiMono = Font.system(.footnote, design: .monospaced)
    static let paiMonoSmall = Font.system(.caption, design: .monospaced)
}

/// The state dot: filled and breathing while busy, amber ring while waiting on you, hollow otherwise —
/// a thread's or an agent's activity read the same way.
@available(iOS 16.0, *)
struct StateDot: View {
    let waiting: Bool
    let busy: Bool

    var body: some View {
        Group {
            if waiting {
                Circle().strokeBorder(Color.paiWaiting, lineWidth: 2.5)
            } else if busy {
                Circle().fill(Color.accentColor).modifier(Breathing())
            } else {
                Circle().fill(Color.paiIdle)
            }
        }
        .frame(width: 10, height: 10)
    }
}

/// Opacity that breathes while something runs; still when the system asks for less motion.
@available(iOS 16.0, *)
struct Breathing: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false

    func body(content: Content) -> some View {
        content
            .opacity(reduceMotion ? 1 : (on ? 1 : 0.35))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

/// Where a tool line came from, by the daemon's summary shape.
@available(iOS 16.0, *)
enum ToolGlyph {
    static func symbol(for name: String, summary: String) -> String {
        if summary.hasPrefix("$ ") { return "terminal" }
        switch name {
        case "Bash": return "terminal"
        case "Read": return "doc.text"
        case "Edit", "Write", "NotebookEdit": return "pencil.line"
        case "Grep", "Glob": return "magnifyingglass"
        case "WebSearch", "WebFetch": return "globe"
        case "Agent", "Task": return "person.2"
        case "AskUserQuestion": return "questionmark.bubble"
        default: return name.hasPrefix("mcp__") || summary.contains(":") ? "puzzlepiece" : "wrench"
        }
    }
}

extension Date {
    /// "3m", "2h", "yesterday" — the shortest honest age.
    var paiAge: String {
        let seconds = Int(-timeIntervalSinceNow)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        if seconds < 172800 { return "yesterday" }
        return "\(seconds / 86400)d"
    }
}

/// Markdown when it parses, plain text when it does not.
@available(iOS 16.0, *)
struct MarkdownText: View {
    let text: String
    var body: some View {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attributed)
        } else {
            Text(text)
        }
    }
}

extension String {
    /// A one-line preview: markdown marks and line breaks out.
    var paiPlain: String {
        replacingOccurrences(of: "[*_`#>]+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// The text with its links tappable: markdown links as written, and bare urls turned into
    /// links first, since the system parser only reads the bracketed form. Anything that fails to
    /// parse comes back as plain text rather than disappearing.
    var paiLinked: AttributedString {
        let source = Self.autolinked(self)
        if let attributed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) { return attributed }
        return AttributedString(self)
    }

    /// Bare `https://…` runs rewritten as `[url](url)`, leaving the ones already inside a markdown link alone.
    private static func autolinked(_ text: String) -> String {
        let pattern = "(\\]\\()?(https?://[^\\s<>\")\\]]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let full = NSRange(text.startIndex..., in: text)
        var out = ""
        var cursor = text.startIndex
        for match in regex.matches(in: text, range: full) {
            guard let range = Range(match.range, in: text), let urlRange = Range(match.range(at: 2), in: text) else { continue }
            // `](` before it means the url is already a markdown link's target.
            if match.range(at: 1).length > 0 { continue }
            let url = String(text[urlRange])
            let trimmed = url.trimmingTrailingPunctuation
            // What was trimmed off the url (a full stop, a comma) is still part of the sentence.
            out += String(text[cursor..<range.lowerBound]) + "[\(trimmed)](\(trimmed))" + String(url.dropFirst(trimmed.count))
            cursor = range.upperBound
        }
        out += String(text[cursor...])
        return out
    }

    /// A url at the end of a sentence keeps the sentence's full stop out of the link.
    var trimmingTrailingPunctuation: String {
        var copy = self
        while let last = copy.last, ".,;:!?".contains(last) { copy.removeLast() }
        return copy
    }
}
