import Foundation
import Postbox
import SwiftSignalKit

/// Mail as chat messages: the subject in bold over a new thread's first message, links and addresses tappable,
/// each attachment a file message of its own beside it. A machine's mail shows the box's summary of it over a
/// card (sender, subject, its picture) that opens the whole email.
private let replyPrefix = try! NSRegularExpression(pattern: "^\\s*(re|aw|fw|fwd|ответ|odp|sv)\\s*(\\[\\d+\\])?\\s*:", options: [.caseInsensitive])

/// A reply carries its thread's subject with a `Re:`; only a thread's first message shows it.
private func startsThread(subject: String) -> Bool {
    let range = NSRange(location: 0, length: (subject as NSString).length)
    return !subject.isEmpty && replyPrefix.firstMatch(in: subject, range: range) == nil
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
    return withBoxLinks((data.entities ?? []).compactMap { textEntity($0, in: body as NSString) }, text: body)
}

/// The bubble's text and entities: an automated mail's summary as it is (its subject is on its card), else the
/// subject (when it starts a thread), then the message's own words.
func emailText(_ data: EmailMessageData) -> (String, [MessageTextEntity]) {
    if let digest = data.digest {
        return (digest.text, digest.entities.compactMap { textEntity($0, in: digest.text as NSString) })
    }
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
    return EmailMessageAttribute(account: data.account, gmailId: data.id, threadId: data.threadId, subject: data.subject, from: data.from.address, to: data.to.map(\.address), cc: data.cc.map(\.address), isPartial: isPartial, viewUrl: data.viewUrl ?? "")
}

private func attachmentFile(_ attachment: EmailAttachmentData, data: EmailMessageData, globallyUniqueId: Int64) -> TelegramMediaFile? {
    guard let url = EmailBox.attachmentURL(account: data.account, message: data.id, part: attachment.part) else {
        return nil
    }
    return TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: globallyUniqueId), partialReference: nil, resource: HttpReferenceMediaResource(url: url, size: attachment.size), previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: attachment.mimeType, size: attachment.size, attributes: [.FileName(fileName: attachment.name)], alternativeRepresentations: [])
}

/// An automated mail's card: who sent it, its subject, its picture; a tap opens the whole email.
private func emailCard(_ data: EmailMessageData, globallyUniqueId: Int64) -> TelegramMediaWebpage? {
    guard data.digest != nil, let viewUrl = data.viewUrl else {
        return nil
    }
    var image: TelegramMediaImage?
    if let hero = data.hero, let url = EmailBox.heroURL(account: data.account, message: data.id) {
        let representation = TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: hero.width, height: hero.height), resource: HttpReferenceMediaResource(url: url, size: nil), progressiveSizes: [], immediateThumbnailData: nil)
        image = TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.LocalImage, id: globallyUniqueId), representations: [representation], immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
    }
    let sender = data.from.displayName
    let domain = data.from.address.split(separator: "@").last.map(String.init) ?? sender
    let content = TelegramMediaWebpageLoadedContent(url: viewUrl, displayUrl: domain, hash: 0, type: "article", websiteName: sender, title: data.subject.isEmpty ? nil : data.subject, text: nil, embedUrl: nil, embedType: nil, embedSize: nil, duration: nil, author: nil, isMediaLargeByDefault: true, imageIsVideoCover: false, image: image, file: nil, story: nil, attributes: [], instantPage: nil)
    return TelegramMediaWebpage(webpageId: MediaId(namespace: Namespaces.Media.LocalWebpage, id: globallyUniqueId), content: .Loaded(content))
}

/// The prefix of a reply button's callback data; the chat drafts the rest as a reply (`ChatControllerImpl`).
public let emailReplyCallbackPrefix = "email-reply:"
/// The callback data of the button that leaves a mail's list through the box.
public let emailUnsubscribeCallback = "email-unsubscribe"

