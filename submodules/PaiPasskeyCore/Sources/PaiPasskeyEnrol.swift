import Foundation

public enum PaiPasskeyEnrolError: LocalizedError, Equatable {
    case wrongCallback
    case stateMismatch
    case missingTicket

    public var errorDescription: String? {
        switch self {
        case .wrongCallback: return "The sign-in page returned an unexpected address"
        case .stateMismatch: return "The sign-in page returned a different request: try again"
        case .missingTicket: return "The sign-in page returned no ticket"
        }
    }
}

/// The web hand-off of an enrol: the page at `/link` returns `paigram://pai-auth?ticket=&expires=&state=`.
public enum PaiPasskeyEnrol {
    public static let callbackScheme = "paigram"

    /// A random value the page echoes back, so a callback from another request is refused.
    public static func makeState() -> String {
        Base64URL.encode(PKCE.randomBytes(16))
    }

    public static func url(base: String, state: String, challenge: String, name: String, invite: String?) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        let path = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = path + "/link"
        var items = [
            URLQueryItem(name: "enrol", value: "1"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "name", value: name),
        ]
        if let invite, !invite.isEmpty { items.append(URLQueryItem(name: "invite", value: invite)) }
        components.queryItems = items
        components.fragment = nil
        return components.url
    }

    /// The add-device code in what the camera read off pai's web Settings: its QR is
    /// `https://<pai>/settings/account?enrol=<code>`; a bare code typed or scanned counts too. Anything else = nil.
    public static func invite(fromScanned text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: text), components.scheme != nil {
            guard let code = components.queryItems?.first(where: { $0.name == "enrol" })?.value else { return nil }
            return isCode(code) ? code : nil
        }
        return isCode(text) ? text : nil
    }

    /// pai's codes are 24 random bytes in base64url (32 characters).
    private static func isCode(_ text: String) -> Bool {
        text.count >= 16 && text.count <= 128 && text.unicodeScalars.allSatisfy {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" || $0 == "_"
        }
    }

    public struct Callback: Equatable {
        public let ticket: String
        public let expires: Date?
    }

    public static func parse(callback url: URL, expectedState: String) throws -> Callback {
        guard url.scheme == callbackScheme, url.host == "pai-auth",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            throw PaiPasskeyEnrolError.wrongCallback
        }
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        guard let state = value("state"), state == expectedState else { throw PaiPasskeyEnrolError.stateMismatch }
        guard let ticket = value("ticket"), !ticket.isEmpty else { throw PaiPasskeyEnrolError.missingTicket }
        let expires = value("expires").flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Callback(ticket: ticket, expires: expires)
    }
}
