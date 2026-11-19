import Foundation

public enum PaiPasskeyGuardError: Error, Equatable, LocalizedError {
    case wrongRelyingParty(String)
    case wrongChange(requested: String, returned: String)

    public var errorDescription: String? {
        switch self {
        case let .wrongRelyingParty(id):
            return "The box asked for a passkey for \(id), not pai"
        case .wrongChange:
            return "The box returned a different change than the one requested"
        }
    }
}

/// Checks on what the box sends before anything reaches the passkey prompt or the approve screen.
public enum PaiPasskeyGuard {
    /// The relying party to sign for: always `pinned`. A server-sent id that differs is refused, so a compromised or
    /// misrouted box cannot get a signature for another site. A missing id falls back to the pinned one.
    public static func relyingParty(_ sent: String?, pinned: String) throws -> String {
        if let sent, sent != pinned { throw PaiPasskeyGuardError.wrongRelyingParty(sent) }
        return pinned
    }

    /// The change the box returned must be the one asked for, or the screen would show one change and sign another.
    public static func checkChange(requested: String, returned: String) throws {
        if requested != returned { throw PaiPasskeyGuardError.wrongChange(requested: requested, returned: returned) }
    }
}

/// Readable text of a change's JSON values for the approve screen.
public enum PaiChangeFormat {
    /// A plain string as is; anything else as pretty JSON with sorted keys and unescaped slashes. nil for JSON null.
    public static func text<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let json = String(data: data, encoding: .utf8) else { return nil }
        if json == "null" { return nil }
        if let string = try? JSONDecoder().decode(String.self, from: data) { return string }
        return json
    }
}
