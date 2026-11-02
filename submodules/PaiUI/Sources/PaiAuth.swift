import AuthenticationServices
import Foundation
import Security
import TelegramCore
import UIKit

/// This phone's own credential for the box. The app ships with none: signing in opens the box's link page
/// (`/#/link`) in a web sign-in sheet, the person signed in there (Desk's Clerk account, on `PAI_ALLOWED`) links the
/// phone, and the box answers `paigram://pai-auth` with a device token that lives in the keychain. Signing out
/// revokes it on the box; a 401 means it was revoked elsewhere, so it is forgotten here too.
public enum PaiAuth {
    /// Posted on the main queue whenever the phone signs in or out.
    public static let didChange = Notification.Name("PaiAuth.didChange")

    private static let service = "pai.device-token"
    private static let account = "box"
    private static let callbackScheme = "paigram"
    private static let lock = NSLock()
    private static var cached: String??

    public static var token: String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let value = readKeychain()
        cached = .some(value)
        return value
    }

    public static var isSignedIn: Bool { token != nil }

    /// Hands the token to TelegramCore's box client (email and WhatsApp chats) and the notification extension.
    public static func apply() {
        if let token {
            PaiBox.configure(baseURL: PaiSecrets.baseURL, token: token)
        } else {
            PaiBox.clear()
        }
        PaiNotificationAnswer.refreshConfig()
    }

    @MainActor
    public static func signIn() async throws {
        let state = UUID().uuidString
        var components = URLComponents(string: PaiSecrets.baseURL)
        components?.path = "/"
        components?.fragment = "/link?" + Self.query(["state": state, "name": UIDevice.current.name])
        guard let url = components?.url else { throw PaiClientError(message: "Server address is not a valid URL") }
        let callback = try await WebSignIn.run(url: url, callbackScheme: callbackScheme)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard callback.host == "pai-auth", items.first(where: { $0.name == "state" })?.value == state,
              let token = items.first(where: { $0.name == "token" })?.value, token.hasPrefix("pd_") else {
            throw PaiClientError(message: "The box did not link this phone")
        }
        store(token)
    }

    /// Revokes the token on the box (best effort) and forgets it here.
    public static func signOut() {
        if let token, let url = URL(string: PaiSecrets.baseURL + "/auth/devices/self") {
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            URLSession.shared.dataTask(with: request).resume()
        }
        store(nil)
    }

    /// The box refused the token: it was revoked, or its person is no longer allowed.
    static func rejected(_ token: String) {
        guard self.token == token else { return }
        store(nil)
    }

    private static func store(_ token: String?) {
        lock.lock()
        writeKeychain(token)
        cached = .some(token)
        lock.unlock()
        DispatchQueue.main.async {
            apply()
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    private static func query(_ items: [String: String]) -> String {
        var components = URLComponents()
        components.queryItems = items.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery ?? ""
    }

    // MARK: Keychain

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func readKeychain() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeKeychain(_ token: String?) {
        SecItemDelete(baseQuery as CFDictionary)
        guard let token, let data = token.data(using: .utf8) else { return }
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// `ASWebAuthenticationSession` as one async call; it shares Safari's cookies, so a phone already signed in to Desk
/// only confirms.
private final class WebSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private static var running: WebSignIn?
    private var session: ASWebAuthenticationSession?

    @MainActor
    static func run(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let signIn = WebSignIn()
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callback, error in
                running = nil
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(throwing: error ?? PaiClientError(message: "Sign-in failed"))
                }
            }
            session.presentationContextProvider = signIn
            signIn.session = session
            running = signIn
            if !session.start() {
                running = nil
                continuation.resume(throwing: PaiClientError(message: "Could not open the sign-in sheet"))
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first ?? ASPresentationAnchor()
    }
}
