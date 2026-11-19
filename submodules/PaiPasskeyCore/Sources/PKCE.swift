import CryptoKit
import Foundation
import Security

/// PKCE (RFC 7636, S256) for the passkey enrol hand-off from the web page back to the app.
public enum PKCE {
    /// 32 random bytes as base64url: 43 characters, all in the verifier alphabet.
    public static func makeVerifier() -> String {
        Base64URL.encode(randomBytes(32))
    }

    public static func challenge(for verifier: String) -> String {
        Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// 43 to 128 characters of `[A-Za-z0-9-._~]`.
    public static func isValidVerifier(_ verifier: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return (43...128).contains(verifier.count) && verifier.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(bytes)
    }
}
