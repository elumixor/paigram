import Foundation

/// How a surface reaches the box: the address and this phone's device token.
public struct PaiGlanceConfig: Codable, Equatable {
    public let baseURL: String
    public let token: String

    public init(baseURL: String, token: String) {
        self.baseURL = baseURL
        self.token = token
    }
}

public enum PaiGlanceError: Error {
    case notSignedIn
    case http(Int)
    case badResponse
    /// The box refused, saying why (`{error}`).
    case refused(String)
}

/// Where a glance comes from: the box, or canned data for previews and until the box is reachable.
public protocol PaiGlanceSource {
    func glance(completion: @escaping (Result<PaiGlance, Error>) -> Void)
    func answer(need id: String, text: String, completion: @escaping (Result<Void, Error>) -> Void)
}

public final class PaiGlanceMockSource: PaiGlanceSource {
    public var value: PaiGlance

    public init(_ value: PaiGlance = .sample) {
        self.value = value
    }

    public func glance(completion: @escaping (Result<PaiGlance, Error>) -> Void) {
        completion(.success(value))
    }

    public func answer(need id: String, text: String, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.success(()))
    }
}

/// The box's API. Prefers the compact `GET /usage/summary`; until a box has it, composes the glance from
/// `/spend/forecast`, `/spend?days=1`, `/needs`, `/rail` and `/agents`.
public final class PaiGlanceLiveSource: PaiGlanceSource {
    public let config: PaiGlanceConfig
    private let session: URLSession
    /// How many needs a glance carries.
    public static let needsLimit = 8

    public init(config: PaiGlanceConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func glance(completion: @escaping (Result<PaiGlance, Error>) -> Void) {
        // The summary carries only the oldest need; the full list comes from /needs, and the agents with their
        // plans from /agents and /agents/<slug>/plan, all read alongside. `self` is held strongly on purpose:
        // callers make a source just for one call, and a weak capture would drop the result with the source.
        let group = DispatchGroup()
        var summary: Data?
        var needs: Data?
        var team: [PaiGlance.Member] = []
        group.enter()
        get("/usage/summary") { result in
            summary = try? result.get()
            group.leave()
        }
        group.enter()
        get("/needs") { result in
            needs = try? result.get()
            group.leave()
        }
        group.enter()
        self.team { members in
            team = members
            group.leave()
        }
        group.notify(queue: .global()) {
            if let summary, let glance = Self.decodeSummary(summary, needs: needs) {
                completion(.success(glance.with(team: team)))
                return
            }
            self.compose { result in
                completion(result.map { $0.with(team: team) })
            }
        }
    }

    /// Every agent and its plan; empty when the box cannot be read.
    public func team(completion: @escaping ([PaiGlance.Member]) -> Void) {
        get("/agents") { result in
            guard let data = try? result.get(), let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                completion([])
                return
            }
            let agents = list.filter { $0["slug"] is String && $0["closedAt"] as? Double == nil && $0["trashedAt"] as? Double == nil }
            let group = DispatchGroup()
            let lock = NSLock()
            var plans: [String: [PaiGlance.Member.Step]] = [:]
            for agent in agents {
                guard let slug = agent["slug"] as? String else { continue }
                group.enter()
                self.get("/agents/\(slug)/plan") { result in
                    let steps = (try? result.get()).flatMap(Self.steps) ?? []
                    lock.lock()
                    plans[slug] = steps
                    lock.unlock()
                    group.leave()
                }
            }
            group.notify(queue: .global()) {
                completion(agents.compactMap { Self.member($0, steps: plans[$0["slug"] as? String ?? ""] ?? []) })
            }
        }
    }

    static func member(_ raw: [String: Any], steps: [PaiGlance.Member.Step]) -> PaiGlance.Member? {
        guard let slug = raw["slug"] as? String else { return nil }
        let doing = (raw["doing"] as? String).map { String($0.prefix(Self.textLimit)) }
        return PaiGlance.Member(
            slug: slug,
            name: raw["name"] as? String ?? slug,
            role: raw["role"] as? String,
            status: raw["status"] as? String ?? "idle",
            doing: doing,
            depth: raw["depth"] as? Int ?? 1,
            steps: steps,
            activeAt: [date(raw["lastOutputAt"]), date(raw["lastActive"])].compactMap { $0 }.max()
        )
    }

