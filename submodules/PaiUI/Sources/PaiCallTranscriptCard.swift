import Foundation
import TelegramCore

/// A recorded call's transcript in General's chat (`render` in `pai/src/domain/call-recordings.ts`), drawn as a card:
/// a bold title, "📞 Call with <peer> · <duration>", a quiet line with the direction, app and start, any summary as is,
/// and the transcript itself (the `[m:ss] Speaker: …` lines) in a collapsed quote that opens on a tap.
public enum PaiCallTranscriptCard {
    /// "📞 Incoming Telegram call with Anna, +420…, 21 Nov 14:03, 12:34".
    private static let header = try! NSRegularExpression(pattern: "^📞 (Incoming|Outgoing) (.+?) call with (.+), (.+?) (\\d{1,2}:\\d{2}), (\\d+(?::\\d{2})+)$")
    /// The first transcript line, or the line saying there is none.
    private static let transcriptStart = try! NSRegularExpression(pattern: "^(\\[\\d+(?::\\d{2})+\\]|Nothing was said)", options: [.anchorsMatchLines])
    /// `**Me:**`: markdown bold left in the text.
    private static let boldMarkdown = try! NSRegularExpression(pattern: "\\*\\*([^*\\n]+?)\\*\\*")

    public static func isHeader(_ text: String) -> Bool {
        let ns = text as NSString
        let end = ns.range(of: "\n").location
        let line = end == NSNotFound ? text : ns.substring(to: end)
        return header.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    public static func card(text: String, entities: [MessageTextEntity]) -> (text: String, entities: [MessageTextEntity]) {
        let ns = text as NSString
        var headerEnd = ns.range(of: "\n").location
        if headerEnd == NSNotFound { headerEnd = ns.length }
        let line = ns.substring(to: headerEnd)
        guard let match = header.firstMatch(in: line, range: NSRange(location: 0, length: headerEnd)) else {
            return (text, entities)
        }
        let group = { (i: Int) in (line as NSString).substring(with: match.range(at: i)) }
        let title = "📞 Call with \(group(3)) · \(group(6))"
        let subtitle = "\(group(1)) \(group(2)) call, \(group(4)) \(group(5))"
        let head = "\(title)\n\(subtitle)"
        let headLength = (head as NSString).length

        // Markdown bold that came through as text (`**Me:**`), drawn bold with its asterisks gone.
        let body = ns.substring(from: headerEnd) as NSString
        let stripped = NSMutableString()
        var removed: [Int] = []
        var bolds: [Range<Int>] = []
        var cursor = 0
        for bold in boldMarkdown.matches(in: body as String, range: NSRange(location: 0, length: body.length)) {
            stripped.append(body.substring(with: NSRange(location: cursor, length: bold.range.location - cursor)))
            let inner = body.substring(with: bold.range(at: 1))
            let from = stripped.length
            stripped.append(inner)
            bolds.append(headLength + from ..< headLength + stripped.length)
            removed.append(bold.range.location)
            removed.append(bold.range.location + bold.range.length - 2)
            cursor = bold.range.location + bold.range.length
        }
        stripped.append(body.substring(from: cursor))
        // A body offset, past the head and less the asterisks before it (inside a pair of them, at its start).
        let place = { (offset: Int) -> Int in
            var shift = 0
            for at in removed where at < offset { shift += min(2, offset - at) }
            return headLength + offset - shift
        }

        var result: [MessageTextEntity] = [
            MessageTextEntity(range: 0 ..< (title as NSString).length, type: .Bold),
            MessageTextEntity(range: (title as NSString).length + 1 ..< headLength, type: .Italic),
        ]
        for entity in entities where entity.range.lowerBound >= headerEnd {
            let lower = place(entity.range.lowerBound - headerEnd), upper = place(entity.range.upperBound - headerEnd)
            if upper > lower { result.append(MessageTextEntity(range: lower ..< upper, type: entity.type)) }
        }
        result += bolds.map { MessageTextEntity(range: $0, type: .Bold) }
        if let start = transcriptStart.firstMatch(in: stripped as String, range: NSRange(location: 0, length: stripped.length))?.range.location {
            var end = stripped.length
            while end > start, let scalar = UnicodeScalar(stripped.character(at: end - 1)), CharacterSet.whitespacesAndNewlines.contains(scalar) { end -= 1 }
            if end > start {
                result.append(MessageTextEntity(range: headLength + start ..< headLength + end, type: .BlockQuote(isCollapsed: true)))
            }
        }
        return (head + (stripped as String), result)
    }
}
