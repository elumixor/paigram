import Foundation
import Postbox
import SwiftSignalKit

/// A message typed in an email chat goes out as an email through the box (`BoxOutgoing.swift`): a reply in its
/// thread when it answers one, its files attached.
private struct EmailSendBody: Encodable {
    struct ReplyTo: Encodable {
        let account: String
        let id: String
    }
    
    struct Attachment: Encodable {
        let name: String
        let mimeType: String
        let data: String
    }
    
    let contact: Int64
    let text: String
    let replyTo: ReplyTo?
    let attachments: [Attachment]
}

private struct PendingEmail {
    let body: EmailSendBody
    let files: [BoxOutgoingFile]
}

/// Stores the messages as sending; the caller starts `sendEmailMessage` for each id once the transaction is done.
func enqueueEmailMessages(transaction: Transaction, accountPeerId: PeerId, peerId: PeerId, messages: [EnqueueMessage]) -> [MessageId] {
    let ids = enqueueBoxMessages(transaction: transaction, accountPeerId: accountPeerId, peerId: peerId, messages: messages)
    updateEmailState(transaction: transaction, { state in
        var state = state
        state.sending.append(contentsOf: ids.map(sendingEntry))
        return state
    })
    return ids
}

private func sendingEntry(_ id: MessageId) -> EmailState.Sending {
    return EmailState.Sending(contact: id.peerId.id._internalGetInt64Value(), id: id.id)
}

private func pendingEmail(transaction: Transaction, messageId: MessageId) -> PendingEmail? {
    guard let message = transaction.getMessage(messageId) else {
        return nil
    }
    let replyTo = message.attributes.compactMap { $0 as? ReplyMessageAttribute }.first.flatMap { reply -> EmailSendBody.ReplyTo? in
        guard let email = transaction.getMessage(reply.messageId)?.attributes.compactMap({ $0 as? EmailMessageAttribute }).first, !email.gmailId.isEmpty else {
            return nil
        }
        return EmailSendBody.ReplyTo(account: email.account, id: email.gmailId)
    }
    let body = EmailSendBody(contact: messageId.peerId.id._internalGetInt64Value(), text: message.text, replyTo: replyTo, attachments: [])
    return PendingEmail(body: body, files: message.media.compactMap(boxOutgoingFile))
}

/// The files' bytes, fetched first when they are not on the device yet.
private func attachments(mediaBox: MediaBox, files: [BoxOutgoingFile]) -> Signal<[EmailSendBody.Attachment], NoError> {
    if files.isEmpty {
        return .single([])
    }
    return combineLatest(files.map { file -> Signal<EmailSendBody.Attachment?, NoError> in
        return boxFileData(mediaBox: mediaBox, resource: file.resource)
        |> map { data in data.map { EmailSendBody.Attachment(name: file.name, mimeType: file.mimeType, data: $0.base64EncodedString()) } }
    })
    |> map { $0.compactMap { $0 } }
}

private func settle(postbox: Postbox, accountPeerId: PeerId, messageId: MessageId, response: EmailMessageResponse?) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> Void in
        transaction.updateMessage(messageId, update: { current in
            guard let response else {
                return updatedBoxMessage(current, flags: { $0.remove(.Sending); $0.insert(.Failed) })
            }
            let attributes = current.attributes.filter { !($0 is EmailMessageAttribute) } + [emailAttribute(response.message, isPartial: false)]
            return updatedBoxMessage(current, flags: { $0.remove(.Sending); $0.remove(.Failed) }, globallyUniqueId: emailGloballyUniqueId(gmailId: response.message.id), attributes: attributes)
        })
        if let response {
            storeEmailContact(transaction: transaction, contact: response.contact)
            clearEmailReplyButtons(transaction: transaction, peerId: messageId.peerId)
        }
        updateEmailState(transaction: transaction, { state in
            var state = state
            state.sending.removeAll(where: { $0 == sendingEntry(messageId) })
            return state
        })
    }
}

func sendEmailMessage(postbox: Postbox, accountPeerId: PeerId, messageId: MessageId) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> PendingEmail? in
        return pendingEmail(transaction: transaction, messageId: messageId)
    }
    |> mapToSignal { pending -> Signal<Void, NoError> in
        guard let pending else {
            return .complete()
        }
        return attachments(mediaBox: postbox.mediaBox, files: pending.files)
        |> mapToSignal { files -> Signal<EmailMessageResponse?, NoError> in
            let body = EmailSendBody(contact: pending.body.contact, text: pending.body.text, replyTo: pending.body.replyTo, attachments: files)
            return (BoxClient.post("/gmail/send", body: body) as Signal<EmailMessageResponse, BoxError>)
            |> map(Optional.init)
            |> `catch` { error -> Signal<EmailMessageResponse?, NoError> in
                Logger.shared.log("Email", "send of \(messageId) failed: \(error)")
                return .single(nil)
            }
        }
        |> mapToSignal { response in
            return settle(postbox: postbox, accountPeerId: accountPeerId, messageId: messageId, response: response)
        }
    }
}

/// Failed sends tried again from the chat.
func resendEmailMessages(postbox: Postbox, accountPeerId: PeerId, messageIds: [MessageId]) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> Void in
        markBoxMessagesSending(transaction: transaction, ids: messageIds)
    }
    |> mapToSignal { _ -> Signal<Void, NoError> in
        return combineLatest(messageIds.map { sendEmailMessage(postbox: postbox, accountPeerId: accountPeerId, messageId: $0) |> then(.single(Void())) })
        |> map { _ in Void() }
    }
}

/// Sends the app quit in the middle of are failed, so they show a retry rather than a clock forever.
func failInterruptedEmailSends(postbox: Postbox) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> Void in
        let ids = currentEmailState(transaction: transaction).sending.map { MessageId(peerId: emailPeerId(contactId: $0.contact), namespace: Namespaces.Message.Box, id: $0.id) }
        for id in ids where transaction.getMessage(id)?.flags.contains(.Sending) == true {
            transaction.updateMessage(id, update: { current in
                return updatedBoxMessage(current, flags: { $0.remove(.Sending); $0.insert(.Failed) })
            })
        }
        updateEmailState(transaction: transaction, { state in
            var state = state
            state.sending = []
            return state
        })
    }
}
