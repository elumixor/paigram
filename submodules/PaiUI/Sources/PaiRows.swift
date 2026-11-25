import Foundation
import Postbox
import TelegramCore

/// An HTML page an agent attached to a message (`meta.artifacts` on a log row, `pai/src/protocol/artifact.ts`), drawn
/// live under the message's words. Only pages are drawn here; an entry whose file is not `<16 hex>.html` or that
/// weighs over 2 MB is left out.
public struct PaiArtifact: Decodable, Equatable {
    public let file: String
    public let name: String
    public let size: Int
    public let title: String?
    /// A UI mock's page (pai's `protocol/mock.ts`): the card draws its version and Approve & build under it.
    public let mock: PaiMockRef?

    public static let maxBytes = 2 * 1024 * 1024
    public static let maxPerMessage = 4
    private static let pattern = try! NSRegularExpression(pattern: "^[0-9a-f]{16}\\.html$")

    public var heading: String { title?.paiNonEmpty ?? name.paiNonEmpty ?? "Artifact" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        file = try c.decode(String.self, forKey: .file)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        size = (try? c.decodeIfPresent(Int.self, forKey: .size)) ?? 0
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        mock = try? c.decodeIfPresent(PaiMockRef.self, forKey: .mock)
    }

    var isDrawable: Bool {
        size > 0 && size <= PaiArtifact.maxBytes && PaiArtifact.pattern.firstMatch(in: file, range: NSRange(location: 0, length: (file as NSString).length)) != nil
    }

    private enum CodingKeys: String, CodingKey { case file, name, size, title, mock }
}

/// A connector's card (`meta.card.view`, `@desk/connector`'s `CardView`): the dev connector's build card and its kin.
/// `state` is the host's closure once every row is closed (superseded by a newer card, or invalidated by him): the
/// card is then drawn folded, with no buttons.
public struct PaiCardView: Decodable, Equatable {
    public struct Button: Decodable, Equatable {
        public let id: String
        public let label: String
        public let icon: String?
        public let primary: Bool
        public let url: String?

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? ""
            icon = try? c.decodeIfPresent(String.self, forKey: .icon)
            primary = (try? c.decodeIfPresent(Bool.self, forKey: .primary)) ?? false
            url = try? c.decodeIfPresent(String.self, forKey: .url)
        }

