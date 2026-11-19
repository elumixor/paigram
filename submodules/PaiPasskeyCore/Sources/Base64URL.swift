import Foundation

/// Base64url without padding (RFC 4648 §5), the encoding pai uses for every binary WebAuthn value.
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Accepts input with or without padding; nil for characters outside the base64url alphabet.
    public static func decode(_ string: String) -> Data? {
        var base64 = string.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard base64.unicodeScalars.allSatisfy({ allowed.contains($0) }), base64.count % 4 != 1 else { return nil }
        base64 = base64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}
