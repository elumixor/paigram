import Foundation
import Postbox

/// What this device knows of the box's WhatsApp beyond the peers: where its change log was read up to, who "me"
/// is there (his own messages show as his), the people's numbers (a DM's subtitle) and the messages on their way.
public struct WhatsAppState: Codable, Equatable {
    public struct Sending: Codable, Equatable {
        public let peerId: Int64
        public let id: Int32
    }

    public var seq: Int64
    /// His own person id on the box; nil until WhatsApp says who he is.
    public var me: Int64?
    /// Person id → phone number, for the people that have one.
    public var phones: [Int64: String]
    public var sending: [Sending]

    public static let empty = WhatsAppState(seq: 0, me: nil, phones: [:], sending: [])
}

func currentWhatsAppState(transaction: Transaction) -> WhatsAppState {
    return transaction.getPreferencesEntry(key: PreferencesKeys.whatsAppState)?.get(WhatsAppState.self) ?? .empty
}

func updateWhatsAppState(transaction: Transaction, _ f: (WhatsAppState) -> WhatsAppState) {
    transaction.updatePreferencesEntry(key: PreferencesKeys.whatsAppState, { entry in
        return PreferencesEntry(f(entry?.get(WhatsAppState.self) ?? .empty))
    })
}

public extension PeerId {
    /// A WhatsApp person or group, synced through the box.
    var isWhatsApp: Bool {
        return self.namespace == Namespaces.Peer.WhatsApp || self.namespace == Namespaces.Peer.WhatsAppGroup
    }

    var isWhatsAppGroup: Bool {
        return self.namespace == Namespaces.Peer.WhatsAppGroup
    }
}

func whatsAppPersonPeerId(_ id: Int64) -> PeerId {
    return PeerId(namespace: Namespaces.Peer.WhatsApp, id: PeerId.Id._internalFromInt64Value(id))
}

func whatsAppChatPeerId(kind: String, id: Int64) -> PeerId {
    return PeerId(namespace: kind == "group" ? Namespaces.Peer.WhatsAppGroup : Namespaces.Peer.WhatsApp, id: PeerId.Id._internalFromInt64Value(id))
}

/// The box's key for a chat: what its routes take.
func whatsAppChatKey(_ peerId: PeerId) -> (kind: String, chat: Int64) {
    return (peerId.isWhatsAppGroup ? "group" : "dm", peerId.id._internalGetInt64Value())
}

private func photo(url: String?) -> [TelegramMediaImageRepresentation] {
    guard let url else {
        return []
    }
    return [TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 256, height: 256), resource: HttpReferenceMediaResource(url: url, size: nil), progressiveSizes: [], immediateThumbnailData: nil)]
}

/// A person as a user peer, rewritten only when their name or picture changed.
func storeWhatsAppPerson(transaction: Transaction, person: WhatsAppPersonData) {
    let peerId = whatsAppPersonPeerId(person.id)
    let picture = photo(url: person.avatar.flatMap { WhatsAppBox.avatarURL(person: person.id, hash: $0) })
    let current = transaction.getPeer(peerId) as? TelegramUser
    if current?.firstName != person.name || current?.photo != picture {
        let user = TelegramUser(id: peerId, accessHash: nil, firstName: person.name, lastName: nil, username: nil, phone: nil, photo: picture, botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
        transaction.updatePeersInternal([user], update: { _, updated in
            return updated
        })
    }
}

func rememberWhatsAppPeople(transaction: Transaction, _ people: [WhatsAppPersonData]) {
    for person in people {
        storeWhatsAppPerson(transaction: transaction, person: person)
    }
    let phones = people.compactMap { person in person.phone.map { (person.id, $0) } }
    guard !phones.isEmpty else {
        return
    }
    updateWhatsAppState(transaction: transaction, { state in
        var state = state
        for (id, phone) in phones {
            state.phones[id] = phone
        }
        return state
    })
}

/// A chat's peer (a group's own; a DM's is its person, stored with the people), its place in the list (WhatsApp's
/// archive is the archive here) and its mute; its unread count is set once its messages are stored, since storing
/// an incoming message counts it as unread.
@discardableResult
func storeWhatsAppChatPeer(transaction: Transaction, chat: WhatsAppChatData) -> PeerId {
    let peerId = whatsAppChatPeerId(kind: chat.kind, id: chat.id)
    if chat.isGroup {
        let picture = photo(url: chat.avatar.flatMap { WhatsAppBox.avatarURL(group: chat.id, hash: $0) })
        let current = transaction.getPeer(peerId) as? TelegramGroup
        let participantCount = chat.participants?.count ?? current?.participantCount ?? 0
        if current?.title != chat.title || current?.photo != picture || current?.participantCount != participantCount {
            let group = TelegramGroup(id: peerId, title: chat.title, photo: picture, participantCount: participantCount, role: .member, membership: .Member, flags: [], defaultBannedRights: nil, migrationReference: nil, creationDate: 0, version: 0)
            transaction.updatePeersInternal([group], update: { _, updated in
                return updated
            })
        }
    } else if transaction.getPeer(peerId) == nil {
        storeWhatsAppPerson(transaction: transaction, person: WhatsAppPersonData(id: chat.id, jid: chat.jid, phone: nil, name: chat.title, avatar: chat.avatar))
    }
    let groupId: PeerGroupId = chat.archived ? Namespaces.PeerGroup.archive : .root
    if case let .ifHasMessagesOrOneOf(currentGroupId, pinningIndex, minTimestamp) = transaction.getPeerChatListInclusion(peerId) {
        if currentGroupId != groupId {
            transaction.updatePeerChatListInclusion(peerId, inclusion: .ifHasMessagesOrOneOf(groupId: groupId, pinningIndex: pinningIndex, minTimestamp: minTimestamp))
        }
    } else {
        transaction.updatePeerChatListInclusion(peerId, inclusion: .ifHasMessagesOrOneOf(groupId: groupId, pinningIndex: nil, minTimestamp: nil))
    }
    let settings = (transaction.getPeerNotificationSettings(id: peerId) as? TelegramPeerNotificationSettings) ?? .defaultSettings
    let muteState: PeerMuteState = chat.muted ? .muted(until: Int32.max) : .default
    if settings.muteState != muteState {
        transaction.updateCurrentPeerNotificationSettings([peerId: settings.withUpdatedMuteState(muteState)])
    }
    return peerId
}

/// A chat WhatsApp no longer has (a person found to be someone already known, a deleted chat): out of the list, emptied.
func removeWhatsAppChat(transaction: Transaction, peerId: PeerId) {
    transaction.updatePeerChatListInclusion(peerId, inclusion: .notIncluded)
    transaction.clearHistory(peerId, threadId: nil, minTimestamp: nil, maxTimestamp: nil, namespaces: .just([Namespaces.Message.Box]), forEachMedia: nil)
}
