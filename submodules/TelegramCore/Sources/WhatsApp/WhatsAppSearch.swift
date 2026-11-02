import Foundation
import Postbox
import SwiftSignalKit

/// The box's search over every WhatsApp message it has seen: what was never loaded on this device is stored in its
/// chat, so the local search that runs after it finds it like any other message. Emits once, when that is done.
func whatsAppBoxSearch(postbox: Postbox, accountPeerId: PeerId, query: String, peerId: PeerId?) -> Signal<Void, NoError> {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard PaiBox.configuration != nil, trimmed.count >= 2 else {
        return .single(Void())
    }
    var parameters = ["q": trimmed]
    if let peerId {
        let key = whatsAppChatKey(peerId)
        parameters["chatKind"] = key.kind
        parameters["chat"] = "\(key.chat)"
    }
    return (BoxClient.get("/whatsapp/search", query: parameters) as Signal<WhatsAppPageResponse, BoxError>)
    |> map(Optional.init)
    |> `catch` { error -> Signal<WhatsAppPageResponse?, NoError> in
        Logger.shared.log("WhatsApp", "search failed: \(error)")
        return .single(nil)
    }
    |> mapToSignal { response -> Signal<Void, NoError> in
        guard let response else {
            return .single(Void())
        }
        return postbox.transaction { transaction -> Void in
            rememberWhatsAppPeople(transaction: transaction, response.people)
            for message in response.messages {
                storeWhatsAppMessage(transaction: transaction, mediaBox: postbox.mediaBox, accountPeerId: accountPeerId, data: message)
            }
        }
    }
}
