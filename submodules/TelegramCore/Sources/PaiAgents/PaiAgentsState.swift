import Foundation
import Postbox

/// One of pai's agents as the app knows it from `/agents`; the app hands the list over (`TelegramEngine.PaiAgents.update`),
/// so TelegramCore never reads that route itself.
public struct PaiAgentInfo: Codable, Equatable {
    public let slug: String
    public let name: String
    /// The line under the chat's title.
    public let role: String?
    /// An absolute address of the agent's portrait.
    public let avatar: String?
    public let parent: String?
    /// A Telegram bot topic the agent talks in; its chat here redirects there.
    public let threadId: Int64?
    /// Closed or done: out of the list.
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

/// What this device knows of pai's agents beyond the peers: the agents, how far the message log was read, which
/// chats already have their history started, and the messages on their way.
public struct PaiAgentsState: Codable, Equatable {
    public struct Sending: Codable, Equatable {
        public let peerId: Int64
        public let id: Int32
    }

    public var agents: [PaiAgentInfo]
    /// The newest row of `/messages` stored; 0 until the first sync.
    public var maxId: Int32
    /// Agents whose chat has a hole for its history and its newest page stored.
    public var seeded: [String]
    public var sending: [Sending]

    public static let empty = PaiAgentsState(agents: [], maxId: 0, seeded: [], sending: [])

    public func agent(slug: String) -> PaiAgentInfo? {
        return self.agents.first(where: { $0.slug == slug })
    }

    public func agent(peerId: PeerId) -> PaiAgentInfo? {
        return self.agents.first(where: { paiAgentPeerId(slug: $0.slug) == peerId })
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
    /// One of pai's agents: a local user peer whose chat is pai's message log.
    var isPaiAgent: Bool {
        return self.namespace == Namespaces.Peer.Email && self.id._internalGetInt64Value() >= paiAgentIdBase
    }
}

public func paiAgentPeerId(slug: String) -> PeerId {
    let hash = UInt64(bitPattern: BoxMessageIds.globallyUniqueId(key: "pai-agent:\(slug)")) & 0xffffffff
    return PeerId(namespace: Namespaces.Peer.Email, id: PeerId.Id._internalFromInt64Value(paiAgentIdBase | Int64(hash)))
}

/// The agent as a user peer: portrait as its photo, rewritten only when its name or picture changed.
func storePaiAgentPeer(transaction: Transaction, agent: PaiAgentInfo) {
    let peerId = paiAgentPeerId(slug: agent.slug)
    let picture: [TelegramMediaImageRepresentation] = agent.avatar.map { [TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 256, height: 256), resource: HttpReferenceMediaResource(url: $0, size: nil), progressiveSizes: [], immediateThumbnailData: nil)] } ?? []
    let current = transaction.getPeer(peerId) as? TelegramUser
    if current?.firstName != agent.name || current?.photo != picture {
        let user = TelegramUser(id: peerId, accessHash: nil, firstName: agent.name, lastName: nil, username: nil, phone: nil, photo: picture, botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
        transaction.updatePeersInternal([user], update: { _, updated in
            return updated
        })
    }
    if current == nil {
        // Agents talk a lot: their chats count, but quietly, under the pai row.
        let settings = (transaction.getPeerNotificationSettings(id: peerId) as? TelegramPeerNotificationSettings) ?? .defaultSettings
        transaction.updateCurrentPeerNotificationSettings([peerId: settings.withUpdatedMuteState(.muted(until: Int32.max))])
    }
    let inclusion: PeerChatListInclusion
    if agent.closed {
        inclusion = .notIncluded
    } else {
        let pinningIndex: UInt16? = agent.slug == "pai" ? 0 : nil
        inclusion = .ifHasMessagesOrOneOf(groupId: Namespaces.PeerGroup.pai, pinningIndex: pinningIndex, minTimestamp: Int32(Date().timeIntervalSince1970))
    }
    switch (transaction.getPeerChatListInclusion(peerId), inclusion) {
    case (.notIncluded, .notIncluded):
        break
    case let (.ifHasMessagesOrOneOf(groupId, pinningIndex, _), .ifHasMessagesOrOneOf(_, newPinningIndex, _)) where groupId == Namespaces.PeerGroup.pai && pinningIndex == newPinningIndex:
        break
    case let (.ifHasMessagesOrOneOf(groupId, _, _), .ifHasMessagesOrOneOf):
        // Archived by hand: it stays there.
        if groupId != Namespaces.PeerGroup.pai && groupId != .root {
            break
        }
        transaction.updatePeerChatListInclusion(peerId, inclusion: inclusion)
    default:
        transaction.updatePeerChatListInclusion(peerId, inclusion: inclusion)
    }
}
