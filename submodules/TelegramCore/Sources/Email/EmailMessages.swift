import Foundation
import Postbox
import SwiftSignalKit

/// Mail as chat messages: the subject in bold over a new thread's first message, links and addresses tappable,
/// each attachment a file message of its own beside it.
private let replyPrefix = try! NSRegularExpression(pattern: "^\\s*(re|aw|fw|fwd|ответ|odp|sv)\\s*(\\[\\d+\\])?\\s*:", options: [.caseInsensitive])
private let linkDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

/// A reply carries its thread's subject with a `Re:`; only a thread's first message shows it.
private func startsThread(subject: String) -> Bool {
    let range = NSRange(location: 0, length: (subject as NSString).length)
    return !subject.isEmpty && replyPrefix.firstMatch(in: subject, range: range) == nil
}

private func links(in text: String) -> [MessageTextEntity] {
    let range = NSRange(location: 0, length: (text as NSString).length)
    return linkDetector.matches(in: text, range: range).compactMap { match in
        guard let url = match.url else {
            return nil
        }
        let type: MessageTextEntityType = url.scheme == "mailto" ? .Email : .Url
        return MessageTextEntity(range: match.range.location ..< match.range.location + match.range.length, type: type)
    }
}

private func isLink(_ entity: MessageTextEntity) -> Bool {
    switch entity.type {
    case .Url, .TextUrl, .Email:
        return true
    default:
        return false
    }
}

/// A span the box drew; a link whose words are its own address stays a plain link, so tapping it asks nothing.
private func textEntity(_ entity: EmailTextEntityData, in text: NSString) -> MessageTextEntity? {
    let range = entity.offset ..< entity.offset + entity.length
    guard entity.offset >= 0, entity.length > 0, range.upperBound <= text.length else {
        return nil
    }
    switch entity.type {
    case "bold":
        return MessageTextEntity(range: range, type: .Bold)
    case "italic":
        return MessageTextEntity(range: range, type: .Italic)
    case "link":
        guard let url = entity.url else {
            return nil
        }
        let shown = text.substring(with: NSRange(location: entity.offset, length: entity.length))
        let type: MessageTextEntityType = url == shown ? .Url : url == "mailto:\(shown)" ? .Email : .TextUrl(url: url)
        return MessageTextEntity(range: range, type: type)
    default:
        return nil
    }
}

/// The body's spans as the box drew them, and the addresses it left as plain text made tappable.
private func bodyEntities(_ data: EmailMessageData, body: String) -> [MessageTextEntity] {
    let drawn = (data.entities ?? []).compactMap { textEntity($0, in: body as NSString) }
    let linked = drawn.filter(isLink).map(\.range)
    return drawn + links(in: body).filter { found in
        !linked.contains(where: { $0.overlaps(found.range) })
    }
}

/// The bubble's text and entities: subject (when it starts a thread), then the message's own words.
func emailText(_ data: EmailMessageData) -> (String, [MessageTextEntity]) {
    let body = data.text ?? data.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
    let entities = bodyEntities(data, body: body)
    guard startsThread(subject: data.subject) else {
        return (body, entities)
    }
    let subjectLength = (data.subject as NSString).length
    let text = body.isEmpty ? data.subject : "\(data.subject)\n\(body)"
    let shifted = entities.map { entity in
        MessageTextEntity(range: entity.range.lowerBound + subjectLength + 1 ..< entity.range.upperBound + subjectLength + 1, type: entity.type)
    }
    return (text, [MessageTextEntity(range: 0 ..< subjectLength, type: .Bold)] + shifted)
}

func emailAttribute(_ data: EmailMessageData, isPartial: Bool) -> EmailMessageAttribute {
    return EmailMessageAttribute(account: data.account, gmailId: data.id, threadId: data.threadId, subject: data.subject, from: data.from.address, to: data.to.map(\.address), cc: data.cc.map(\.address), isPartial: isPartial)
}

