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
        let delta = headLength - headerEnd

        var result: [MessageTextEntity] = [
            MessageTextEntity(range: 0 ..< (title as NSString).length, type: .Bold),
            MessageTextEntity(range: (title as NSString).length + 1 ..< headLength, type: .Italic),
        ]
        for entity in entities where entity.range.lowerBound >= headerEnd {
            result.append(MessageTextEntity(range: entity.range.lowerBound + delta ..< entity.range.upperBound + delta, type: entity.type))
        }
        let rest = NSRange(location: headerEnd, length: ns.length - headerEnd)
        if let start = transcriptStart.firstMatch(in: text, range: rest)?.range.location {
            var end = ns.length
            while end > start, let scalar = UnicodeScalar(ns.character(at: end - 1)), CharacterSet.whitespacesAndNewlines.contains(scalar) { end -= 1 }
            if end > start {
                result.append(MessageTextEntity(range: start + delta ..< end + delta, type: .BlockQuote(isCollapsed: true)))
            }
        }
        return (head + ns.substring(from: headerEnd), result)
    }
}
