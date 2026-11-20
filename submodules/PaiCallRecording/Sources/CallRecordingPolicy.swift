import Foundation

/// The peer of a call, as pai's `POST /calls/should-record` reads it.
public struct CallRecordingPolicyPeer: Encodable, Equatable, Sendable {
    public var app: String
    public var peerName: String?
    /// E.164 (`+` and digits) when the phone number is known.
    public var peerPhone: String?
    public var peerUsername: String?
    public var peerTelegramId: String?

    public init(peerName: String?, peerPhone: String?, peerUsername: String?, peerTelegramId: String?) {
        self.app = "telegram"
        self.peerName = peerName
        self.peerPhone = peerPhone.flatMap(CallRecordingPolicyPeer.e164)
        self.peerUsername = peerUsername
        self.peerTelegramId = peerTelegramId
    }

    /// Telegram keeps phone numbers as bare digits; pai expects `+` and the digits.
    static func e164(_ phone: String) -> String? {
        let digits = phone.filter(\.isNumber)
        return digits.isEmpty ? nil : "+" + digits
    }
}

/// Asks pai whether a call may be recorded automatically (calls with the owner's employer contacts are not: pai answers
/// `record: false`). Anything but a clear "no" records: pai checks again on upload and drops what it must not keep.
public enum CallRecordingPolicy {
    public struct Answer: Equatable, Sendable {
        public var record: Bool
        public var reason: String
    }

    private struct Response: Decodable {
        var record: Bool
        var reason: String?
    }

    static let timeout: TimeInterval = 3

    /// Maps pai's reply to an answer; an error, a non-2xx status (404 = endpoint not deployed yet) or an unreadable
    /// body records.
    public static func answer(status: Int?, body: Data?) -> Answer {
        guard let status else {
            return Answer(record: true, reason: "pai unreachable")
        }
        guard (200..<300).contains(status), let body, let response = try? JSONDecoder().decode(Response.self, from: body) else {
            return Answer(record: true, reason: "pai answered \(status)")
        }
        return Answer(record: response.record, reason: response.reason ?? "")
    }

    public static func shouldRecord(_ peer: CallRecordingPolicyPeer, uploader: CallRecordingUploader = .shared) async -> Answer {
        guard let (baseURL, token) = uploader.signedIn() else {
            return Answer(record: true, reason: "pai not signed in")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("calls/should-record"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = try? JSONEncoder().encode(peer)
        return await withCheckedContinuation { continuation in
            URLSession.shared.dataTask(with: request) { data, response, _ in
                let status = (response as? HTTPURLResponse)?.statusCode
                continuation.resume(returning: answer(status: status, body: data))
            }.resume()
        }
    }
}
