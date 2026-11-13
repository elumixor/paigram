import Foundation

/// A voice the call can run on (`GET /calls` lists them with their labels).
public struct PaiCallEngine: Codable, Hashable, Identifiable {
    public let id: String
    public let label: String

    /// What the picker offers before the daemon has said.
    public static let defaults: [PaiCallEngine] = [
        PaiCallEngine(id: "claude", label: "Claude"),
        PaiCallEngine(id: "grok", label: "Grok"),
        PaiCallEngine(id: "eleven-realtime", label: "ElevenLabs realtime"),
        PaiCallEngine(id: "grok-voice", label: "Grok voice"),
    ]
}

/// One call, live or over: who, how long, what came of it; `transcript` only from `GET /calls/<id>`.
public struct PaiCallRecord: Codable, Identifiable, Equatable {
    public struct Line: Codable, Equatable, Hashable {
        public let role: String
        public let text: String
        public let at: Double?
    }

    public let id: String
    public let agent: String
    public let engine: String?
    public let status: String?
    public let startedAt: Double?
    public let endedAt: Double?
    public let durationS: Double?
    public let reason: String?
    public let headline: String?
    public let messageId: Int?
    public var transcript: [Line]? = nil
    /// Only on `POST /calls`: where its socket opens, once.
    public var ws: String? = nil

    public var startDate: Date? { startedAt.map { Date(timeIntervalSince1970: $0 / 1000) } }
}

public struct PaiCallList: Codable {
    public let calls: [PaiCallRecord]
    public let engines: [PaiCallEngine]
}

@available(iOS 16.0, *)
extension PaiClient {
    public func startCall(agent slug: String, engine: String?) async throws -> PaiCallRecord {
        var body: [String: Any] = ["agent": slug]
        if let engine { body["engine"] = engine }
        return try await call(PaiCallRecord.self, "/calls", method: "POST", body: body)
    }

    public func calls(limit: Int = 100) async throws -> PaiCallList {
        try await call(PaiCallList.self, "/calls", query: ["limit": String(limit)])
    }

    public func callDetail(_ id: String) async throws -> PaiCallRecord {
        try await call(PaiCallRecord.self, "/calls/\(id)")
    }

    /// Hangs up from the server's side, for when the socket is already gone.
    public func endCall(_ id: String) async throws {
        _ = try await call(JSONValue.self, "/calls/\(id)/end", method: "POST", body: [String: Any]())
    }
}

extension Double {
    /// "0:42", "12:05", "1:02:03".
    public var paiDuration: String {
        let total = Swift.max(0, Int(self.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
