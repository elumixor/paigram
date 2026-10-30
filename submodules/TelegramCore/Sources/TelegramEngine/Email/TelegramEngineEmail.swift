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
        public func openChat(address: String, name: String) -> Signal<EnginePeer.Id, EmailBoxError> {
            struct Body: Encodable {
                let address: String
                let name: String
            }
            let postbox = self.account.postbox
            return (EmailClient.post("/gmail/contacts", body: Body(address: address, name: name)) as Signal<EmailContactData, EmailBoxError>)
            |> mapToSignal { contact -> Signal<EnginePeer.Id, EmailBoxError> in
                return postbox.transaction { transaction -> EnginePeer.Id in
                    let peerId = storeEmailContact(transaction: transaction, contact: contact)
                    if case .notIncluded = transaction.getPeerChatListInclusion(peerId) {
                        transaction.updatePeerChatListInclusion(peerId, inclusion: .ifHasMessagesOrOneOf(groupId: .root, pinningIndex: nil, minTimestamp: Int32(Date().timeIntervalSince1970)))
                    }
                    return peerId
                }
                |> castError(EmailBoxError.self)
            }
        }
    }
}
