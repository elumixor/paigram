import Foundation
import Postbox
import SwiftSignalKit

/// A message typed in a WhatsApp chat goes out through the box as him, one message per request: text as JSON, a
/// photo, video, voice message or file as a form with its caption. The box reads every send back out of the chat;
/// `unverified` (WhatsApp took it, the read-back did not show it) counts as sent, since it may well have arrived.

private struct TextBody: Encodable {
    let chatKind: String
    let chat: Int64
    let text: String
    let replyTo: String?
}

private struct Pending {
    let chatKind: String
    let chat: Int64
    let text: String
    let replyTo: String?
    let file: BoxOutgoingFile?
}

private func sendingEntry(_ id: MessageId) -> WhatsAppState.Sending {
    return WhatsAppState.Sending(peerId: id.peerId.toInt64(), id: id.id)
}

/// Stores the messages as sending; the caller starts `sendWhatsAppMessage` for each id once the transaction is done.
func enqueueWhatsAppMessages(transaction: Transaction, accountPeerId: PeerId, peerId: PeerId, messages: [EnqueueMessage]) -> [MessageId] {
    let ids = enqueueBoxMessages(transaction: transaction, accountPeerId: accountPeerId, peerId: peerId, messages: messages)
    updateWhatsAppState(transaction: transaction, { state in
        var state = state
        state.sending.append(contentsOf: ids.map(sendingEntry))
        return state
    })
    return ids
}

private func pending(transaction: Transaction, messageId: MessageId) -> Pending? {
    guard let message = transaction.getMessage(messageId) else {
        return nil
    }
    let key = whatsAppChatKey(messageId.peerId)
    let replyTo = message.attributes.compactMap { $0 as? ReplyMessageAttribute }.first.flatMap { reply in
        transaction.getMessage(reply.messageId)?.attributes.compactMap { $0 as? WhatsAppMessageAttribute }.first?.waId
    }.flatMap { $0.isEmpty ? nil : $0 }
    return Pending(chatKind: key.kind, chat: key.chat, text: message.text, replyTo: replyTo, file: message.media.lazy.compactMap(boxOutgoingFile).first)
}

/// What WhatsApp calls the file: a voice message plays as one, a photo or a video shows inline, anything else is a document.
private func kind(of file: BoxOutgoingFile) -> String {
    if let media = file.media as? TelegramMediaFile {
        if media.isVoice {
            return "voice"
        }
        return media.isVideo ? "video" : "document"
    }
    return "photo"
}

private func duration(of file: BoxOutgoingFile) -> Double? {
    return (file.media as? TelegramMediaFile)?.duration
}

private func send(mediaBox: MediaBox, pending: Pending) -> Signal<WhatsAppSendResponse?, NoError> {
    let request: Signal<WhatsAppSendResponse, BoxError>
    if let file = pending.file {
        request = boxFileData(mediaBox: mediaBox, resource: file.resource)
        |> castError(BoxError.self)
        |> mapToSignal { data -> Signal<WhatsAppSendResponse, BoxError> in
            guard let data else {
                return .fail(.transport("the file is not on this device"))
            }
            var fields = ["chatKind": pending.chatKind, "chat": "\(pending.chat)", "text": pending.text, "kind": kind(of: file)]
            fields["replyTo"] = pending.replyTo
            fields["duration"] = duration(of: file).map { "\(Int($0))" }
            return BoxClient.postMultipart("/whatsapp/send", fields: fields, file: BoxUpload(field: "file", fileName: file.name, mimeType: file.mimeType, data: data))
        }
    } else {
        request = BoxClient.post("/whatsapp/send", body: TextBody(chatKind: pending.chatKind, chat: pending.chat, text: pending.text, replyTo: pending.replyTo))
    }
    return request
    |> map(Optional.init)
    |> `catch` { error -> Signal<WhatsAppSendResponse?, NoError> in
        Logger.shared.log("WhatsApp", "send failed: \(error)")
        return .single(nil)
    }
}

private func settle(postbox: Postbox, messageId: MessageId, pending: Pending, response: WhatsAppSendResponse?) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> Void in
        transaction.updateMessage(messageId, update: { current in
            guard let response, response.state != "not_sent", let id = response.id else {
                if let note = response?.note {
                    Logger.shared.log("WhatsApp", "\(messageId) not sent: \(note)")
                }
                return updatedBoxMessage(current, flags: { $0.remove(.Sending); $0.insert(.Failed) })
            }
            let attributes = current.attributes.filter { !($0 is WhatsAppMessageAttribute) } + [WhatsAppMessageAttribute(waId: id)]
            return updatedBoxMessage(current, flags: { $0.remove(.Sending); $0.remove(.Failed) }, globallyUniqueId: whatsAppGloballyUniqueId(chatKind: pending.chatKind, chat: pending.chat, id: id), attributes: attributes)
        })
        updateWhatsAppState(transaction: transaction, { state in
            var state = state
            state.sending.removeAll(where: { $0 == sendingEntry(messageId) })
            return state
        })
    }
}

func sendWhatsAppMessage(postbox: Postbox, messageId: MessageId) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> Pending? in
        return pending(transaction: transaction, messageId: messageId)
    }
    |> mapToSignal { pending -> Signal<Void, NoError> in
        guard let pending else {
            return .complete()
        }
        return send(mediaBox: postbox.mediaBox, pending: pending)
        |> mapToSignal { response in
            return settle(postbox: postbox, messageId: messageId, pending: pending, response: response)
        }
    }
}

/// Failed sends tried again from the chat.
func resendWhatsAppMessages(postbox: Postbox, messageIds: [MessageId]) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> Void in
        markBoxMessagesSending(transaction: transaction, ids: messageIds)
    }
    |> mapToSignal { _ -> Signal<Void, NoError> in
        return combineLatest(messageIds.map { sendWhatsAppMessage(postbox: postbox, messageId: $0) |> then(.single(Void())) })
        |> map { _ in Void() }
    }
}

/// Sends the app quit in the middle of are failed.
func failInterruptedWhatsAppSends(postbox: Postbox) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> Void in
        let ids = currentWhatsAppState(transaction: transaction).sending.map { MessageId(peerId: PeerId($0.peerId), namespace: Namespaces.Message.Box, id: $0.id) }
        failBoxMessages(transaction: transaction, ids: ids)
        updateWhatsAppState(transaction: transaction, { state in
            var state = state
            state.sending = []
            return state
        })
    }
}
