import Foundation
import Postbox
import SwiftSignalKit

/// A message typed in an email chat goes out as an email through the box, never through Telegram: it is stored
/// as sending (not unsent, so the pending-message machinery never sees it) and the box's answer settles it.
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
    let files: [(name: String, mimeType: String, resource: MediaResource)]
}

private func outgoingContent(transaction: Transaction, message: EnqueueMessage) -> (text: String, entities: [MessageTextEntity], media: [Media], replyTo: MessageId?) {
    switch message {
    case let .message(text, attributes, _, mediaReference, _, replyToMessageId, _, _, _, _):
        let entities = (attributes.first(where: { $0 is TextEntitiesMessageAttribute }) as? TextEntitiesMessageAttribute)?.entities ?? []
        return (text, entities, mediaReference.map { [$0.media] } ?? [], replyToMessageId?.messageId)
    case let .forward(source, _, _, _, _):
        let original = transaction.getMessage(source)
        return (original?.text ?? "", original?.textEntitiesAttribute?.entities ?? [], original?.media ?? [], nil)
    }
}

/// Stores the messages as sending; the caller starts `sendEmailMessage` for each id once the transaction is done.
func enqueueEmailMessages(transaction: Transaction, accountPeerId: PeerId, peerId: PeerId, messages: [EnqueueMessage]) -> [MessageId] {
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    let ids = messages.map { message -> MessageId in
        let content = outgoingContent(transaction: transaction, message: message)
        let globallyUniqueId = Int64.random(in: Int64.min ... Int64.max)
        let id = EmailMessageIds.id(transaction: transaction, peerId: peerId, date: now, globallyUniqueId: globallyUniqueId)
        var attributes: [MessageAttribute] = [TextEntitiesMessageAttribute(entities: content.entities)]
        if let replyTo = content.replyTo {
            attributes.append(ReplyMessageAttribute(messageId: replyTo, threadMessageId: nil, quote: nil, isQuote: false, innerSubject: nil))
        }
        let (tags, globalTags) = tagsForStoreMessage(incoming: false, attributes: attributes, media: content.media, textEntities: content.entities, isPinned: false)
        let _ = transaction.addMessages([StoreMessage(id: id, customStableId: nil, globallyUniqueId: globallyUniqueId, groupingKey: nil, threadId: nil, timestamp: Int32(clamping: now / 1000), flags: [.Sending], tags: tags, globalTags: globalTags, localTags: [], forwardInfo: nil, authorId: accountPeerId, text: content.text, attributes: attributes, media: content.media)], location: .Random)
        return id
    }
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

/// The message as stored, its flags (and, for a sent one, its Gmail identity) changed.
private func updated(_ current: Message, flags change: (inout StoreMessageFlags) -> Void, globallyUniqueId: Int64? = nil, attributes: [MessageAttribute]? = nil) -> PostboxUpdateMessage {
    var flags = StoreMessageFlags(current.flags)
    change(&flags)
    return .update(StoreMessage(id: current.id, customStableId: nil, globallyUniqueId: globallyUniqueId ?? current.globallyUniqueId, groupingKey: current.groupingKey, threadId: current.threadId, timestamp: current.timestamp, flags: flags, tags: current.tags, globalTags: current.globalTags, localTags: current.localTags, forwardInfo: current.forwardInfo.flatMap(StoreMessageForwardInfo.init), authorId: current.author?.id, text: current.text, attributes: attributes ?? current.attributes, media: current.media))
}

private func fileOf(_ media: Media) -> (name: String, mimeType: String, resource: MediaResource)? {
    if let file = media as? TelegramMediaFile {
        return (file.fileName ?? "file", file.mimeType, file.resource)
    }
    if let image = media as? TelegramMediaImage, let largest = largestImageRepresentation(image.representations) {
        return ("photo.jpg", "image/jpeg", largest.resource)
    }
    return nil
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
    return PendingEmail(body: body, files: message.media.compactMap(fileOf))
}

/// The files' bytes, fetched first when they are not on the device yet (a photo still in the library).
private func attachments(mediaBox: MediaBox, files: [(name: String, mimeType: String, resource: MediaResource)]) -> Signal<[EmailSendBody.Attachment], NoError> {
    if files.isEmpty {
        return .single([])
    }
    return combineLatest(files.map { file -> Signal<EmailSendBody.Attachment?, NoError> in
        return Signal { subscriber in
            let fetch = mediaBox.fetchedResource(file.resource, parameters: nil).start()
            let read = (mediaBox.resourceData(file.resource, option: .complete(waitUntilFetchStatus: true))
            |> filter { $0.complete }
            |> take(1)).start(next: { data in
                let bytes = try? Data(contentsOf: URL(fileURLWithPath: data.path))
                subscriber.putNext(bytes.map { EmailSendBody.Attachment(name: file.name, mimeType: file.mimeType, data: $0.base64EncodedString()) })
                subscriber.putCompletion()
            })
            return ActionDisposable {
                fetch.dispose()
                read.dispose()
            }
        }
    })
    |> map { $0.compactMap { $0 } }
}

private func settle(postbox: Postbox, accountPeerId: PeerId, messageId: MessageId, response: EmailMessageResponse?) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> Void in
        transaction.updateMessage(messageId, update: { current in
            guard let response else {
                return updated(current, flags: { $0.remove(.Sending); $0.insert(.Failed) })
            }
            let attributes = current.attributes.filter { !($0 is EmailMessageAttribute) } + [emailAttribute(response.message, isPartial: false)]
            return updated(current, flags: { $0.remove(.Sending); $0.remove(.Failed) }, globallyUniqueId: EmailMessageIds.globallyUniqueId(gmailId: response.message.id), attributes: attributes)
        })
        if let response {
            storeEmailContact(transaction: transaction, contact: response.contact)
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
            return (EmailClient.post("/gmail/send", body: body) as Signal<EmailMessageResponse, EmailBoxError>)
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
        for id in messageIds {
            transaction.updateMessage(id, update: { current in
                return updated(current, flags: { $0.remove(.Failed); $0.insert(.Sending) })
            })
        }
    }
    |> mapToSignal { _ -> Signal<Void, NoError> in
        return combineLatest(messageIds.map { sendEmailMessage(postbox: postbox, accountPeerId: accountPeerId, messageId: $0) |> then(.single(Void())) })
        |> map { _ in Void() }
    }
}

/// Sends the app quit in the middle of are failed, so they show a retry rather than a clock forever.
func failInterruptedEmailSends(postbox: Postbox) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> Void in
        let ids = currentEmailState(transaction: transaction).sending.map { MessageId(peerId: emailPeerId(contactId: $0.contact), namespace: Namespaces.Message.Email, id: $0.id) }
        for id in ids where transaction.getMessage(id)?.flags.contains(.Sending) == true {
            transaction.updateMessage(id, update: { current in
                return updated(current, flags: { $0.remove(.Sending); $0.insert(.Failed) })
            })
        }
        updateEmailState(transaction: transaction, { state in
            var state = state
            state.sending = []
            return state
        })
    }
}