        private enum CodingKeys: String, CodingKey { case id, label, icon, primary, url }
    }

    public struct Row: Decodable, Equatable {
        public let id: String
        public let title: String
        public let state: String?
        public let message: String?
        public let url: String?
        public let supersededBy: String?
        public let buttons: [Button]

        public init(id: String, title: String, state: String?, message: String?, url: String?, supersededBy: String?, buttons: [Button]) {
            self.id = id
            self.title = title
            self.state = state
            self.message = message
            self.url = url
            self.supersededBy = supersededBy
            self.buttons = buttons
        }

        /// Just pressed: running, "Starting…", no buttons, until the connector redraws it (`PaiPressed`).
        public var running: Row {
            Row(id: id, title: title, state: "running", message: "Starting…", url: url, supersededBy: supersededBy, buttons: [])
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
            state = try? c.decodeIfPresent(String.self, forKey: .state)
            message = try? c.decodeIfPresent(String.self, forKey: .message)
            url = try? c.decodeIfPresent(String.self, forKey: .url)
            supersededBy = PaiCardView.idString(c, .supersededBy)
            buttons = (try? c.decodeIfPresent([Button].self, forKey: .buttons)) ?? []
        }

        /// Closed by the host: it lost its buttons and reads as its closure.
        public var isClosed: Bool { state == "superseded" || state == "invalidated" }

        private enum CodingKeys: String, CodingKey { case id, title, state, message, url, supersededBy, buttons }
    }

    public let title: String
    public let subtitle: String?
    public let icon: String?
    public let rows: [Row]
    public let buttons: [Button]
    public let state: String?
    public let supersededBy: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        subtitle = try? c.decodeIfPresent(String.self, forKey: .subtitle)
        icon = try? c.decodeIfPresent(String.self, forKey: .icon)
        rows = (try? c.decodeIfPresent([Row].self, forKey: .rows)) ?? []
        buttons = (try? c.decodeIfPresent([Button].self, forKey: .buttons)) ?? []
        state = try? c.decodeIfPresent(String.self, forKey: .state)
        supersededBy = PaiCardView.idString(c, .supersededBy)
    }

    /// A card the host closed: folded to its head and the closure, every button gone (Install, Retry, Cancel…),
    /// whatever the connector's own view still lists.
    public var isClosed: Bool { state == "superseded" || state == "invalidated" }

    /// What a closed card or row says: "Superseded by #12", "Invalidated".
    public static func closure(_ state: String?, by: String?) -> String? {
        switch state {
        case "superseded": return by.map { "Superseded by #\($0)" } ?? "Superseded"
        case "invalidated": return "Invalidated"
        default: return nil
        }
    }

    /// What a row's state reads as beside its title.
    public static func label(_ state: String?) -> String? {
        switch state {
        case "pending": return "Pending"
        case "running": return "Running"
        case "succeeded": return "Done"
        case "failed": return "Failed"
        case "interrupted": return "Interrupted"
        case "cancelled": return "Cancelled"
        default: return nil
        }
    }

    /// The SF Symbol for a connector's icon name (lucide's kebab-case, the set the web client draws).
    public static func symbol(_ icon: String?) -> String? {
        switch icon ?? "" {
        case "badge-check": return "checkmark.seal"
        case "circle-check": return "checkmark.circle"
        case "clock": return "clock"
        case "cloud-upload": return "icloud.and.arrow.up"
        case "download": return "arrow.down.circle"
        case "external-link": return "arrow.up.right.square"
        case "hammer": return "hammer"
        case "hourglass": return "hourglass"
        case "laptop": return "laptopcomputer"
        case "loader": return "arrow.triangle.2.circlepath"
        case "package": return "shippingbox"
        case "play": return "play"
        case "rotate-ccw": return "arrow.counterclockwise"
        case "smartphone": return "iphone"
        case "terminal": return "terminal"
        case "x": return "xmark"
        default: return nil
        }
    }

    /// `supersededBy` is a row id, written as a string or a number.
    private static func idString<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> String? {
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return s.paiNonEmpty }
        if let n = try? c.decodeIfPresent(Int.self, forKey: key) { return String(n) }
        return nil
    }

    private enum CodingKeys: String, CodingKey { case title, subtitle, icon, rows, buttons, state, supersededBy }
}

/// What a chat message gets from the message-log row it draws: the row's id, its artifacts and its card.
public struct PaiRowMeta: Equatable {
    public let id: Int
    public let artifacts: [PaiArtifact]
    public let card: PaiCardView?
}

/// The bot's messages carry the row's kind and agent but not its artifacts or card, which pai keeps on the log row
/// (`GET /messages`). A message with the trailer's `logId` (the row's id, on every message from a log row) reads that
/// row itself (`GET /messages/<id>`); one without it, from a box older than `logId`, is matched among the agent's latest
/// rows (`GET /messages?agent=`) by its words and time. Rows are read at most every 30 s while a message of theirs is
/// drawn; a change to an artifact list or a card posts `changed` so the chat redraws.
public enum PaiRows {
    public static let changed = Notification.Name("pai.rowsChanged")

    private struct Row: Decodable {
        struct Meta: Decodable {
            struct Card: Decodable { let view: PaiCardView? }
            let artifacts: [PaiArtifact]?
            let card: Card?

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                artifacts = try? c.decodeIfPresent([PaiArtifact].self, forKey: .artifacts)
                card = try? c.decodeIfPresent(Card.self, forKey: .card)
            }

            private enum CodingKeys: String, CodingKey { case artifacts, card }
        }

