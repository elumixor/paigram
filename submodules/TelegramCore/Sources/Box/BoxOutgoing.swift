import Foundation
import Postbox
import SwiftSignalKit

/// A message typed in a box chat goes out through the box, never through Telegram: it is stored as sending (not
/// unsent, so the pending-message machinery never sees it) and the box's answer settles it. These are the parts
/// email and WhatsApp share; each service sends its own way.

/// A file a box message carries, as the box needs it named and typed.
struct BoxOutgoingFile {
    let name: String
    let mimeType: String
    let resource: MediaResource
    let media: Media
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

/// Stores the messages as sending and returns their ids; the caller remembers them in its state and sends each
/// once the transaction is done.
func enqueueBoxMessages(transaction: Transaction, accountPeerId: PeerId, peerId: PeerId, messages: [EnqueueMessage]) -> [MessageId] {
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    return messages.map { message -> MessageId in
        let content = outgoingContent(transaction: transaction, message: message)
        let globallyUniqueId = Int64.random(in: Int64.min ... Int64.max)
        let id = BoxMessageIds.id(transaction: transaction, peerId: peerId, date: now, globallyUniqueId: globallyUniqueId)
        var attributes: [MessageAttribute] = [TextEntitiesMessageAttribute(entities: content.entities)]
        if let replyTo = content.replyTo {
            attributes.append(ReplyMessageAttribute(messageId: replyTo, threadMessageId: nil, quote: nil, isQuote: false, innerSubject: nil))
        }
        let (tags, globalTags) = tagsForStoreMessage(incoming: false, attributes: attributes, media: content.media, textEntities: content.entities, isPinned: false)
        let _ = transaction.addMessages([StoreMessage(id: id, customStableId: nil, globallyUniqueId: globallyUniqueId, groupingKey: nil, threadId: nil, timestamp: Int32(clamping: now / 1000), flags: [.Sending], tags: tags, globalTags: globalTags, localTags: [], forwardInfo: nil, authorId: accountPeerId, text: content.text, attributes: attributes, media: content.media)], location: .Random)
        return id
    }
}

/// The message as stored, its flags (and, once sent, its identity on the box) changed.
func updatedBoxMessage(_ current: Message, flags change: (inout StoreMessageFlags) -> Void, globallyUniqueId: Int64? = nil, attributes: [MessageAttribute]? = nil) -> PostboxUpdateMessage {
    var flags = StoreMessageFlags(current.flags)
    change(&flags)
    return .update(StoreMessage(id: current.id, customStableId: nil, globallyUniqueId: globallyUniqueId ?? current.globallyUniqueId, groupingKey: current.groupingKey, threadId: current.threadId, timestamp: current.timestamp, flags: flags, tags: current.tags, globalTags: current.globalTags, localTags: current.localTags, forwardInfo: current.forwardInfo.flatMap(StoreMessageForwardInfo.init), authorId: current.author?.id, text: current.text, attributes: attributes ?? current.attributes, media: current.media))
}

/// Messages that will not go out marked failed, so they show a retry rather than a clock forever.
func failBoxMessages(transaction: Transaction, ids: [MessageId]) {
    for id in ids where transaction.getMessage(id)?.flags.contains(.Sending) == true {
        transaction.updateMessage(id, update: { current in
            return updatedBoxMessage(current, flags: { $0.remove(.Sending); $0.insert(.Failed) })
        })
    }
}

/// Failed messages back to sending, before they are sent again.
func markBoxMessagesSending(transaction: Transaction, ids: [MessageId]) {
    for id in ids {
        transaction.updateMessage(id, update: { current in
            return updatedBoxMessage(current, flags: { $0.remove(.Failed); $0.insert(.Sending) })
        })
    }
}

func boxOutgoingFile(_ media: Media) -> BoxOutgoingFile? {
    if let file = media as? TelegramMediaFile {
        return BoxOutgoingFile(name: file.fileName ?? (file.isVoice ? "voice.ogg" : "file"), mimeType: file.mimeType, resource: file.resource, media: file)
    }
    if let image = media as? TelegramMediaImage, let largest = largestImageRepresentation(image.representations) {
        return BoxOutgoingFile(name: "photo.jpg", mimeType: "image/jpeg", resource: largest.resource, media: image)
    }
    return nil
}

/// A file's bytes, fetched first when they are not on the device yet (a photo still in the library); nil when unreadable.
func boxFileData(mediaBox: MediaBox, resource: MediaResource) -> Signal<Data?, NoError> {
    return Signal { subscriber in
        let fetch = mediaBox.fetchedResource(resource, parameters: nil).start()
        let read = (mediaBox.resourceData(resource, option: .complete(waitUntilFetchStatus: true))
        |> filter { $0.complete }
        |> take(1)).start(next: { data in
            subscriber.putNext(try? Data(contentsOf: URL(fileURLWithPath: data.path)))
            subscriber.putCompletion()
        })
        return ActionDisposable {
            fetch.dispose()
            read.dispose()
        }
    }
}
