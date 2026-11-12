import Foundation
import UIKit
import Display
import TelegramCore

/// The record pill (`@desk/core/pill`): a reference an agent writes (`keep:page/<id>`, `balance:block/<id>`,
/// `git:pai@1a2b3c4`, `#18`…) drawn as one capsule with the record's mark, title, meta and status. Each kind is one
/// entry in `kinds`; the first whose pattern matches the whole reference wins.
public enum PaiPill {
    public enum Kind: String {
        case balanceBlock, keepPage, person, thread, agent, commit, issue, hash, card, devSession
    }

    /// The picture at the pill's start, tinted by the look's colour.
    public enum Mark: Equatable {
        case symbol(String)
        case calendar
        case keep
        case commit
        case avatar(String)
        case dot
    }

    public struct Status: Equatable {
        public enum Shape { case todo, doing, done, cancelled }

        public let name: String
        public let color: String?

        public var shape: Shape {
            let name = name.lowercased()
            func has(_ pattern: String) -> Bool { name.range(of: pattern, options: .regularExpression) != nil }
            if has("done|complete|finish|closed|shipped|merged") { return .done }
            if has("cancel|drop|won.?t|abandon") { return .cancelled }
            if has("doing|progress|review|active|started|wip|testing|block") { return .doing }
            return .todo
        }

        public var ink: UIColor { PaiPill.color(color) ?? PaiPill.ink["gray"]! }
    }

    /// What a kind's resolver answers about one record.
    public struct Look: Equatable {
        public var title: String
        public var meta: String?
        public var color: UIColor?
        public var status: Status?
        public var mark: Mark
        public var href: String?
        public var hint: String?
        public var done: Bool
        public var external: Bool
    }

    public enum State: Equatable {
        case pending
        case found(Look)
        case missing
    }

    /// A reference as the resolver takes it.
    public struct Ref: Hashable {
        public let kind: Kind
        public let urn: String
    }

    /// One reference in a text: bare, as inline code, or as a link's target (the link text is its label).
    public struct Match {
        public let ref: Ref
        /// UTF-16 range in the text.
        public let range: NSRange
        public let label: String?
        public let url: String?
    }

    /// Posted on the main thread when a record's look arrives.
    public static let resolved = Notification.Name("pai.urnResolved")

    static let keepBase = "https://keep.desk.atmagaming.com"
    static let devBase = "https://dev.desk.atmagaming.com"
    static let balanceBase = "https://balance.desk.atmagaming.com"

