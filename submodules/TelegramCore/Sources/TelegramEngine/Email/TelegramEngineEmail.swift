import Foundation
import Postbox
import SwiftSignalKit

public extension TelegramEngine {
    /// Paigram's email chats: the box's correspondents as peers in the `Email` namespace.
    final class Email {
        private let account: Account
        
        init(account: Account) {
            self.account = account
        }
        
        /// Leaves the list this mail came from; the mail without its button follows in the change log.
        public func unsubscribe(messageId: EngineMessage.Id) -> Signal<Never, BoxError> {
            struct Body: Encodable {
                let account: String
                let id: String
            }
            struct Response: Decodable {
                let unsubscribed: Bool
            }
            return self.account.postbox.transaction { transaction -> Body? in
                return transaction.getMessage(messageId)?.attributes.compactMap({ $0 as? EmailMessageAttribute }).first.map { Body(account: $0.account, id: $0.gmailId) }
            }
            |> castError(BoxError.self)
            |> mapToSignal { body -> Signal<Never, BoxError> in
                guard let body else {
                    return .fail(.transport("the mail is gone"))
                }
                return (BoxClient.post("/gmail/unsubscribe", body: body) as Signal<Response, BoxError>)
                |> mapToSignal { _ -> Signal<Never, BoxError> in
                    requestEmailSync()
                    return .complete()
                }
            }
        }
        
        /// Reads the box's changes now (a push arrived, the app came to the front).
        public func syncNow() {
            requestEmailSync()
        }
        
        public func state() -> Signal<EmailState, NoError> {
            return self.account.postbox.preferencesView(keys: [PreferencesKeys.emailState])
            |> map { view -> EmailState in
                return view.values[PreferencesKeys.emailState]?.get(EmailState.self) ?? .empty
            }
            |> distinctUntilChanged
        }
        
        /// The chat for the box's contact `id` (a push names it so).
        public func peerId(contactId: Int64) -> EnginePeer.Id {
            return emailPeerId(contactId: contactId)
        }
        
        /// A chat with anyone by address, made on the box first so it has the same id everywhere; it is in the
        /// chat list from the start, since the user asked for it.
        /// A chat with an address; its first email goes out from `account` (a mailbox label) under `subject` when given.
        public func openChat(address: String, name: String, account: String? = nil, subject: String? = nil) -> Signal<EnginePeer.Id, BoxError> {
            struct Body: Encodable {
                let address: String
                let name: String
                let account: String?
                let subject: String?
            }
            let postbox = self.account.postbox
            return (BoxClient.post("/gmail/contacts", body: Body(address: address, name: name, account: account, subject: subject)) as Signal<EmailContactData, BoxError>)
            |> mapToSignal { contact -> Signal<EnginePeer.Id, BoxError> in
                return postbox.transaction { transaction -> EnginePeer.Id in
                    let peerId = storeEmailContact(transaction: transaction, contact: contact)
                    if case .notIncluded = transaction.getPeerChatListInclusion(peerId) {
                        transaction.updatePeerChatListInclusion(peerId, inclusion: .ifHasMessagesOrOneOf(groupId: Namespaces.PeerGroup.email, pinningIndex: nil, minTimestamp: Int32(Date().timeIntervalSince1970)))
                    }
                    return peerId
                }
                |> castError(BoxError.self)
            }
        }
    }
}
