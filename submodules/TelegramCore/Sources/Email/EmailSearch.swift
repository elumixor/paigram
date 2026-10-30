import Foundation
import Postbox
import SwiftSignalKit

/// Gmail's own search through the box: mail that was never loaded on this device is stored in its chat, so the
/// local search that runs after it finds it like any other message. Emits once, when that is done (or failed).
func emailBoxSearch(postbox: Postbox, accountPeerId: PeerId, query: String, peerId: PeerId?) -> Signal<Void, NoError> {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard EmailBox.configuration != nil, trimmed.count >= 2 else {
        return .single(Void())
    }
    var parameters = ["q": trimmed]
    if let peerId {
        parameters["contact"] = "\(peerId.id._internalGetInt64Value())"
    }
    return (EmailClient.get("/gmail/search", query: parameters) as Signal<EmailSearchResponse, EmailBoxError>)
    |> map(Optional.init)
    |> `catch` { error -> Signal<EmailSearchResponse?, NoError> in
        Logger.shared.log("Email", "search failed: \(error)")
        return .single(nil)
    }
    |> mapToSignal { response -> Signal<Void, NoError> in
        guard let response else {
            return .single(Void())
        }
        return postbox.transaction { transaction -> Void in
            rememberEmailContacts(transaction: transaction, response.results.compactMap(\.contact))
            for result in response.results {
                guard let contact = result.contact else {
                    continue
                }
                let peerId = storeEmailContactPeer(transaction: transaction, contact: contact)
                storeEmailMessage(transaction: transaction, accountPeerId: accountPeerId, peerId: peerId, data: result.message)
                resetEmailReadState(transaction: transaction, peerId: peerId, contact: contact)
            }
        }
    }
}
