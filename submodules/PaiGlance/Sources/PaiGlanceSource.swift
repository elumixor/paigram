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
        // The summary carries only the oldest need; the full list comes from /needs, read alongside.
        let group = DispatchGroup()
        var summary: Data?
        var needs: Data?
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
        group.notify(queue: .global()) { [weak self] in
            guard let self else { return }
            if let summary, let glance = Self.decodeSummary(summary, needs: needs) {
                completion(.success(glance))
                return
            }
            self.compose(completion: completion)
        }
    }

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
            createdAt: date(raw["createdAt"]) ?? Date()
        )
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
            needs: Array(needs.sorted { $0.createdAt < $1.createdAt }.prefix(needsLimit))
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
        var request = URLRequest(url: url, timeoutInterval: 15)
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
