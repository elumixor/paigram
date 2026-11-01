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
    public static let currentTextVersion: Int32 = 1
    
    public var seq: Int64
    public var accounts: [EmailAccountData]
    public var contacts: [Contact]
    public var sending: [Sending]
    /// The `currentTextVersion` the stored mail was drawn with; 0 before there was one.
    public var textVersion: Int32
    
    public static let empty = EmailState(seq: 0, accounts: [], contacts: [], sending: [], textVersion: EmailState.currentTextVersion)
    
    private enum CodingKeys: String, CodingKey {
        case seq, accounts, contacts, sending, textVersion
    }
    
    init(seq: Int64, accounts: [EmailAccountData], contacts: [Contact], sending: [Sending], textVersion: Int32) {
        self.seq = seq
        self.accounts = accounts
        self.contacts = contacts
        self.sending = sending
        self.textVersion = textVersion
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.seq = try container.decode(Int64.self, forKey: .seq)
        self.accounts = try container.decode([EmailAccountData].self, forKey: .accounts)
        self.contacts = try container.decode([Contact].self, forKey: .contacts)
        self.sending = try container.decode([Sending].self, forKey: .sending)
        self.textVersion = try container.decodeIfPresent(Int32.self, forKey: .textVersion) ?? 0
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

/// Message ids in an email chat follow the date: minutes since 2000, with 64 slots for mail sent in the same
/// minute. History holes are id ranges, so this is what lets a hole stand for "mail before this date".
enum EmailMessageIds {
    private static let epoch: Int64 = 946_684_800
    private static let slots: Int64 = 64
    
    static func base(date: Int64) -> Int32 {
        let minutes = max(1, (date / 1000 - self.epoch) / 60)
        return Int32(clamping: minutes * self.slots)
    }
    
    /// The first date after every message an id up to `id` can have; nil for the top of the range (no limit).
    static func dateAfter(id: Int32) -> Int64? {
        if id >= Int32.max - 1 {
            return nil
        }
        return ((Int64(id) / self.slots + 1) * 60 + self.epoch) * 1000
    }
    
    /// Gmail's 64-bit hex message id, which every copy of a message is found by.
    static func globallyUniqueId(gmailId: String) -> Int64 {
        return Int64(bitPattern: UInt64(gmailId, radix: 16) ?? UInt64(truncatingIfNeeded: gmailId.hashValue))
    }
    
    /// A free id for mail of `date`, or the one the message already has.
    static func id(transaction: Transaction, peerId: PeerId, date: Int64, globallyUniqueId: Int64) -> MessageId {
        if let existing = transaction.messageIdForGloballyUniqueMessageId(peerId: peerId, id: globallyUniqueId) {
            return existing
        }
        let base = self.base(date: date)
        for slot in 0 ..< Int32(self.slots) {
            let id = MessageId(peerId: peerId, namespace: Namespaces.Message.Email, id: base + slot)
            if transaction.getMessage(id) == nil {
                return id
            }
        }
        return MessageId(peerId: peerId, namespace: Namespaces.Message.Email, id: base + Int32(self.slots) - 1)
    }
}

public extension PeerId {
    var isEmail: Bool {
        return self.namespace == Namespaces.Peer.Email
    }
}

func emailPeerId(contactId: Int64) -> PeerId {
    return PeerId(namespace: Namespaces.Peer.Email, id: PeerId.Id._internalFromInt64Value(contactId))
}

/// The chat for a correspondent: its peer and whether it is in the chat list, as the box says. Its address is
/// remembered by `rememberEmailContacts`, once for a whole batch, and its unread count is set by
/// `resetEmailReadState` after its messages are stored (storing an incoming message counts it as unread).
@discardableResult
func storeEmailContactPeer(transaction: Transaction, contact: EmailContactData) -> PeerId {
    let peerId = emailPeerId(contactId: contact.id)
    let name = contact.name.isEmpty ? contact.address : contact.name
    if (transaction.getPeer(peerId) as? TelegramUser)?.firstName != name {
        let user = TelegramUser(id: peerId, accessHash: nil, firstName: name, lastName: nil, username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
        transaction.updatePeersInternal([user], update: { _, updated in
            return updated
        })
    }
    switch transaction.getPeerChatListInclusion(peerId) {
    case .notIncluded:
        if contact.included {
            transaction.updatePeerChatListInclusion(peerId, inclusion: .ifHasMessagesOrOneOf(groupId: .root, pinningIndex: nil, minTimestamp: nil))
        }
    case let .ifHasMessagesOrOneOf(_, pinningIndex, _):
        if !contact.included && pinningIndex == nil {
            transaction.updatePeerChatListInclusion(peerId, inclusion: .notIncluded)
        }
    }
    return peerId
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

/// The box counts what is unread; the read line sits just before its oldest unread message.
func resetEmailReadState(transaction: Transaction, peerId: PeerId, contact: EmailContactData) {
    let maxIncomingReadIndex: MessageIndex
    if contact.unread > 0, let oldest = contact.oldestUnread {
        maxIncomingReadIndex = MessageIndex(id: MessageId(peerId: peerId, namespace: Namespaces.Message.Email, id: EmailMessageIds.base(date: oldest) - 1), timestamp: Int32(clamping: oldest / 1000) - 1)
    } else {
        maxIncomingReadIndex = MessageIndex.upperBound(peerId: peerId, namespace: Namespaces.Message.Email)
    }
    // Mail has no read receipts: what went out shows as read.
    let state = PeerReadState.indexBased(maxIncomingReadIndex: maxIncomingReadIndex, maxOutgoingReadIndex: MessageIndex.upperBound(peerId: peerId, namespace: Namespaces.Message.Email), count: contact.unread, markedUnread: false)
    if transaction.getPeerReadStates(peerId)?.first(where: { $0.0 == Namespaces.Message.Email })?.1 != state {
        transaction.resetIncomingReadStates([peerId: [Namespaces.Message.Email: state]])
    }
}
