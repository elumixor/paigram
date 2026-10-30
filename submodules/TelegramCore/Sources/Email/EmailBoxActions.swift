import Foundation
import Postbox
import SwiftSignalKit

/// What the user does to an email chat that the mailbox has to know: deleting moves mail to the Trash (so other
/// mail clients lose it too), muting stops the box from pushing it.
private struct EmailTrashBody: Encodable {
    struct Item: Encodable {
        let account: String
        let id: String
    }
    
    let items: [Item]
}

private struct EmailTrashResponse: Decodable {
    let trashed: Int
}

/// The emails behind messages about to be deleted; read before the messages go.
func startTrashingEmails(transaction: Transaction, messageIds: [MessageId]) {
    var seen = Set<String>()
    let items = messageIds.filter { $0.peerId.isEmail }.compactMap { id -> EmailTrashBody.Item? in
        guard let email = transaction.getMessage(id)?.attributes.compactMap({ $0 as? EmailMessageAttribute }).first, !email.gmailId.isEmpty, seen.insert(email.gmailId).inserted else {
            return nil
        }
        return EmailTrashBody.Item(account: email.account, id: email.gmailId)
    }
    guard !items.isEmpty else {
        return
    }
    let _ = (EmailClient.post("/gmail/trash", body: EmailTrashBody(items: items)) as Signal<EmailTrashResponse, EmailBoxError>).startStandalone(error: { error in
        Logger.shared.log("Email", "trash failed: \(error)")
    })
}

private struct EmailMuteBody: Encodable {
    let contact: Int64
    let muted: Bool
}

/// An email chat's notification settings are this device's; whether it is muted is the box's too, since the
/// box sends its pushes.
func pushEmailNotificationSettings(postbox: Postbox, peerId: PeerId, settings: PeerNotificationSettings) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> Void in
        transaction.updateCurrentPeerNotificationSettings([peerId: settings])
        if let pending = transaction.getPendingPeerNotificationSettings(peerId), pending.isEqual(to: settings) {
            transaction.updatePendingPeerNotificationSettings(peerId: peerId, settings: nil)
        }
    }
    |> mapToSignal { _ -> Signal<Void, NoError> in
        guard let settings = settings as? TelegramPeerNotificationSettings else {
            return .complete()
        }
        var muted = false
        if case let .muted(until) = settings.muteState {
            muted = until > Int32(Date().timeIntervalSince1970)
        }
        return (EmailClient.post("/gmail/mute", body: EmailMuteBody(contact: peerId.id._internalGetInt64Value(), muted: muted)) as Signal<EmailContactData, EmailBoxError>)
        |> map { _ in Void() }
        |> `catch` { error -> Signal<Void, NoError> in
            Logger.shared.log("Email", "mute of \(peerId) failed: \(error)")
            return .complete()
        }
    }
}
