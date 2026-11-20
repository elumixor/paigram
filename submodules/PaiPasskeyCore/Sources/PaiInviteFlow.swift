import Foundation

/// The add-device screen's steps: scan a code, fetch the box's passkey request for it (whose `user.name` is the
/// account the code is bound to), confirm, then enrol. Every button maps to one event, and each event either moves
/// the flow or is ignored, so the screen never sits on a step a tap can't leave.
public struct PaiInviteFlow: Equatable {
    public enum State: Equatable {
        case scanning
        case preparing(code: String)
        case confirming(account: String)
        case enrolling
        case closed
    }

    public enum Event: Equatable {
        case scanned(code: String)
        case prepared(accountName: String)
        case failed
        case back
        case confirm
        case cancel
    }

    /// Shown when the box sends a request without a name.
    public static let fallbackAccount = "pai account"

    public private(set) var state: State = .scanning

    public init() {}

    /// Applies `event`; false = ignored in this state (a second scan while confirming, a tap after closing).
    @discardableResult
    public mutating func handle(_ event: Event) -> Bool {
        let next: State?
        switch (state, event) {
        case let (.scanning, .scanned(code)): next = .preparing(code: code)
        case let (.preparing, .prepared(name)): next = .confirming(account: Self.accountLabel(name))
        case (.preparing, .failed): next = .scanning
        case (.confirming, .back): next = .scanning
        case (.confirming, .confirm): next = .enrolling
        case (.enrolling, _), (.closed, _): next = nil
        case (_, .cancel): next = .closed
        default: next = nil
        }
        guard let next else { return false }
        state = next
        return true
    }

    /// The account row: the request's `user.name` (the email the invite is bound to), trimmed.
    public static func accountLabel(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallbackAccount : trimmed
    }
}
