import Foundation
import Postbox
import SwiftSignalKit

/// What this device keeps of the box: where it has read the change log up to, the mailboxes, and each email
/// chat's address (the peer is a `TelegramUser`, which has nowhere to hold one).
public struct EmailState: Codable, Equatable {
    public struct Contact: Codable, Equatable {
        public let id: Int64
        public let address: String
        public let name: String
    }
    
    /// A send started and not answered yet: one the app quit in the middle of is failed at start.
    public struct Sending: Codable, Equatable {
        public let contact: Int64
        public let id: Int32
    }
    
    /// How the box draws a message's text; raised when that changes, so mail stored the old way is fetched again.
    public static let currentTextVersion: Int32 = 6
    
    public var seq: Int64
    public var accounts: [EmailAccountData]
    public var contacts: [Contact]
    public var sending: [Sending]
    /// The `currentTextVersion` the stored mail was drawn with; 0 before there was one.
    public var textVersion: Int32
    /// Whether the chats stored before the Email row existed have moved behind it.
    public var movedToEmailGroup: Bool
    
    public static let empty = EmailState(seq: 0, accounts: [], contacts: [], sending: [], textVersion: EmailState.currentTextVersion, movedToEmailGroup: true)
    
    private enum CodingKeys: String, CodingKey {
        case seq, accounts, contacts, sending, textVersion, movedToEmailGroup
    }
    
    init(seq: Int64, accounts: [EmailAccountData], contacts: [Contact], sending: [Sending], textVersion: Int32, movedToEmailGroup: Bool) {
        self.seq = seq
        self.accounts = accounts
        self.contacts = contacts
        self.sending = sending
        self.textVersion = textVersion
        self.movedToEmailGroup = movedToEmailGroup
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.seq = try container.decode(Int64.self, forKey: .seq)
        self.accounts = try container.decode([EmailAccountData].self, forKey: .accounts)
        self.contacts = try container.decode([Contact].self, forKey: .contacts)
        self.sending = try container.decode([Sending].self, forKey: .sending)
        self.textVersion = try container.decodeIfPresent(Int32.self, forKey: .textVersion) ?? 0
        self.movedToEmailGroup = try container.decodeIfPresent(Bool.self, forKey: .movedToEmailGroup) ?? false
    }
    
    public func contact(id: Int64) -> Contact? {
        return self.contacts.first(where: { $0.id == id })
    }
}

func currentEmailState(transaction: Transaction) -> EmailState {
    return transaction.getPreferencesEntry(key: PreferencesKeys.emailState)?.get(EmailState.self) ?? .empty
}

func updateEmailState(transaction: Transaction, _ f: (EmailState) -> EmailState) {
    transaction.updatePreferencesEntry(key: PreferencesKeys.emailState, { entry in
        return PreferencesEntry(f(entry?.get(EmailState.self) ?? .empty))
    })
}

/// Gmail's 64-bit hex message id, which every copy of a message is found by.
func emailGloballyUniqueId(gmailId: String) -> Int64 {
    return UInt64(gmailId, radix: 16).map { Int64(bitPattern: $0) } ?? BoxMessageIds.globallyUniqueId(key: "gmail:\(gmailId)")
}

public extension PeerId {
    var isEmail: Bool {
        return self.namespace == Namespaces.Peer.Email
    }
}

func emailPeerId(contactId: Int64) -> PeerId {
    return PeerId(namespace: Namespaces.Peer.Email, id: PeerId.Id._internalFromInt64Value(contactId))
}

/// The box's square JPEG of a correspondent, fetched over plain HTTP like an attachment.
private func emailContactPhoto(avatar: String?) -> [TelegramMediaImageRepresentation] {
    guard let avatar, let url = EmailBox.avatarURL(hash: avatar) else {
        return []
    }
    let side = 256
    return [TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: Int32(side), height: Int32(side)), resource: HttpReferenceMediaResource(url: url, size: nil), progressiveSizes: [], immediateThumbnailData: nil)]
}

