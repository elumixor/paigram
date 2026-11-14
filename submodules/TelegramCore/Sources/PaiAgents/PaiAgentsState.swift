import Foundation
import Postbox

/// One of pai's agents as the app knows it from `/agents`; the app hands the list over (`TelegramEngine.PaiAgents.update`),
/// so TelegramCore never reads that route itself.
public struct PaiAgentInfo: Codable, Equatable {
    public let slug: String
    public let name: String
    /// The line under the name on its profile.
    public let role: String?
    /// An absolute address of the agent's portrait, set once the app stored it at `paiAgentAvatarResource(url:)`.
    public let avatar: String?
    public let parent: String?
    /// The pai bot's forum topic the agent talks in: its chat.
    public let threadId: Int64?
    /// Closed or done.
    public let closed: Bool

    public init(slug: String, name: String, role: String?, avatar: String?, parent: String?, threadId: Int64?, closed: Bool) {
        self.slug = slug
        self.name = name
        self.role = role
        self.avatar = avatar
        self.parent = parent
        self.threadId = threadId
        self.closed = closed
    }
}

/// What this device keeps of pai's agents: the agents (each a peer that is only an identity: portrait, name, role, for
/// its profile), the bot whose forum topics are their chats, and the topics given a hole for pai's log from before
/// the topic (`PaiTopicHistory.swift`).
public struct PaiAgentsState: Codable, Equatable {
    public var agents: [PaiAgentInfo]
    /// The pai bot's peer.
    public var botPeerId: Int64?
    /// Topics given a `Box` hole for the agent's history older than the topic.
    public var historyTopics: [Int64]?
    /// The agent chats an earlier build kept on the device (local history under a "pai" row) are cleared.
    public var cleared: Bool?

    public static let empty = PaiAgentsState(agents: [], botPeerId: nil, historyTopics: nil, cleared: nil)

    public func agent(slug: String) -> PaiAgentInfo? {
        return self.agents.first(where: { $0.slug == slug })
    }

    public func agent(peerId: PeerId) -> PaiAgentInfo? {
        return self.agents.first(where: { paiAgentPeerId(slug: $0.slug) == peerId })
    }

    public func agent(thread: Int64) -> PaiAgentInfo? {
        return self.agents.first(where: { $0.threadId == thread })
    }
}

func currentPaiAgentsState(transaction: Transaction) -> PaiAgentsState {
    return transaction.getPreferencesEntry(key: PreferencesKeys.paiAgentsState)?.get(PaiAgentsState.self) ?? .empty
}

func updatePaiAgentsState(transaction: Transaction, _ f: (PaiAgentsState) -> PaiAgentsState) {
    transaction.updatePreferencesEntry(key: PreferencesKeys.paiAgentsState, { entry in
        return PreferencesEntry(f(entry?.get(PaiAgentsState.self) ?? .empty))
    })
}

/// Agent peers share the local `Email` namespace (a peer namespace is 3 bits, all taken) in an id range no email
/// contact reaches.
private let paiAgentIdBase: Int64 = 1 << 52

public extension PeerId {
    /// One of pai's agents: a local user peer, its profile; its chat is its topic in the pai bot's chat.
    var isPaiAgent: Bool {
        return self.namespace == Namespaces.Peer.Email && self.id._internalGetInt64Value() >= paiAgentIdBase
    }
}

public func paiAgentPeerId(slug: String) -> PeerId {
    let hash = UInt64(bitPattern: BoxMessageIds.globallyUniqueId(key: "pai-agent:\(slug)")) & 0xffffffff
    return PeerId(namespace: Namespaces.Peer.Email, id: PeerId.Id._internalFromInt64Value(paiAgentIdBase | Int64(hash)))
}

/// Where the app stores an agent's portrait, scaled down: pai serves 1024² PNGs over 1 MB, which reach the screens
/// cut at 1 MB when fetched as an `HttpReferenceMediaResource`.
public func paiAgentAvatarResource(url: String) -> LocalFileMediaResource {
    return LocalFileMediaResource(fileId: BoxMessageIds.globallyUniqueId(key: "pai-avatar:\(url)"))
}

/// The agent as a user peer: portrait as its photo, rewritten only when its name or picture changed. It is in no
/// chat list: it has no chat of its own.
func storePaiAgentPeer(transaction: Transaction, agent: PaiAgentInfo) {
    let peerId = paiAgentPeerId(slug: agent.slug)
    let picture: [TelegramMediaImageRepresentation] = agent.avatar.map { [TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 256, height: 256), resource: paiAgentAvatarResource(url: $0), progressiveSizes: [], immediateThumbnailData: nil)] } ?? []
    let current = transaction.getPeer(peerId) as? TelegramUser
    if current?.firstName != agent.name || current?.photo != picture {
        let user = TelegramUser(id: peerId, accessHash: nil, firstName: agent.name, lastName: nil, username: nil, phone: nil, photo: picture, botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
        transaction.updatePeersInternal([user], update: { _, updated in
            return updated
        })
    }
    if case .notIncluded = transaction.getPeerChatListInclusion(peerId) {
    } else {
        transaction.updatePeerChatListInclusion(peerId, inclusion: .notIncluded)
    }
}

/// An agent chat an earlier build kept on the device: its history goes and it leaves the chat list.
func clearPaiAgentChat(transaction: Transaction, slug: String) {
    let peerId = paiAgentPeerId(slug: slug)
    transaction.clearHistory(peerId, threadId: nil, minTimestamp: nil, maxTimestamp: nil, namespaces: .just([Namespaces.Message.Box]), forEachMedia: nil)
    if case .notIncluded = transaction.getPeerChatListInclusion(peerId) {
    } else {
        transaction.updatePeerChatListInclusion(peerId, inclusion: .notIncluded)
    }
}
