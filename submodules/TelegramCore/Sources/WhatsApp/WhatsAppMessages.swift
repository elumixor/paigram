import Foundation
import Postbox

/// WhatsApp messages as chat messages: its markup as bold, italic, strikethrough and code, links tappable; photos,
/// videos, voice messages, files and stickers fetched from the box when shown, their small preview drawn at once.

func whatsAppGloballyUniqueId(chatKind: String, chat: Int64, id: String) -> Int64 {
    return BoxMessageIds.globallyUniqueId(key: "wa:\(chatKind):\(chat):\(id)")
}

private func entity(_ data: WhatsAppEntityData, length: Int) -> MessageTextEntity? {
    let range = data.offset ..< data.offset + data.length
    guard data.offset >= 0, data.length > 0, range.upperBound <= length else {
        return nil
    }
    switch data.type {
    case "bold":
        return MessageTextEntity(range: range, type: .Bold)
    case "italic":
        return MessageTextEntity(range: range, type: .Italic)
    case "strike":
        return MessageTextEntity(range: range, type: .Strikethrough)
    case "code":
        return MessageTextEntity(range: range, type: .Code)
    default:
        return nil
    }
}

/// The box's small preview, stored as the picture's first representation so the bubble has something at once.
private func thumbnail(_ media: WhatsAppMediaData, globallyUniqueId: Int64, mediaBox: MediaBox) -> TelegramMediaImageRepresentation? {
    guard let base64 = media.thumbnail, let data = Data(base64Encoded: base64), let width = media.width, let height = media.height, width > 0, height > 0 else {
        return nil
    }
    let resource = LocalFileMediaResource(fileId: globallyUniqueId &+ 1)
    mediaBox.storeResourceData(resource.id, data: data)
    let scale = max(1, max(width, height) / 90)
    return TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: width / scale, height: height / scale), resource: resource, progressiveSizes: [], immediateThumbnailData: nil)
}

private func media(_ data: WhatsAppMessageData, globallyUniqueId: Int64, mediaBox: MediaBox) -> Media? {
    guard let media = data.media, let url = WhatsAppBox.mediaURL(chatKind: data.chatKind, chat: data.chat, message: data.id) else {
        return nil
    }
    let resource = HttpReferenceMediaResource(url: url, size: media.size)
    let dimensions = PixelDimensions(width: media.width ?? 512, height: media.height ?? 512)
    let preview = thumbnail(media, globallyUniqueId: globallyUniqueId, mediaBox: mediaBox)
    if media.kind == "photo" {
        let full = TelegramMediaImageRepresentation(dimensions: dimensions, resource: resource, progressiveSizes: [], immediateThumbnailData: nil)
        return TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.LocalImage, id: globallyUniqueId), representations: (preview.map { [$0] } ?? []) + [full], immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
    }
    let duration = media.duration ?? 0
    var attributes: [TelegramMediaFileAttribute] = []
    switch media.kind {
    case "video", "gif":
        attributes.append(.Video(duration: duration, size: dimensions, flags: [], preloadSize: nil, coverTime: nil, videoCodec: nil))
        if media.kind == "gif" {
            attributes.append(.Animated)
        }
    case "voice":
        attributes.append(.Audio(isVoice: true, duration: Int(duration), title: nil, performer: nil, waveform: nil))
    case "audio":
        attributes.append(.Audio(isVoice: false, duration: Int(duration), title: media.fileName, performer: nil, waveform: nil))
    case "sticker":
        attributes.append(.Sticker(displayText: "", packReference: nil, maskData: nil))
        attributes.append(.ImageSize(size: dimensions))
    default:
        break
    }
    if let fileName = media.fileName {
        attributes.append(.FileName(fileName: fileName))
    }
    return TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: globallyUniqueId), partialReference: nil, resource: resource, previewRepresentations: preview.map { [$0] } ?? [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: media.mime, size: media.size, attributes: attributes, alternativeRepresentations: [])
}

/// Stores one message in its chat, or brings the stored copy up to date (an edit); its id when stored.
@discardableResult
func storeWhatsAppMessage(transaction: Transaction, mediaBox: MediaBox, accountPeerId: PeerId, data: WhatsAppMessageData) -> MessageId? {
    let peerId = whatsAppChatPeerId(kind: data.chatKind, id: data.chat)
    guard transaction.getPeer(peerId) != nil else {
        return nil
    }
    let globallyUniqueId = whatsAppGloballyUniqueId(chatKind: data.chatKind, chat: data.chat, id: data.id)
    let length = (data.text as NSString).length
    let entities = withBoxLinks(data.entities.compactMap { entity($0, length: length) }, text: data.text)
    var attributes: [MessageAttribute] = [TextEntitiesMessageAttribute(entities: entities), WhatsAppMessageAttribute(waId: data.id)]
    if let quoted = data.quoted, let replyTo = transaction.messageIdForGloballyUniqueMessageId(peerId: peerId, id: whatsAppGloballyUniqueId(chatKind: data.chatKind, chat: data.chat, id: quoted)) {
        attributes.append(ReplyMessageAttribute(messageId: replyTo, threadMessageId: nil, quote: nil, isQuote: false, innerSubject: nil))
    }
    if data.edited {
        attributes.append(EditedMessageAttribute(date: Int32(clamping: data.at / 1000), isHidden: false))
    }
    let messageMedia = media(data, globallyUniqueId: globallyUniqueId, mediaBox: mediaBox).map { [$0] } ?? []
    let authorId: PeerId?
    if data.fromMe {
        authorId = accountPeerId
    } else if data.chatKind == "group" {
        authorId = data.author > 0 ? whatsAppPersonPeerId(data.author) : nil
    } else {
        authorId = peerId
    }
    let id = BoxMessageIds.id(transaction: transaction, peerId: peerId, date: data.at, globallyUniqueId: globallyUniqueId)
    let (tags, globalTags) = tagsForStoreMessage(incoming: !data.fromMe, attributes: attributes, media: messageMedia, textEntities: entities, isPinned: false)
    let message = StoreMessage(id: id, customStableId: nil, globallyUniqueId: globallyUniqueId, groupingKey: nil, threadId: nil, timestamp: Int32(clamping: data.at / 1000), flags: data.fromMe ? [] : [.Incoming], tags: tags, globalTags: globalTags, localTags: [], forwardInfo: nil, authorId: authorId, text: data.text, attributes: attributes, media: messageMedia)
    if transaction.getMessage(id) != nil {
        transaction.updateMessage(id, update: { _ in
            return .update(message)
        })
    } else {
        let _ = transaction.addMessages([message], location: .Random)
    }
    return id
}

/// A message revoked on WhatsApp goes here too.
func removeWhatsAppMessage(transaction: Transaction, chatKind: String, chat: Int64, id: String) {
    let peerId = whatsAppChatPeerId(kind: chatKind, id: chat)
    if let messageId = transaction.messageIdForGloballyUniqueMessageId(peerId: peerId, id: whatsAppGloballyUniqueId(chatKind: chatKind, chat: chat, id: id)) {
        transaction.deleteMessages([messageId], forEachMedia: nil)
    }
}
