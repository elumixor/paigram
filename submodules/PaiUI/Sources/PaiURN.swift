import Foundation
import TelegramCore

/// Keep pages (`keep:page/<id>`) and dev sessions (`dev:session/<id>`) as agents write them, turned into titled
/// links: the raw URN is for machines, never for the screen.
public enum PaiURN {
    public enum Kind {
        case keepPage
        case devSession
    }

    public struct Match {
        public let kind: Kind
        public let id: String
        /// UTF-16 range in the text.
        public let range: NSRange
    }

    private static let pattern = try! NSRegularExpression(pattern: "`?\\b(keep:page|dev:session)/([0-9A-Za-z-]{6,36})\\b`?")
    private static let uuidPattern = try! NSRegularExpression(pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")

    /// Posted on the main thread when a title arrives.
    public static let resolved = Notification.Name("pai.urnResolved")

    private struct Resolution {
        let title: String
        let url: String?
    }

    private static let lock = NSLock()
    private static var resolutions: [String: Resolution] = [:]
    private static var pending: Set<String> = []

    public static func matches(in text: String) -> [Match] {
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            let kind: Kind = ns.substring(with: match.range(at: 1)) == "keep:page" ? .keepPage : .devSession
            return Match(kind: kind, id: ns.substring(with: match.range(at: 2)), range: match.range)
        }
    }

    private static func key(_ kind: Kind, _ id: String) -> String {
        kind == .keepPage ? "keep:\(id)" : "dev:\(id)"
    }

    /// Where the URN opens: the Keep page, or the session in dev (its own URL once known).
    public static func url(_ kind: Kind, _ id: String) -> String {
        if let url = resolution(kind, id)?.url { return url }
        switch kind {
        case .keepPage: return "https://keep.desk.atmagaming.com/p/\(id)"
        case .devSession: return "https://dev.desk.atmagaming.com/?session=\(id)"
        }
    }

    /// What the pill says: the page's or session's title once fetched, its kind until then.
    public static func label(_ kind: Kind, _ id: String) -> String {
        let title = resolution(kind, id)?.title
        switch kind {
        case .keepPage: return "📄 " + (title ?? "Keep page")
        case .devSession: return "⌨️ " + (title ?? "Dev session")
        }
    }

    private static func resolution(_ kind: Kind, _ id: String) -> Resolution? {
        lock.lock()
        defer { lock.unlock() }
        return resolutions[key(kind, id)]
    }

    /// Fetches the titles of the URNs in a text that are not known yet.
    public static func prefetch(_ text: String) {
        for match in matches(in: text) {
            resolve(match.kind, match.id)
        }
    }

    private static func resolve(_ kind: Kind, _ id: String) {
        let key = key(kind, id)
        lock.lock()
        let skip = resolutions[key] != nil || pending.contains(key)
        if !skip { pending.insert(key) }
        lock.unlock()
        guard !skip, PaiAuth.isSignedIn else { return }
        // The daemon resolves a dev session only by its full id.
        if kind == .devSession, uuidPattern.firstMatch(in: id, range: NSRange(location: 0, length: (id as NSString).length)) == nil { return }
        guard #available(iOS 16.0, *) else { return }
        Task {
            struct Keep: Decodable { let title: String? }
            struct Dev: Decodable { let title: String?; let url: String? }
            var resolution: Resolution?
            switch kind {
            case .keepPage:
                if let page = try? await PaiClient().call(Keep.self, "/keep/preview", query: ["id": id]), let title = page.title, !title.isEmpty {
                    resolution = Resolution(title: title, url: nil)
                }
            case .devSession:
                if let session = try? await PaiClient().call(Dev.self, "/dev/session", query: ["id": id]), let title = session.title, !title.isEmpty {
                    resolution = Resolution(title: title, url: session.url)
                }
            }
            lock.lock()
            pending.remove(key)
            if let resolution { resolutions[key] = resolution }
            lock.unlock()
            if resolution != nil {
                DispatchQueue.main.async { NotificationCenter.default.post(name: resolved, object: nil) }
            }
        }
    }

    /// Markdown with every URN as a `[label](url)` link.
    public static func markdown(_ text: String) -> String {
        let found = matches(in: text)
        guard !found.isEmpty else { return text }
        let result = NSMutableString(string: text)
        for match in found.reversed() {
            let label = label(match.kind, match.id).replacingOccurrences(of: "]", with: ")").replacingOccurrences(of: "[", with: "(")
            result.replaceCharacters(in: match.range, with: "[\(label)](\(url(match.kind, match.id)))")
        }
        prefetch(text)
        return result as String
    }

    /// A message's text with every URN replaced by its label carrying a link; the other entities shift with it.
    /// Entities that overlap a URN (a code span around it) are dropped.
    public static func rewrite(text: String, entities: [MessageTextEntity]) -> (String, [MessageTextEntity]) {
        let found = matches(in: text)
        guard !found.isEmpty else { return (text, entities) }
        prefetch(text)
        let result = NSMutableString(string: text)
        var entities = entities
        for match in found.reversed() {
            let label = label(match.kind, match.id)
            let labelLength = (label as NSString).length
            let delta = labelLength - match.range.length
            result.replaceCharacters(in: match.range, with: label)
            let start = match.range.location
            let end = match.range.location + match.range.length
            entities = entities.compactMap { entity in
                let range = entity.range
                if range.upperBound <= start { return entity }
                if range.lowerBound >= end { return MessageTextEntity(range: (range.lowerBound + delta)..<(range.upperBound + delta), type: entity.type) }
                if range.lowerBound <= start && range.upperBound >= end {
                    if case .Code = entity.type { return nil }
                    return MessageTextEntity(range: range.lowerBound..<(range.upperBound + delta), type: entity.type)
                }
                return nil
            }
            entities.append(MessageTextEntity(range: start..<(start + labelLength), type: .TextUrl(url: url(match.kind, match.id))))
        }
        entities.sort { $0.range.lowerBound < $1.range.lowerBound }
        return (result as String, entities)
    }
}