        let id: Int
        let from: String
        let kind: String
        let body: String
        let createdAt: Double
        let meta: Meta?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int.self, forKey: .id)
            from = (try? c.decodeIfPresent(String.self, forKey: .from)) ?? ""
            kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? ""
            body = (try? c.decodeIfPresent(String.self, forKey: .body)) ?? ""
            createdAt = (try? c.decodeIfPresent(Double.self, forKey: .createdAt)) ?? 0
            meta = try? c.decodeIfPresent(Meta.self, forKey: .meta)
        }

        private enum CodingKeys: String, CodingKey { case id, from, kind, body, createdAt, meta }
    }

    /// A row as kept here: only what a message needs, and its words' key for matching.
    private struct Kept {
        let id: Int
        let from: String
        let kind: String
        let key: String
        let at: Double
        let meta: PaiRowMeta
    }

    private static let lock = NSLock()
    private static var rows: [String: [Int: Kept]] = [:]
    private static var readAt: [String: Date] = [:]
    private static var inFlight: Set<String> = []
    private static let fresh: TimeInterval = 30

    /// Kinds whose rows can carry an artifact (an agent's reply) or a card (a notice).
    private static let kinds: Set<String> = ["result", "notice"]

    /// Whether a message may have a row with artifacts or a card: an agent's reply or a notice from pai's bot.
    public static func wants(_ message: Message) -> Bool {
        guard let meta = PaiTrailer.find(message)?.meta else { return false }
        return kinds.contains(meta.kind) && (meta.agent ?? meta.session.paiNonEmpty) != nil
    }

    /// The row a message draws, as known now; reads the agent's rows when they are unknown or old. Nil while
    /// unknown, or when the row has neither artifacts nor a card.
    public static func meta(_ message: Message) -> PaiRowMeta? {
        guard let trailer = PaiTrailer.find(message), kinds.contains(trailer.meta.kind), let slug = trailer.meta.agent ?? trailer.meta.session.paiNonEmpty else { return nil }
        let text = (message.text as NSString).substring(to: min(trailer.textEnd, (message.text as NSString).length))
        let found: PaiRowMeta?
        if let logId = trailer.meta.logId {
            found = find(logId: logId)
            refreshRow(logId, slug: slug)
        } else {
            found = find(slug: slug, kind: trailer.meta.kind, text: text, at: Double(message.timestamp) * 1000)
            refresh(slug)
        }
        guard let found, !found.artifacts.isEmpty || found.card != nil else { return nil }
        return found
    }

    /// Re-reads an agent's rows now: after a press, so the card's new state shows without waiting.
    public static func reload(slug: String) {
        lock.lock()
        readAt[slug] = nil
        let ids = Array((rows[slug] ?? [:]).keys).filter { readAt[rowKey($0)] != nil }
        for id in ids { readAt[rowKey(id)] = nil }
        lock.unlock()
        refresh(slug)
        for id in ids { refreshRow(id, slug: slug) }
    }

    /// Presses a card's button (`POST /cards/:id/press`); the redraw follows from the agent's rows. Nil when it went.
    @available(iOS 16.0, *)
    public static func press(card id: Int, button: String, row: String?, slug: String) async -> String? {
        struct Pressed: Decodable { let error: String? }
        var body: [String: Any] = ["button": button]
        if let row { body["row"] = row }
        do {
            let result = try await PaiClient().call(Pressed.self, "/cards/\(id)/press", method: "POST", body: body)
            reloadSoon(slug)
            return result.error
        } catch {
            return error.localizedDescription
        }
    }

    private static func reloadSoon(_ slug: String) {
        for delay in [0.8, 3.0, 8.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { reload(slug: slug) }
        }
    }

    // MARK: Matching

    /// Letters and digits only, lower-cased, the first `length`: a reply's text as Telegram shows it and the row's
    /// markdown agree on that. A message's is longer than a row's, since the bot may put a breadcrumb before the words.
    private static func key(_ text: String, length: Int) -> String {
        var out = ""
        for scalar in text.lowercased().unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            out.unicodeScalars.append(scalar)
            if out.unicodeScalars.count >= length { break }
        }
        return out
    }

    /// The row by its id, whichever agent's rows it was read with.
    private static func find(logId: Int) -> PaiRowMeta? {
        lock.lock()
        defer { lock.unlock() }
        for kept in rows.values {
            if let row = kept[logId] { return row.meta }
        }
        return nil
    }

    private static func find(slug: String, kind: String, text: String, at: Double) -> PaiRowMeta? {
        lock.lock()
        defer { lock.unlock() }
        guard let kept = rows[slug] else { return nil }
        let wanted = key(text, length: 96)
        guard wanted.count >= 4 else { return nil }
        let rowKinds: Set<String> = kind == "notice" ? ["notice"] : ["report", "response", "chat"]
        let candidates = kept.values.filter { row in
            rowKinds.contains(row.kind) && row.from != "user" && abs(row.at - at) < 10 * 60 * 1000
                && row.key.count >= 4 && (wanted.contains(row.key) || row.key.hasPrefix(wanted))
        }
        return candidates.min(by: { abs($0.at - at) < abs($1.at - at) })?.meta
    }

    // MARK: Reading

    private static func rowKey(_ id: Int) -> String { "#\(id)" }

    /// Whether a read under `key` is due; marks it in flight when it is.
    private static func begin(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let stale = readAt[key].map { Date().timeIntervalSince($0) > fresh } ?? true
        let start = stale && !inFlight.contains(key)
        if start { inFlight.insert(key) }
        return start
    }

    /// The agent's latest rows, for messages without a `logId`.
    private static func refresh(_ slug: String) {
        guard PaiAuth.isSignedIn, #available(iOS 16.0, *), begin(slug) else { return }
        Task {
            let read = try? await PaiClient().call([Row].self, "/messages", query: ["agent": slug, "limit": "100"])
            store(slug, key: slug, read ?? [], ok: read != nil)
        }
    }

    /// One row by its id (`GET /messages/<id>`), kept with the agent's rows. A row that is gone is kept as one with
    /// nothing to draw, so it is not asked for on every draw.
    private static func refreshRow(_ id: Int, slug: String) {
        let key = rowKey(id)
        guard PaiAuth.isSignedIn, #available(iOS 16.0, *), begin(key) else { return }
        Task {
            do {
                let row = try await PaiClient().call(Row.self, "/messages/\(id)")
                store(slug, key: key, [row], ok: true)
            } catch let error as PaiClientError where error.message.contains("404") || error.message.contains("no such message") {
                store(slug, key: key, [], ok: true)
            } catch {
                store(slug, key: key, [], ok: false)
            }
        }
    }

    private static func store(_ slug: String, key readKey: String, _ read: [Row], ok: Bool) {
        lock.lock()
        inFlight.remove(readKey)
        // Offline: try again in a while, not on every draw.
        readAt[readKey] = ok ? Date() : Date().addingTimeInterval(-fresh + 10)
        var kept = rows[slug] ?? [:]
        var dirty = false
        for row in read {
            let artifacts = Array((row.meta?.artifacts ?? []).filter(\.isDrawable).prefix(PaiArtifact.maxPerMessage))
            let meta = PaiRowMeta(id: row.id, artifacts: artifacts, card: row.meta?.card?.view)
            if let previous = kept[row.id], previous.meta == meta { continue }
            let hadMeta = kept[row.id].map { !$0.meta.artifacts.isEmpty || $0.meta.card != nil } ?? false
            if hadMeta || !artifacts.isEmpty || meta.card != nil { dirty = true }
            kept[row.id] = Kept(id: row.id, from: row.from, kind: row.kind, key: key(row.body, length: 24), at: row.createdAt, meta: meta)
        }
        // Keep the newest few hundred.
        if kept.count > 400 {
            for id in kept.keys.sorted().prefix(kept.count - 400) { kept[id] = nil }
        }
        rows[slug] = kept
        lock.unlock()
        if dirty {
            DispatchQueue.main.async { NotificationCenter.default.post(name: PaiRows.changed, object: nil) }
        }
    }
}
