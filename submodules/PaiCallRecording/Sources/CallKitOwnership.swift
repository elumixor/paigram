import Foundation

/// Paigram runs two CallKit users in one process: Telegram's calls and Pai's agent calls. CallKit delivers a
/// transaction to any provider of the app, so Pai's provider must exist only while an agent call is on, and must
/// act only on its own call. Kept free of CallKit so the rule is testable.
public enum CallKitOwnership {
    /// Whether Pai's agent-call provider should exist now: only between starting an agent call and its end.
    public static func agentProviderNeeded(agentCallActive: Bool, callKitAvailable: Bool) -> Bool {
        return agentCallActive && callKitAvailable
    }

    /// Whether an action CallKit delivered to Pai's provider is for Pai's own call; anything else is Telegram's.
    public static func agentOwnsAction(actionCallUUID: UUID, agentCallUUID: UUID?) -> Bool {
        guard let agentCallUUID else { return false }
        return actionCallUUID == agentCallUUID
    }
}