/// The chat for a correspondent: its peer and whether it is in the chat list, as the box says. Its address is
/// remembered by `rememberEmailContacts`, once for a whole batch, and its unread count is set by
/// `resetEmailReadState` after its messages are stored (storing an incoming message counts it as unread).
@discardableResult
func storeEmailContactPeer(transaction: Transaction, contact: EmailContactData) -> PeerId {
    let peerId = emailPeerId(contactId: contact.id)
    let name = contact.name.isEmpty ? contact.address : contact.name
    let photo = emailContactPhoto(avatar: contact.avatar)
    let current = transaction.getPeer(peerId) as? TelegramUser
    if current?.firstName != name || current?.photo != photo {
        let user = TelegramUser(id: peerId, accessHash: nil, firstName: name, lastName: nil, username: nil, phone: nil, photo: photo, botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
        transaction.updatePeersInternal([user], update: { _, updated in
            return updated
        })
    }
    switch transaction.getPeerChatListInclusion(peerId) {
    case .notIncluded:
        if contact.included {
            transaction.updatePeerChatListInclusion(peerId, inclusion: .ifHasMessagesOrOneOf(groupId: Namespaces.PeerGroup.email, pinningIndex: nil, minTimestamp: nil))
        }
    case let .ifHasMessagesOrOneOf(_, pinningIndex, _):
        if !contact.included && pinningIndex == nil {
            transaction.updatePeerChatListInclusion(peerId, inclusion: .notIncluded)
        } else {
            moveEmailChatToGroup(transaction: transaction, peerId: peerId)
        }
    }
    return peerId
}

/// A chat in the main list goes behind the Email row; one the user archived stays archived.
private func moveEmailChatToGroup(transaction: Transaction, peerId: PeerId) {
    if case let .ifHasMessagesOrOneOf(groupId, pinningIndex, minTimestamp) = transaction.getPeerChatListInclusion(peerId), groupId == .root {
        transaction.updatePeerChatListInclusion(peerId, inclusion: .ifHasMessagesOrOneOf(groupId: Namespaces.PeerGroup.email, pinningIndex: pinningIndex, minTimestamp: minTimestamp))
    }
}

/// Once, for the chats this device stored in the main list.
func moveStoredEmailChatsToGroup(transaction: Transaction) {
    let state = currentEmailState(transaction: transaction)
    guard !state.movedToEmailGroup else {
        return
    }
    for contact in state.contacts {
        moveEmailChatToGroup(transaction: transaction, peerId: emailPeerId(contactId: contact.id))
    }
    updateEmailState(transaction: transaction, { state in
        var state = state
        state.movedToEmailGroup = true
        return state
    })
}

/// The addresses of these chats, for their titles.
func rememberEmailContacts(transaction: Transaction, _ contacts: [EmailContactData]) {
    guard !contacts.isEmpty else {
        return
    }
    let current = currentEmailState(transaction: transaction).contacts
    var byId = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    for contact in contacts {
        byId[contact.id] = EmailState.Contact(id: contact.id, address: contact.address, name: contact.name)
    }
    let updated = byId.values.sorted(by: { $0.id < $1.id })
    if updated != current {
        updateEmailState(transaction: transaction, { state in
            var state = state
            state.contacts = updated
            return state
        })
    }
}

/// One chat stored, remembered and counted.
@discardableResult
func storeEmailContact(transaction: Transaction, contact: EmailContactData) -> PeerId {
    let peerId = storeEmailContactPeer(transaction: transaction, contact: contact)
    rememberEmailContacts(transaction: transaction, [contact])
    resetEmailReadState(transaction: transaction, peerId: peerId, contact: contact)
    return peerId
}

/// The box counts what is unread; mail has no read receipts.
func resetEmailReadState(transaction: Transaction, peerId: PeerId, contact: EmailContactData) {
    resetBoxReadState(transaction: transaction, peerId: peerId, unread: contact.unread, oldestUnread: contact.oldestUnread)
}
