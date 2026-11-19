import Foundation

/// Who was on the other end. Nil fields are left out of the JSON.
public struct CallRecordingPeer: Codable, Equatable, Sendable {
    public var name: String?
    public var number: String?
    public var telegramId: String?

    public init(name: String? = nil, number: String? = nil, telegramId: String? = nil) {
        self.name = name
        self.number = number
        self.telegramId = telegramId
    }
}

/// The `meta` part of `POST /calls/recording` (pai `src/domain/call-recordings.ts`), also kept beside the tracks on disk.
/// `endedAt` stays nil while the call is still being recorded; only finished recordings are uploaded.
public struct CallRecordingMeta: Codable, Equatable, Sendable {
    public enum Direction: String, Codable, Sendable {
        case incoming = "in"
        case outgoing = "out"
    }

    public var callId: String
    public var startedAt: String
    public var endedAt: String?
    public var direction: Direction
    public var peer: CallRecordingPeer
    public var app: String

    public init(callId: String = UUID().uuidString, startedAt: Date, endedAt: Date? = nil, direction: Direction, peer: CallRecordingPeer, app: String = "telegram") {
        self.callId = callId
        self.startedAt = CallRecordingMeta.isoString(startedAt)
        self.endedAt = endedAt.map(CallRecordingMeta.isoString)
        self.direction = direction
        self.peer = peer
        self.app = app
    }

    public static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