    private struct Spec {
        let kind: Kind
        let pattern: NSRegularExpression
        let mark: Mark
        let external: Bool
        /// What a pill says while its record is loading and has no label.
        let name: (String) -> String
        let href: (String) -> String?
        /// A bare hash may not be a commit: it stays plain text until one answers.
        let plainUntilFound: Bool
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: "^(?:\(pattern))$", options: [.caseInsensitive])
    }

    private static func tail(_ urn: String) -> String {
        urn.components(separatedBy: "/").last ?? urn
    }

    private static let kinds: [Spec] = [
        Spec(kind: .balanceBlock, pattern: regex("balance:block/[A-Za-z0-9_-]+"), mark: .calendar, external: true,
             name: { _ in "Calendar block" }, href: { "\(balanceBase)/calendar?event=\(tail($0))" }, plainUntilFound: false),
        Spec(kind: .keepPage, pattern: regex("keep:page/[0-9A-Za-z-]{6,36}"), mark: .keep, external: true,
             name: { _ in "Keep page" }, href: { "\(keepBase)/p/\(tail($0))" }, plainUntilFound: false),
        Spec(kind: .person, pattern: regex("people:person/[0-9A-Za-z-]+"), mark: .symbol("person.crop.circle"), external: false,
             name: { _ in "Person" }, href: { _ in nil }, plainUntilFound: false),
        Spec(kind: .thread, pattern: regex("pai:thread/[0-9A-Za-z_-]+"), mark: .symbol("bubble.left.and.bubble.right"), external: false,
             name: { _ in "Thread" }, href: { _ in nil }, plainUntilFound: false),
        Spec(kind: .agent, pattern: regex("pai:agent/[0-9A-Za-z_-]+"), mark: .symbol("person.crop.circle"), external: false,
             name: { tail($0) }, href: { _ in nil }, plainUntilFound: false),
        Spec(kind: .commit, pattern: regex("git:@?[\\w.-]+(?:/[\\w.-]+)?@[0-9a-f]{7,40}"), mark: .commit, external: true,
             name: { urn in String(urn.split(separator: "@").last ?? "").prefix(7).description }, href: { _ in nil }, plainUntilFound: false),
        Spec(kind: .issue, pattern: regex("git:@?[\\w.-]+(?:/[\\w.-]+)?#\\d{1,7}"), mark: .symbol("arrow.triangle.pull"), external: true,
             name: { urn in "#" + (urn.components(separatedBy: "#").last ?? "") }, href: { _ in nil }, plainUntilFound: false),
        Spec(kind: .hash, pattern: regex("[0-9a-f]{7,40}"), mark: .commit, external: true,
             name: { String($0.prefix(7)) }, href: { _ in nil }, plainUntilFound: true),
        Spec(kind: .card, pattern: regex("pai:(?:draft|ask|card)/\\d{1,6}"), mark: .symbol("doc.text"), external: false,
             name: { urn in (urn.contains(":ask/") ? "Ask #" : urn.contains(":draft/") ? "Draft #" : "#") + tail(urn) }, href: { _ in nil }, plainUntilFound: false),
        Spec(kind: .devSession, pattern: regex("dev:session/[0-9A-Za-z-]{6,36}"), mark: .symbol("terminal"), external: true,
             name: { urn in "Dev session \(tail(urn).prefix(6))" }, href: { "\(devBase)/?session=\(tail($0))" }, plainUntilFound: false),
    ]

    private static func spec(_ kind: Kind) -> Spec { kinds.first(where: { $0.kind == kind })! }

    /// The kind of a whole reference, nil when it is none pai knows.
    public static func ref(_ urn: String) -> Ref? {
        let range = NSRange(location: 0, length: (urn as NSString).length)
        guard let spec = kinds.first(where: { $0.pattern.firstMatch(in: urn, range: range) != nil }) else { return nil }
        return Ref(kind: spec.kind, urn: urn)
    }

    // MARK: Finding references

    private static let barePattern = try! NSRegularExpression(pattern:
        "(?<![\\w/:.#@-])(balance:block/[A-Za-z0-9_-]+|keep:page/[0-9A-Za-z-]{6,36}|dev:session/[0-9A-Za-z-]{6,36}|people:person/[0-9A-Za-z-]+|pai:(?:thread|agent)/[0-9A-Za-z_-]+|pai:(?:draft|ask|card)/\\d{1,6}|git:@?[\\w-]+(?:\\.[\\w-]+)*(?:/[\\w-]+(?:\\.[\\w-]+)*)?(?:@[0-9a-f]{7,40}|#\\d{1,7}))(?![\\w/-])")
    private static let hashPattern = try! NSRegularExpression(pattern: "(?<![\\w/:.#@-])([0-9a-f]{7,40})(?![\\w/-])")
    private static let keepLink = try! NSRegularExpression(pattern: "^https://keep\\.desk\\.atmagaming\\.com/p/([0-9a-f-]{36})(?:[/?#].*)?$")
    private static let devLink = try! NSRegularExpression(pattern: "^https://[^/]*dev[^/]*/.*[?&]session=([0-9a-f-]{36})")
    private static let cardLink = try! NSRegularExpression(pattern: "/#/(draft|ask)/(\\d{1,6})$")

    private static func capture(_ regex: NSRegularExpression, _ text: String, group: Int = 1) -> [String]? {
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1 ... max(1, regex.numberOfCaptureGroups)).map { ns.substring(with: match.range(at: $0)) }
    }

    /// The reference a link points at: a Keep page, a dev session, a draft or ask in pai, or a URN as the target.
    private static func ref(fromLink url: String) -> Ref? {
        if let id = capture(keepLink, url)?.first { return Ref(kind: .keepPage, urn: "keep:page/\(id)") }
        if let id = capture(devLink, url)?.first { return Ref(kind: .devSession, urn: "dev:session/\(id)") }
        if let groups = capture(cardLink, url), groups.count == 2 { return Ref(kind: .card, urn: "pai:\(groups[0])/\(groups[1])") }
        if let found = ref(url), found.kind != .hash { return found }
        return nil
    }

    /// Every reference in a message: link targets first, then bare ones outside links and code blocks.
    public static func matches(text: String, entities: [MessageTextEntity] = []) -> [Match] {
        let ns = text as NSString
        var found: [Match] = []
        var blocked: [NSRange] = []
        for entity in entities {
            let range = NSRange(location: entity.range.lowerBound, length: entity.range.count)
            guard range.location >= 0, range.upperBound <= ns.length else { continue }
            switch entity.type {
            case let .TextUrl(url):
                blocked.append(range)
                if let linked = ref(fromLink: url) {
                    found.append(Match(ref: linked, range: range, label: ns.substring(with: range), url: url))
                }
            case .Url, .Email, .Pre, .Mention, .TextMention, .Hashtag:
                blocked.append(range)
            default:
                break
            }
        }
        let all = NSRange(location: 0, length: ns.length)
        for (pattern, isHash) in [(barePattern, false), (hashPattern, true)] {
            for match in pattern.matches(in: text, range: all) {
                var range = match.range(at: 1)
                if blocked.contains(where: { NSIntersectionRange($0, range).length > 0 }) { continue }
                if found.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) { continue }
                let urn = ns.substring(with: range)
                if isHash, urn.rangeOfCharacter(from: .decimalDigits) == nil || urn.rangeOfCharacter(from: .letters) == nil { continue }
                guard let bare = ref(urn) else { continue }
                if range.location > 0, range.upperBound < ns.length, ns.character(at: range.location - 1) == 0x60, ns.character(at: range.upperBound) == 0x60 {
                    range = NSRange(location: range.location - 1, length: range.length + 2)
                }
                found.append(Match(ref: bare, range: range, label: nil, url: nil))
            }
        }
        return found.sorted { $0.range.location < $1.range.location }
    }

    // MARK: Looks

    private struct Entry {
        let state: State
        let at: Date
    }

    private static let fresh: TimeInterval = 60
    private static let lock = NSLock()
    private static var entries: [String: Entry] = [:]
    private static var inFlight: Set<String> = []

    /// The record's look as known now; asks for it when unknown or older than a minute.
    public static func state(_ ref: Ref) -> State {
        lock.lock()
        let entry = entries[ref.urn]
        let stale = entry.map { Date().timeIntervalSince($0.at) > fresh } ?? true
        let start = stale && !inFlight.contains(ref.urn)
        if start { inFlight.insert(ref.urn) }
        lock.unlock()
        if start { resolve(ref) }
        return entry?.state ?? .pending
    }

    /// What a pill shows before (or without) its record: its label, else the kind's name; the URN when not found.
    public static func fallback(_ match: Match, missing: Bool) -> Look {
        let kind = spec(match.ref.kind)
        let label = match.label?.paiNonEmpty
        let title = label ?? (missing ? match.ref.urn : kind.name(match.ref.urn))
        return Look(title: title, meta: nil, color: nil, status: nil, mark: kind.mark, href: match.url ?? kind.href(match.ref.urn),
                    hint: missing ? "Not found: \(match.ref.urn)" : nil, done: false, external: kind.external)
    }

    /// What to draw for a match: its look and whether it is faded (loading or not found); nil leaves it as text.
    public static func display(_ match: Match) -> (look: Look, faded: Bool)? {
        switch state(match.ref) {
        case let .found(look):
            var look = look
            if look.href == nil { look.href = match.url ?? spec(match.ref.kind).href(match.ref.urn) }
            return (look, false)
        case .pending:
            return spec(match.ref.kind).plainUntilFound ? nil : (fallback(match, missing: false), true)
        case .missing:
            return spec(match.ref.kind).plainUntilFound ? nil : (fallback(match, missing: true), true)
        }
    }

    private static func finish(_ ref: Ref, _ look: Look?) {
        lock.lock()
        let previous = entries[ref.urn]?.state
        let state: State = look.map { .found($0) } ?? .missing
        entries[ref.urn] = Entry(state: state, at: Date())
        inFlight.remove(ref.urn)
        lock.unlock()
        if previous != state {
            DispatchQueue.main.async { NotificationCenter.default.post(name: resolved, object: nil) }
        }
    }

    private static func resolve(_ ref: Ref) {
        guard PaiAuth.isSignedIn, #available(iOS 16.0, *) else {
            lock.lock()
            inFlight.remove(ref.urn)
            lock.unlock()
            return
        }
        Task {
            do {
                let look = ref.kind == .keepPage ? try await keepLook(ref) : try await resolvedLook(ref)
                finish(ref, look)
            } catch {
                // Offline or the daemon is down: try again on the next draw, keep what was known.
                lock.lock()
                inFlight.remove(ref.urn)
                if entries[ref.urn] == nil { entries[ref.urn] = Entry(state: .missing, at: Date().addingTimeInterval(-fresh + 10)) }
                lock.unlock()
            }
        }
    }

    private struct KeepPreview: Decodable {
        struct Property: Decodable {
            let name: String
            let value: String?

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                name = (try? c.decode(String.self, forKey: .name)) ?? ""
                value = try? c.decodeIfPresent(String.self, forKey: .value)
            }

            private enum CodingKeys: String, CodingKey { case name, value }
        }

        let title: String?
        let properties: [Property]?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try? c.decodeIfPresent(String.self, forKey: .title)
            properties = try? c.decodeIfPresent([Property].self, forKey: .properties)
        }

        private enum CodingKeys: String, CodingKey { case title, properties }
    }

    @available(iOS 16.0, *)
    private static func keepLook(_ ref: Ref) async throws -> Look? {
        let id = tail(ref.urn)
        let page: KeepPreview
        do {
            page = try await PaiClient().call(KeepPreview.self, "/keep/preview", query: ["id": id])
        } catch let error as PaiClientError where error.message.contains("404") || error.message.lowercased().contains("not found") {
            return nil
        }
        let status = page.properties?.first(where: { $0.name.range(of: "^status$", options: [.regularExpression, .caseInsensitive]) != nil })?.value?.paiNonEmpty
        return Look(title: page.title?.paiNonEmpty ?? "Untitled", meta: nil, color: nil, status: status.map { Status(name: $0, color: nil) },
                    mark: .keep, href: "\(keepBase)/p/\(id)", hint: nil, done: false, external: true)
    }

    private struct Resolved: Decodable {
        struct Card: Decodable {
            let kind: String?
            let state: String?
            let channel: String?
        }

        struct Commit: Decodable {
            let project: String?
        }

        struct Block: Decodable {
            struct Sphere: Decodable {
                let name: String?
                let color: String?
            }

            let id: String?
            let title: String?
            let start: String?
            let end: String?
            let allDay: Bool?
            let location: String?
            let cancelled: Bool?
            let sphere: Sphere?
            let path: String?
        }

        let urn: String?
        let kind: String?
        let id: String?
        let label: String?
        let url: String?
        let avatar: String?
        let state: String?
        let card: Card?
        let commit: Commit?
        let block: Block?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            urn = try? c.decodeIfPresent(String.self, forKey: .urn)
            kind = try? c.decodeIfPresent(String.self, forKey: .kind)
            id = try? c.decodeIfPresent(String.self, forKey: .id)
            label = try? c.decodeIfPresent(String.self, forKey: .label)
            url = try? c.decodeIfPresent(String.self, forKey: .url)
            avatar = try? c.decodeIfPresent(String.self, forKey: .avatar)
            state = try? c.decodeIfPresent(String.self, forKey: .state)
            card = try? c.decodeIfPresent(Card.self, forKey: .card)
            commit = try? c.decodeIfPresent(Commit.self, forKey: .commit)
            block = try? c.decodeIfPresent(Block.self, forKey: .block)
        }

        private enum CodingKeys: String, CodingKey { case urn, kind, id, label, url, avatar, state, card, commit, block }
    }

    /// The resolver takes a card as `#N`, `draft #N` or `ask #N`.
    private static func resolverInput(_ ref: Ref) -> String {
        if ref.kind == .card {
            let n = tail(ref.urn)
            if ref.urn.contains(":draft/") { return "draft #\(n)" }
            if ref.urn.contains(":ask/") { return "ask #\(n)" }
            return "#\(n)"
        }
        return ref.urn
    }

    @available(iOS 16.0, *)
    private static func resolvedLook(_ ref: Ref) async throws -> Look? {
        let r = try await PaiClient().call(Resolved.self, "/urn/resolve", query: ["urn": resolverInput(ref)])
        guard r.urn != nil else { return nil }
        let kind = spec(ref.kind)
        let label = r.label?.paiNonEmpty
        var look = Look(title: label ?? kind.name(ref.urn), meta: nil, color: nil, status: nil, mark: kind.mark, href: r.url ?? kind.href(ref.urn),
                        hint: nil, done: false, external: kind.external)
        switch r.kind ?? "" {
        case "balance:block":
            guard let block = r.block else { break }
            let time = blockTime(start: block.start, end: block.end, allDay: block.allDay ?? false)
            look.title = block.title?.paiNonEmpty ?? "Untitled"
            look.meta = time
            look.color = color(block.sphere?.color)
            look.done = block.cancelled ?? false
            look.href = r.url ?? "\(balanceBase)\(block.path ?? "/calendar?event=\(block.id ?? tail(ref.urn))")"
            look.hint = [block.title, time, block.sphere?.name, block.location].compactMap { $0?.paiNonEmpty }.joined(separator: "\n")
        case "people:person", "pai:agent":
            if let avatar = r.avatar, avatar.hasPrefix("http") { look.mark = .avatar(avatar) }
        case "git:commit":
            look.mark = .commit
            look.meta = r.commit?.project
        case "git:issue":
            look.mark = .symbol("arrow.triangle.pull")
            look.meta = ref.urn.dropFirst(4).components(separatedBy: "#").first.map { String($0.split(separator: "/").last ?? "") }
        case "draft", "ask":
            let isAsk = (r.card?.kind ?? r.kind) == "ask"
            look.mark = .symbol(isAsk ? "hand.raised" : channelSymbol(r.card?.channel))
            look.done = (r.card?.state ?? r.state) == "done"
            look.external = false
        case "dev:session":
            if label == nil || label == "dev session" { look.title = "Dev session \(tail(r.urn ?? ref.urn).prefix(6))" }
        default:
            break
        }
        return look
    }

    private static func channelSymbol(_ channel: String?) -> String {
        switch channel ?? "" {
        case "email": return "envelope"
        case "telegram": return "paperplane"
        case "whatsapp": return "message"
        case "linkedin": return "briefcase"
        case "post": return "megaphone"
        default: return "doc.text"
        }
    }

    // MARK: Balance time

    private static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = precise.date(from: text) { return date }
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: String(text.prefix(10)))
    }

    /// "Fri 20 Nov · 11:30–12:15" in the reader's zone; the year when not this one; an all-day block is its days.
    public static func blockTime(start: String?, end: String?, allDay: Bool, now: Date = Date()) -> String? {
        guard let start = date(start) else { return nil }
        let end = date(end) ?? start
        let calendar = Calendar.current
        let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: now)
        let dayFormat = DateFormatter()
        dayFormat.locale = Locale(identifier: "en_GB")
        dayFormat.dateFormat = sameYear ? "EEE d MMM" : "EEE d MMM yyyy"
        let timeFormat = DateFormatter()
        timeFormat.locale = Locale(identifier: "en_GB")
        timeFormat.dateFormat = "HH:mm"
        if allDay {
            let last = end.addingTimeInterval(-86_400)
            return last > start ? "\(dayFormat.string(from: start)) – \(dayFormat.string(from: last))" : dayFormat.string(from: start)
        }
        if calendar.isDate(start, inSameDayAs: end) {
            return "\(dayFormat.string(from: start)) · \(timeFormat.string(from: start))–\(timeFormat.string(from: end))"
        }
        return "\(dayFormat.string(from: start)) \(timeFormat.string(from: start)) – \(dayFormat.string(from: end)) \(timeFormat.string(from: end))"
    }

    // MARK: Colours

    static let ink: [String: UIColor] = [
        "gray": UIColor(rgb: 0x8b8b8b), "grey": UIColor(rgb: 0x8b8b8b), "default": UIColor(rgb: 0x8b8b8b),
        "blue": UIColor(rgb: 0x3b82f6), "green": UIColor(rgb: 0x2f9e5b), "yellow": UIColor(rgb: 0xd4a106),
        "orange": UIColor(rgb: 0xea7a1a), "red": UIColor(rgb: 0xe5484d), "purple": UIColor(rgb: 0x8e4ec6),
        "pink": UIColor(rgb: 0xd6409f), "brown": UIColor(rgb: 0xa1714f),
    ]

    /// A colour as pai writes one: `#rrggbb`, `#rgb`, or an option colour's name.
    static func color(_ value: String?) -> UIColor? {
        guard var value = value?.trimmingCharacters(in: .whitespaces).lowercased(), !value.isEmpty else { return nil }
        if let named = ink[value] { return named }
        if value.hasPrefix("#") { value.removeFirst() }
        if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        return UIColor(rgb: rgb)
    }

    // MARK: Plain-text form

    /// Markdown with every reference as a `[title · meta](href)` link, for the SwiftUI screens.
    public static func markdown(_ text: String) -> String {
        let found = matches(text: text)
        guard !found.isEmpty else { return text }
        // Code blocks show their text as written.
        let fences = (try? NSRegularExpression(pattern: "```[\\s\\S]*?(```|$)"))?.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range) ?? []
        let result = NSMutableString(string: text)
        for match in found.reversed() where !fences.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
            guard let (look, _) = display(match) else { continue }
            let label = ([look.title] + (look.meta.map { [$0] } ?? [])).joined(separator: " · ")
                .replacingOccurrences(of: "]", with: ")").replacingOccurrences(of: "[", with: "(")
            result.replaceCharacters(in: match.range, with: look.href.map { "[\(label)](\($0))" } ?? label)
        }
        return result as String
    }
}
