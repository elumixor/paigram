import Foundation

private func postOnMain(_ names: Notification.Name...) {
    DispatchQueue.main.async { for name in names { NotificationCenter.default.post(name: name, object: nil) } }
}

/// What the user just acted on (a card pressed, an ask or question answered), kept on the client so every indicator
/// (the title's count, the hub, agent badges, the watch) drops it at once, before the daemon says so. Keys are need ids
/// (`card:<message>`, `ask:<id>`) or a prefix ending in `:` (`q:<session>:` = every question of that session). A key
/// lapses after 10 minutes, by when the daemon has long caught up; a refused action takes it back (`remove`).
public enum PaiSettled {
    private static let ttl: TimeInterval = 600
    private static let lock = NSLock()
    private static var keys: [String: Date] = [:]

    public static func add(_ key: String) {
        let until = Date().addingTimeInterval(ttl)
        lock.lock(); keys[key] = until; lock.unlock()
        postOnMain(PaiChat.needsChanged, PaiChat.changed)
        DispatchQueue.main.asyncAfter(deadline: .now() + ttl) {
            lock.lock(); let lapsed = keys[key] == until; if lapsed { keys[key] = nil }; lock.unlock()
            if lapsed { postOnMain(PaiChat.needsChanged, PaiChat.changed) }
        }
    }

    public static func remove(_ key: String) {
        lock.lock(); let removed = keys.removeValue(forKey: key) != nil; lock.unlock()
        if removed { postOnMain(PaiChat.needsChanged, PaiChat.changed) }
    }

    /// Whether `id` names something settled: a key exactly, or a key ending in `:` it starts with.
    public static func has(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        return keys.contains { key, until in until > now && (key == id || (key.hasSuffix(":") && id.hasPrefix(key))) }
    }

    /// The needs without the ones he just acted on, so a refetch that predates his answer never brings them back.
    public static func filter(_ needs: [PaiNeed]) -> [PaiNeed] {
        lock.lock(); let empty = keys.isEmpty; lock.unlock()
        if empty { return needs }
        return needs.filter { need in
            !(has(need.id) || need.askId.map { has("ask:\($0)") } == true || need.session.map { has("q:\($0):") } == true)
        }
    }
}

/// Agents sent a message a moment ago: they read as busy until their session says anything (`PaiStore` unexpects them on
/// the first `session.phase/input/turn_end/exit` of theirs, or when `/agents` shows them busy), the send fails, or 30 s pass.
public enum PaiExpected {
    private static let ttl: TimeInterval = 30
    private static let lock = NSLock()
    private static var sent: [String: Date] = [:]

    public static func expect(_ slug: String) {
        let at = Date()
        lock.lock(); sent[slug] = at; lock.unlock()
        postOnMain(PaiChat.agentsChanged, PaiChat.changed)
        DispatchQueue.main.asyncAfter(deadline: .now() + ttl) {
            lock.lock(); let lapsed = sent[slug] == at; if lapsed { sent[slug] = nil }; lock.unlock()
            if lapsed { postOnMain(PaiChat.agentsChanged, PaiChat.changed) }
        }
    }

    public static func unexpect(_ slug: String?) {
        guard let slug else { return }
        lock.lock(); let removed = sent.removeValue(forKey: slug) != nil; lock.unlock()
        if removed { postOnMain(PaiChat.agentsChanged, PaiChat.changed) }
    }

    public static func isExpected(_ slug: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let at = sent[slug] else { return false }
        return Date().timeIntervalSince(at) < ttl
    }
}

/// Card rows just pressed: drawn as running ("Starting…", no buttons) until the connector redraws the row (its state is
/// no longer the one it had when pressed) or 60 s pass. A refused press takes the row back (`release`).
public enum PaiPressed {
    private static let hold: TimeInterval = 60
    private static let lock = NSLock()
    private static var pressed: [String: (at: Date, was: String?)] = [:]

    private static func key(_ card: Int, _ row: String) -> String { "\(card):\(row)" }

    /// Whether a row in this state can be pressed into "running": one already pending or running stays as it is.
    public static func isLive(_ state: String?) -> Bool { state == "pending" || state == "running" }

    public static func press(card: Int, row: String, was: String?) {
        guard !isLive(was) else { return }
        let at = Date()
        lock.lock(); pressed[key(card, row)] = (at, was); lock.unlock()
        postOnMain(PaiRows.changed)
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
            lock.lock(); let lapsed = pressed[key(card, row)]?.at == at; if lapsed { pressed[key(card, row)] = nil }; lock.unlock()
            if lapsed { postOnMain(PaiRows.changed) }
        }
    }

    public static func release(card: Int, row: String) {
        lock.lock(); let removed = pressed.removeValue(forKey: key(card, row)) != nil; lock.unlock()
        if removed { postOnMain(PaiRows.changed) }
    }

    /// The row as it should draw now: running while its press holds, else as the connector sent it.
    public static func shown(_ row: PaiCardView.Row, card: Int) -> PaiCardView.Row {
        lock.lock(); defer { lock.unlock() }
        guard let press = pressed[key(card, row.id)] else { return row }
        guard row.state == press.was, Date().timeIntervalSince(press.at) < hold else {
            pressed[key(card, row.id)] = nil
            return row
        }
        return row.running
    }
}