/// A mail that asks something carries its buttons under its bubble, one a row: the links it asks the user to
/// follow, the way out of a subscription, then the answers the box offered.
private func replyButtons(_ data: EmailMessageData) -> ReplyMarkupMessageAttribute? {
    guard !data.outgoing else {
        return nil
    }
    let links = (data.actions ?? []).map { action in
        ReplyMarkupRow(buttons: [ReplyMarkupButton(title: action.label, titleWhenForwarded: nil, action: .url(action.url), style: nil)])
    }
    let answers = (data.replies ?? []).map { label in
        ReplyMarkupRow(buttons: [ReplyMarkupButton(title: label, titleWhenForwarded: nil, action: .callback(requiresPassword: false, data: MemoryBuffer(data: (emailReplyCallbackPrefix + label).data(using: .utf8)!)), style: nil)])
    }
    let unsubscribe = data.unsubscribe.map { way -> [ReplyMarkupRow] in
        let action: ReplyMarkupButtonAction = way.url.map { ReplyMarkupButtonAction.url($0) } ?? .callback(requiresPassword: false, data: MemoryBuffer(data: emailUnsubscribeCallback.data(using: .utf8)!))
        return [ReplyMarkupRow(buttons: [ReplyMarkupButton(title: "Unsubscribe", titleWhenForwarded: nil, action: action, style: nil)])]
    } ?? []
    let rows = links + unsubscribe + answers
    return rows.isEmpty ? nil : ReplyMarkupMessageAttribute(rows: rows, flags: [.inline], placeholder: nil)
}

private func isAnswer(_ button: ReplyMarkupButton) -> Bool {
    if case let .callback(_, data) = button.action {
        return String(data: data.makeData(), encoding: .utf8)?.hasPrefix(emailReplyCallbackPrefix) == true
    }
    return false
}

/// One message of an email: its files first, each a message of the email's group, the last one carrying the text.
private struct EmailPart {
    let globallyUniqueId: Int64
    let text: String
    let entities: [MessageTextEntity]
    let media: [Media]
    let markup: ReplyMarkupMessageAttribute?
}

/// The ids an email's messages have, oldest first, found by its globally unique ids.
private func storedEmailIds(transaction: Transaction, peerId: PeerId, globallyUniqueId: Int64) -> [MessageId] {
    var ids: [MessageId] = []
    var misses = 0
    var offset: Int64 = 0
    // The text message may be absent (an attachment-only mail stored the old way): its files start at offset 1.
    while misses < 2 {
        if let id = transaction.messageIdForGloballyUniqueMessageId(peerId: peerId, id: globallyUniqueId &+ offset) {
            ids.append(id)
            misses = 0
        } else {
            misses += 1
        }
        offset += 1
    }
    return ids.sorted()
}