private func attachmentFile(_ attachment: EmailAttachmentData, data: EmailMessageData, globallyUniqueId: Int64) -> TelegramMediaFile? {
    guard let url = EmailBox.attachmentURL(account: data.account, message: data.id, part: attachment.part) else {
        return nil
    }
    return TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: globallyUniqueId), partialReference: nil, resource: HttpReferenceMediaResource(url: url, size: attachment.size), previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: attachment.mimeType, size: attachment.size, attributes: [.FileName(fileName: attachment.name)], alternativeRepresentations: [])
}

private func storeMessage(transaction: Transaction, accountPeerId: PeerId, peerId: PeerId, data: EmailMessageData, globallyUniqueId: Int64, text: String, entities: [MessageTextEntity], media: [Media], isPartial: Bool) {
    let id = EmailMessageIds.id(transaction: transaction, peerId: peerId, date: data.date, globallyUniqueId: globallyUniqueId)
    let attributes: [MessageAttribute] = [TextEntitiesMessageAttribute(entities: entities), emailAttribute(data, isPartial: isPartial)]
    let (tags, globalTags) = tagsForStoreMessage(incoming: !data.outgoing, attributes: attributes, media: media, textEntities: entities, isPinned: false)
    let message = StoreMessage(id: id, customStableId: nil, globallyUniqueId: globallyUniqueId, groupingKey: nil, threadId: nil, timestamp: Int32(clamping: data.date / 1000), flags: data.outgoing ? [] : [.Incoming], tags: tags, globalTags: globalTags, localTags: [], forwardInfo: nil, authorId: data.outgoing ? accountPeerId : peerId, text: text, attributes: attributes, media: media)
    if transaction.getMessage(id) != nil {
        transaction.updateMessage(id, update: { _ in
            return .update(message)
        })
    } else {
        let _ = transaction.addMessages([message], location: .Random)
    }
}

/// Stores one email (and its attachments) in its chat; a full copy replaces the snippet the contact list gave.
@discardableResult
func storeEmailMessage(transaction: Transaction, accountPeerId: PeerId, peerId: PeerId, data: EmailMessageData) -> MessageId? {
    let globallyUniqueId = EmailMessageIds.globallyUniqueId(gmailId: data.id)
    let isPartial = data.text == nil
    if isPartial, let existing = transaction.messageIdForGloballyUniqueMessageId(peerId: peerId, id: globallyUniqueId) {
        // Known already, possibly in full: a summary never overwrites it.
        return existing
    }
    let (text, entities) = emailText(data)
    if !text.isEmpty || (data.attachments ?? []).isEmpty {
        storeMessage(transaction: transaction, accountPeerId: accountPeerId, peerId: peerId, data: data, globallyUniqueId: globallyUniqueId, text: text, entities: entities, media: [], isPartial: isPartial)
    }
    for (index, attachment) in (data.attachments ?? []).enumerated() {
        let fileId = globallyUniqueId &+ Int64(index + 1)
        if let file = attachmentFile(attachment, data: data, globallyUniqueId: fileId) {
            storeMessage(transaction: transaction, accountPeerId: accountPeerId, peerId: peerId, data: data, globallyUniqueId: fileId, text: "", entities: [], media: [file], isPartial: false)
        }
    }
    return transaction.messageIdForGloballyUniqueMessageId(peerId: peerId, id: globallyUniqueId)
}

/// An email gone from the mailbox (trashed, deleted): its message and its attachments' go too.
func removeEmailMessage(transaction: Transaction, peerId: PeerId, gmailId: String) {
    let globallyUniqueId = EmailMessageIds.globallyUniqueId(gmailId: gmailId)
    var ids: [MessageId] = []
    var offset: Int64 = 0
    while let id = transaction.messageIdForGloballyUniqueMessageId(peerId: peerId, id: globallyUniqueId &+ offset) {
        ids.append(id)
        offset += 1
    }
    // The text message may be absent (an attachment-only mail): its files start at offset 1.
    if ids.isEmpty {
        offset = 1
        while let id = transaction.messageIdForGloballyUniqueMessageId(peerId: peerId, id: globallyUniqueId &+ offset) {
            ids.append(id)
            offset += 1
        }
    }
    if !ids.isEmpty {
        transaction.deleteMessages(ids, forEachMedia: nil)
    }
}
