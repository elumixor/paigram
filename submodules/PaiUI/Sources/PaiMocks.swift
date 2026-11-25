import Foundation

/// Which UI mock an artifact is, and which version of it (pai's `MockRef`, `src/protocol/mock.ts`).
public struct PaiMockRef: Decodable, Equatable {
    public let id: String
    public let version: Int

    public init(id: String, version: Int) {
        self.id = id
        self.version = version
    }
}

/// A mock as the box keeps it (`GET /mocks/<id>`, the `mock.changed` event): its latest version, whether a version
/// is approved, and the dev session building it.
public struct PaiMockState: Decodable, Equatable {
    public let id: String
    public let title: String
    public let project: String
    /// The latest version posted.
    public let version: Int
    /// `open` while iterated, `building` once a version is approved and its dev session started.
    public let status: String
    /// The last version he approved.
    public let approved: Int?
    public let session: String?
    public let sessionUrl: String?

    public init(id: String, title: String, project: String, version: Int, status: String, approved: Int?, session: String?, sessionUrl: String?) {
        self.id = id
        self.title = title
        self.project = project
        self.version = version
        self.status = status
        self.approved = approved
        self.session = session
        self.sessionUrl = sessionUrl
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        project = (try? c.decodeIfPresent(String.self, forKey: .project)) ?? ""
        version = try c.decode(Int.self, forKey: .version)
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "open"
        approved = try? c.decodeIfPresent(Int.self, forKey: .approved)
        session = try? c.decodeIfPresent(String.self, forKey: .session)
        sessionUrl = (try? c.decodeIfPresent(String.self, forKey: .sessionUrl))?.paiNonEmpty
    }

    private enum CodingKeys: String, CodingKey { case id, title, project, version, status, approved, session, sessionUrl }
}

/// What a mock card's foot says under the page, as pai's web client draws it (`apps/web/src/lib/chat/MockBar.svelte`).
public enum PaiMockFoot: Equatable {
    /// This version is the approved one: "Approved · building", and the session's link when there is one.
    case approved(sessionUrl: String?)
    /// The latest version: "Write in the chat to change it" and Approve & build, pressable once the state is known.
    case approvable(ready: Bool)
    /// An older version: "Replaced by v{latest}".
    case replaced(by: Int)

    /// The foot for one version given the mock's state as known (nil while unread).
    public static func of(_ ref: PaiMockRef, state: PaiMockState?) -> PaiMockFoot {
        guard let state else { return .approvable(ready: false) }
        if state.approved == ref.version { return .approved(sessionUrl: state.sessionUrl) }
        if state.version == ref.version { return .approvable(ready: true) }
        return .replaced(by: state.version)
    }
}

/// Mocks' states by id, read once when a card asks (`GET /mocks/<id>`), again when older than 30 s while drawn, and
/// kept current by the `mock.changed` event (`PaiStore`). Approve & build is his press (`POST /mocks/<id>/approve`),
/// which the box takes only from a person: the device token. Every change posts `PaiRows.changed`, so cards redraw.
public enum PaiMocks {
    private static let lock = NSLock()
    private static var states: [String: PaiMockState] = [:]
    private static var readAt: [String: Date] = [:]
    private static var inFlight: Set<String> = []
    private static var approving: Set<String> = []
    private static var errors: [String: String] = [:]
    private static let fresh: TimeInterval = 30

    /// The mock as last known; reads it when unknown or old.
    public static func state(_ id: String) -> PaiMockState? {
        lock.lock()
        let state = states[id]
        let stale = (readAt[id].map { Date().timeIntervalSince($0) > fresh } ?? true) && !inFlight.contains(id)
        if stale { inFlight.insert(id) }
        lock.unlock()
        if stale { load(id) }
        return state
    }

    public static func isApproving(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return approving.contains(id)
    }

    /// The last refusal of his Approve & build, until the next press.
    public static func error(_ id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return errors[id]
    }

    /// A `mock.changed` event's payload: the state.
    public static func apply(_ payload: JSONValue) {
        guard let state = try? payload.decode(PaiMockState.self) else { return }
        store(state)
    }

    /// His Approve & build on one version; the error the box gave, nil when it went.
    @discardableResult
    public static func approve(_ id: String, version: Int) async -> String? {
        lock.lock()
        guard !approving.contains(id) else {
            lock.unlock()
            return nil
        }
        approving.insert(id)
        errors[id] = nil
        lock.unlock()
        changed()
        var failure: String?
        do {
            // A 401 here says the press was not a person's, not that the device token is gone.
            let state = try await PaiClient().call(PaiMockState.self, "/mocks/\(id)/approve", method: "POST", body: ["version": version], keepTokenOn401: true)
            store(state, post: false)
        } catch {
            failure = error.localizedDescription
        }
        lock.lock()
        approving.remove(id)
        errors[id] = failure
        lock.unlock()
        changed()
        return failure
    }

    private static func load(_ id: String) {
        Task {
            let state = try? await PaiClient().call(PaiMockState.self, "/mocks/\(id)")
            lock.lock()
            inFlight.remove(id)
            readAt[id] = Date()
            lock.unlock()
            if let state { store(state) }
        }
    }

    private static func store(_ state: PaiMockState, post: Bool = true) {
        lock.lock()
        let old = states[state.id]
        states[state.id] = state
        readAt[state.id] = Date()
        lock.unlock()
        if post, old != state { changed() }
    }

    private static func changed() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: PaiRows.changed, object: nil) }
    }
}
