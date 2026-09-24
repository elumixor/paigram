import Foundation

public struct PaiClientError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// Where the daemon is and how to talk to it. Persisted so the app remembers the box.
public final class PaiSettings: ObservableObject {
    private enum Key {
        static let baseURL = "pai.baseURL"
        static let token = "pai.token"
        static let speechLocale = "pai.speechLocale"
    }
    public static let defaultBaseURL = "https://pai.atmagaming.com"
    public static let speechLocales = ["en-US", "uk-UA", "ru-RU"]
    private static var defaultSpeechLocale: String {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        return speechLocales.first { $0.hasPrefix(language) } ?? speechLocales[0]
    }

    @Published public var baseURL: String { didSet { defaults.set(baseURL, forKey: Key.baseURL) } }
    @Published public var token: String { didSet { defaults.set(token, forKey: Key.token) } }
    @Published public var speechLocale: String { didSet { defaults.set(speechLocale, forKey: Key.speechLocale) } }

    private let defaults = UserDefaults.standard

    public init() {
        baseURL = defaults.string(forKey: Key.baseURL) ?? Self.defaultBaseURL
        token = defaults.string(forKey: Key.token) ?? ""
        speechLocale = defaults.string(forKey: Key.speechLocale) ?? Self.defaultSpeechLocale
    }

    public var isConfigured: Bool { !token.isEmpty && URL(string: baseURL) != nil }
}

/// The daemon's HTTP API: JSON calls plus the SSE event stream.
@available(iOS 16.0, *)
public final class PaiClient {
    private let settings: PaiSettings
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    public init(settings: PaiSettings) { self.settings = settings }

    private func url(_ path: String, query: [String: String] = [:]) throws -> URL {
        guard var components = URLComponents(string: settings.baseURL.trimmingCharacters(in: .whitespaces)) else {
            throw PaiClientError(message: "Server address is not a valid URL")
        }
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + path
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components.url else { throw PaiClientError(message: "Server address is not a valid URL") }
        return url
    }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil, query: [String: String] = [:]) throws -> URLRequest {
        var request = URLRequest(url: try url(path, query: query))
        request.httpMethod = method
        request.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func call<T: Decodable>(_ type: T.Type, _ path: String, method: String = "GET", body: [String: Any]? = nil, query: [String: String] = [:]) async throws -> T {
        let (data, response) = try await session.data(for: try request(path, method: method, body: body, query: query))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw PaiClientError(message: detail ?? "\(path) failed with HTTP \(status)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Threads

    public func tasks() async throws -> PaiTasks { try await call(PaiTasks.self, "/tasks") }
    public func projects() async throws -> [PaiProject] { try await call([PaiProject].self, "/projects") }

    public func transcript(session id: String) async throws -> [PaiTranscriptMessage] {
        try await call([PaiTranscriptMessage].self, "/transcript", query: ["session": id, "limit": "200"])
    }

    public func newThread(text: String, project: String?) async throws -> PaiSession {
        var body: [String: Any] = ["title": "", "text": text]
        if let project { body["project"] = project }
        return try await call(PaiSession.self, "/task", method: "POST", body: body)
    }

    public func send(session id: String, text: String) async throws -> PaiSession {
        try await call(PaiSession.self, "/send", method: "POST", body: ["id": id, "text": text])
    }

    public func answer(session id: String, text: String) async throws {
        struct Answered: Decodable { let answered: Bool; let error: String? }
        let result = try await call(Answered.self, "/answer", method: "POST", body: ["id": id, "text": text])
        if !result.answered { throw PaiClientError(message: result.error ?? "No question is pending") }
    }

    public func stop(session id: String) async throws {
        struct Ok: Decodable { let ok: Bool }
        _ = try await call(Ok.self, "/stop", method: "POST", body: ["id": id])
    }

    public func health() async throws -> String {
        struct Health: Decodable { let version: String? }
        return try await call(Health.self, "/health").version ?? "unknown"
    }

    // MARK: Events

    /// `GET /events?follow=1`; yields one decoded event per `data:` line, until cancelled or the server hangs up.
    public func events(session id: String?, deltas: Bool) -> AsyncThrowingStream<PaiEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var query = ["follow": "1", "replay": "0", "deltas": deltas ? "1" : "0", "token": settings.token]
                    if let id { query["session"] = id }
                    var request = try request("/events", query: query)
                    request.timeoutInterval = 3600
                    let (bytes, response) = try await session.bytes(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        throw PaiClientError(message: "Event stream refused: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                    }
                    let decoder = JSONDecoder()
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let data = json.data(using: .utf8), let event = try? decoder.decode(PaiEvent.self, from: data) else { continue }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
