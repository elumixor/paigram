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
/// `record: false`). Fails closed: only a clear `record: true` records.
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

    static let unavailable = Answer(record: false, reason: "policy unavailable")

    /// Maps pai's reply to an answer; anything but a 2xx with a readable `record` (error, timeout, 404, bad body)
    /// is `unavailable` and does not record.
    public static func answer(status: Int?, body: Data?) -> Answer {
        guard let status, (200..<300).contains(status), let body, let response = try? JSONDecoder().decode(Response.self, from: body) else {
            return unavailable
        }
        return Answer(record: response.record, reason: response.reason ?? "")
    }

    public static func shouldRecord(_ peer: CallRecordingPolicyPeer, uploader: CallRecordingUploader = .shared) async -> Answer {
        guard let (baseURL, token) = uploader.signedIn() else {
            return unavailable
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