/// Stores one email (and its attachments) in its chat; a full copy replaces the snippet the contact list gave.
/// Its files and text read as one bubble: a group of file messages with the text under the last, as Telegram sends
/// files with a caption. An automated mail's card cannot share a message with a file, so it stays on its own.
@discardableResult
func storeEmailMessage(transaction: Transaction, accountPeerId: PeerId, peerId: PeerId, data: EmailMessageData) -> MessageId? {
    let globallyUniqueId = emailGloballyUniqueId(gmailId: data.id)
    let isPartial = data.text == nil
    if isPartial, let existing = transaction.messageIdForGloballyUniqueMessageId(peerId: peerId, id: globallyUniqueId) {
        // Known already, possibly in full: a summary never overwrites it.
        return existing
    }
    // Answers are offered for a chat's latest mail only: anything newer takes the older ones' away.
    clearEmailReplyButtons(transaction: transaction, peerId: peerId, before: Int32(clamping: data.date / 1000), except: globallyUniqueId)
    let (text, entities) = emailText(data)
    let markup = replyButtons(data)
    let files = (data.attachments ?? []).enumerated().compactMap { index, attachment in
        attachmentFile(attachment, data: data, globallyUniqueId: globallyUniqueId &+ Int64(index + 1))
    }
    var parts: [EmailPart] = []
    if let card = emailCard(data, globallyUniqueId: globallyUniqueId) {
        parts.append(EmailPart(globallyUniqueId: globallyUniqueId, text: text, entities: entities, media: [card], markup: markup))
        parts += files.enumerated().map { EmailPart(globallyUniqueId: globallyUniqueId &+ Int64($0.offset + 1), text: "", entities: [], media: [$0.element], markup: nil) }
    } else {
        parts += files.dropLast().enumerated().map { EmailPart(globallyUniqueId: globallyUniqueId &+ Int64($0.offset + 1), text: "", entities: [], media: [$0.element], markup: nil) }
        parts.append(EmailPart(globallyUniqueId: globallyUniqueId, text: text, entities: entities, media: files.last.map { [$0] } ?? [], markup: markup))
    }
    let groupedFiles = parts.filter { $0.media.contains(where: { $0 is TelegramMediaFile }) }
    let groupingKey: Int64? = groupedFiles.count > 1 ? globallyUniqueId : nil

    // Ids follow the order the messages were added in; an email stored another way (each file a message after the
    // text) is laid out again in the same ids, so the text lands under the last file.
    let existing = storedEmailIds(transaction: transaction, peerId: peerId, globallyUniqueId: globallyUniqueId)
    let inPlace = existing.count == parts.count
    if !inPlace && !existing.isEmpty {
        transaction.deleteMessages(existing, forEachMedia: nil)
    }
    var free = existing
    let timestamp = Int32(clamping: data.date / 1000)
    for part in parts {
        let id = free.isEmpty ? BoxMessageIds.id(transaction: transaction, peerId: peerId, date: data.date, globallyUniqueId: part.globallyUniqueId) : free.removeFirst()
        var attributes: [MessageAttribute] = [TextEntitiesMessageAttribute(entities: part.entities), emailAttribute(data, isPartial: isPartial)]
        if let markup = part.markup {
            attributes.append(markup)
        }
        let (tags, globalTags) = tagsForStoreMessage(incoming: !data.outgoing, attributes: attributes, media: part.media, textEntities: part.entities, isPinned: false)
        let isGrouped = groupingKey != nil && part.media.contains(where: { $0 is TelegramMediaFile })
        let message = StoreMessage(id: id, customStableId: nil, globallyUniqueId: part.globallyUniqueId, groupingKey: isGrouped ? groupingKey : nil, threadId: nil, timestamp: timestamp, flags: data.outgoing ? [] : [.Incoming], tags: tags, globalTags: globalTags, localTags: [], forwardInfo: nil, authorId: data.outgoing ? accountPeerId : peerId, text: part.text, attributes: attributes, media: part.media)
        if inPlace {
            transaction.updateMessage(id, update: { _ in
                return .update(message)
            })
        } else {
            // Added one by one: a free id is one no message has yet.
            let _ = transaction.addMessages([message], location: .Random)
        }
    }
    return transaction.messageIdForGloballyUniqueMessageId(peerId: peerId, id: globallyUniqueId)
}

/// A newer message came (or the user wrote): the answers offered to earlier mail are spent. Link buttons stay.
func clearEmailReplyButtons(transaction: Transaction, peerId: PeerId, before timestamp: Int32 = Int32.max, except globallyUniqueId: Int64? = nil) {
    var marked: [MessageId] = []
    transaction.scanTopMessages(peerId: peerId, namespace: Namespaces.Message.Box, limit: 100, { message in
        if message.timestamp <= timestamp, message.globallyUniqueId != globallyUniqueId, message.attributes.contains(where: { ($0 as? ReplyMarkupMessageAttribute)?.rows.contains(where: { $0.buttons.contains(where: isAnswer) }) == true }) {
            marked.append(message.id)
        }
        return true
    })
    for id in marked {
        transaction.updateMessage(id, update: { current in
            let attributes: [MessageAttribute] = current.attributes.compactMap { attribute in
                guard let markup = attribute as? ReplyMarkupMessageAttribute else {
                    return attribute
                }
                let rows = markup.rows.filter { !$0.buttons.contains(where: isAnswer) }
                return rows.isEmpty ? nil : ReplyMarkupMessageAttribute(rows: rows, flags: markup.flags, placeholder: markup.placeholder)
            }
            return updatedBoxMessage(current, flags: { _ in }, attributes: attributes)
        })
    }
}

/// An email gone from the mailbox (trashed, deleted): its message and its attachments' go too.
func removeEmailMessage(transaction: Transaction, peerId: PeerId, gmailId: String) {
    let globallyUniqueId = emailGloballyUniqueId(gmailId: gmailId)
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