    /// The plan's steps a small screen shows: the open ones (now, then next) and the last two done.
    static func steps(_ data: Data) -> [PaiGlance.Member.Step]? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let list = raw["steps"] as? [[String: Any]] else { return nil }
        let all = list.compactMap { step -> PaiGlance.Member.Step? in
            guard let text = step["text"] as? String, let state = step["state"] as? String else { return nil }
            return PaiGlance.Member.Step(state: state, text: String(text.prefix(textLimit)), eta: step["eta"] as? String)
        }
        let open = all.filter { $0.state == "now" } + all.filter { $0.state != "now" && $0.state != "done" }
        return Array(open.prefix(5)) + Array(all.filter { $0.state == "done" }.prefix(2))
    }

    /// Longest text a glance keeps per line: it travels to the watch, whose context is small.
    static let textLimit = 220

    public func answer(need id: String, text: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = URL(string: config.baseURL + "/needs/answer") else {
            completion(.failure(PaiGlanceError.badResponse))
            return
        }
        var request = request(url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["id": id, "text": text])
        session.dataTask(with: request) { _, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            completion((200 ..< 300).contains(status) ? .success(()) : .failure(PaiGlanceError.http(status)))
        }.resume()
    }

    // MARK: - Composing from the existing endpoints

    private func compose(completion: @escaping (Result<PaiGlance, Error>) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var parts: [String: Data] = [:]
        var failure: Error?
        for path in ["/spend/forecast", "/spend?days=1", "/needs", "/rail", "/agents"] {
            group.enter()
            get(path) { result in
                lock.lock()
                switch result {
                case let .success(data): parts[path] = data
                case let .failure(error): if path == "/spend/forecast" { failure = error }
                }
                lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .global()) {
            guard let forecastData = parts["/spend/forecast"], let forecast = try? JSONSerialization.jsonObject(with: forecastData) as? [String: Any] else {
                completion(.failure(failure ?? PaiGlanceError.badResponse))
                return
            }
            completion(.success(Self.compose(forecast: forecast, spend: parts["/spend?days=1"], needs: parts["/needs"], rail: parts["/rail"], agents: parts["/agents"])))
        }
    }

    static func compose(forecast: [String: Any], spend: Data?, needs needsData: Data?, rail: Data?, agents agentsData: Data?) -> PaiGlance {
        let today = forecast["today"] as? [String: Any]
        // A window without a reading is unknown, not empty: it is left out so the last known value stays.
        let windows = (forecast["windows"] as? [[String: Any]] ?? []).compactMap { raw -> PaiGlance.Window? in
            guard let name = raw["name"] as? String else { return nil }
            let reading = (raw["reading"] as? [String: Any])?["percent"] as? Double
            guard let percent = reading ?? raw["percent"] as? Double else { return nil }
            return PaiGlance.Window(name: name, percent: percent, resetsAt: date(raw["resetsAt"]))
        }

        let agentList = agentsData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        var names: [String: String] = [:]
        for agent in agentList {
            if let slug = agent["slug"] as? String, let name = agent["name"] as? String {
                names[slug] = name
            }
        }

        let buckets = spend.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { ($0["by"] as? [String: Any])?["agent"] as? [[String: Any]] } ?? []
        let agents = buckets.compactMap { bucket -> PaiGlance.AgentSpend? in
            guard let key = bucket["key"] as? String, let usd = bucket["apiUsd"] as? Double, usd > 0 else { return nil }
            return PaiGlance.AgentSpend(slug: key, name: names[key] ?? key.prefix(1).uppercased() + key.dropFirst(), usd: usd)
        }.sorted { $0.usd > $1.usd }

        let running: Int
        if let rail = rail.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }), let list = rail["running"] as? [Any] {
            running = list.count
        } else {
            running = agentList.filter { ($0["status"] as? String) == "working" }.count
        }

        let rawNeeds = needsData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        let needs = rawNeeds.compactMap(need).sorted { $0.createdAt < $1.createdAt }

        return PaiGlance(
            at: Date(),
            todayUsd: today?["apiUsd"] as? Double ?? 0,
            usdPerHour: forecast["usdPerHour"] as? Double,
            windows: windows,
            agents: Array(agents.prefix(5)),
            running: running,
            needsCount: needs.count,
            needs: Array(needs.prefix(needsLimit))
        )
    }

    static func need(_ raw: [String: Any]) -> PaiGlance.Need? {
        guard let id = raw["id"] as? String, let question = raw["question"] as? String else { return nil }
        return PaiGlance.Need(
            id: id,
            agent: raw["agent"] as? String,
            from: raw["from"] as? String ?? (raw["agent"] as? String).map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "pai",
            question: question,
            options: raw["options"] as? [String] ?? [],
            freeText: raw["freeText"] as? Bool ?? true,
            createdAt: date(raw["createdAt"]) ?? Date(),
            kind: raw["kind"] as? String,
            draft: (raw["draft"] as? [String: Any]).flatMap { draft in
                (raw["draftId"] as? Int).flatMap { Self.draft(id: $0, raw: draft) }
            }
        )
    }

    /// Longest draft body a glance carries; a longer one is marked `cut` and loaded whole before editing.
    static let draftBodyLimit = 2000

    /// A draft from `GET /drafts/:id`.
    public static func draft(_ raw: [String: Any]) -> PaiGlance.Need.Draft? {
        guard let id = raw["id"] as? Int else { return nil }
        return draft(id: id, raw: raw, limit: nil)
    }

    /// A draft from its `{channel, fields, status}` (a need's `draft` or the draft itself).
    static func draft(id: Int, raw: [String: Any], limit: Int? = draftBodyLimit) -> PaiGlance.Need.Draft? {
        guard let channel = raw["channel"] as? String, let fields = raw["fields"] as? [String: Any] else { return nil }
        let body = fields["body"] as? String ?? ""
        let cut = limit.map { body.count > $0 } ?? false
        return PaiGlance.Need.Draft(
            id: id,
            channel: channel,
            to: (fields["to"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            subject: (fields["subject"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            body: cut ? String(body.prefix(limit ?? 0)) : body,
            cut: cut,
            status: raw["status"] as? String,
            awaitsRecipient: !((fields["candidates"] as? [Any])?.isEmpty ?? true)
        )
    }

    /// The whole draft, for editing one whose glance body was cut.
    public func draft(id: Int, completion: @escaping (Result<PaiGlance.Need.Draft, Error>) -> Void) {
        get("/drafts/\(id)") { result in
            completion(result.flatMap { data -> Result<PaiGlance.Need.Draft, Error> in
                guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let draft = Self.draft(raw) else {
                    return .failure(PaiGlanceError.badResponse)
                }
                return .success(draft)
            })
        }
    }

    /// Sends a draft as the user, with his edits (`body`, `subject`) applied first. Empty `fields` sends it as drafted.
    public func sendDraft(id: Int, fields: [String: String], completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = URL(string: config.baseURL + "/drafts/\(id)/send") else {
            completion(.failure(PaiGlanceError.badResponse))
            return
        }
        var request = request(url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: fields)
        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200 ..< 300).contains(status) {
                completion(.success(()))
                return
            }
            let reason = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["error"] as? String
            completion(.failure(reason.map(PaiGlanceError.refused) ?? PaiGlanceError.http(status)))
        }.resume()
    }

    /// The compact endpoint (see PAIGRAM.md for its shape); nil when it is missing or malformed.
    static func decodeSummary(_ data: Data, needs needsData: Data? = nil) -> PaiGlance? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let today = raw["todayUsd"] as? Double else { return nil }
        let windows = (raw["windows"] as? [[String: Any]] ?? []).compactMap { window -> PaiGlance.Window? in
            guard let name = window["name"] as? String, let percent = window["percent"] as? Double else { return nil }
            return PaiGlance.Window(name: name, percent: percent, resetsAt: date(window["resetsAt"]))
        }
        let agents = (raw["agents"] as? [[String: Any]] ?? []).compactMap { agent -> PaiGlance.AgentSpend? in
            guard let slug = agent["slug"] as? String, let usd = agent["usd"] as? Double else { return nil }
            return PaiGlance.AgentSpend(slug: slug, name: agent["name"] as? String ?? slug, usd: usd)
        }
        let listed = needsData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
        let needs = (listed ?? raw["needsList"] as? [[String: Any]] ?? (raw["oldestNeed"] as? [String: Any]).map { [$0] } ?? []).compactMap(need)
        return PaiGlance(
            at: date(raw["at"]) ?? Date(),
            todayUsd: today,
            usdPerHour: raw["usdPerHour"] as? Double,
            windows: windows,
            agents: agents,
            running: raw["running"] as? Int ?? 0,
            needsCount: listed?.count ?? raw["needs"] as? Int ?? needs.count,
            needs: Array(needs.sorted { $0.createdAt < $1.createdAt }.prefix(needsLimit)),
            hold: PaiGlance.Hold.decode(raw["hold"])
        )
    }

    /// The box sends times as milliseconds or ISO strings (sometimes with microseconds).
    static func date(_ value: Any?) -> Date? {
        if let ms = value as? Double { return Date(timeIntervalSince1970: ms / 1000) }
        if let ms = value as? Int { return Date(timeIntervalSince1970: Double(ms) / 1000) }
        if let raw = value as? String {
            let trimmed = raw.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
            return ISO8601DateFormatter().date(from: trimmed)
        }
        return nil
    }

    // MARK: - HTTP

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func get(_ path: String, completion: @escaping (Result<Data, Error>) -> Void) {
        guard let url = URL(string: config.baseURL + path) else {
            completion(.failure(PaiGlanceError.badResponse))
            return
        }
        session.dataTask(with: request(url)) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200 ..< 300).contains(status), let data else {
                completion(.failure(PaiGlanceError.http(status)))
                return
            }
            completion(.success(data))
        }.resume()
    }
}
