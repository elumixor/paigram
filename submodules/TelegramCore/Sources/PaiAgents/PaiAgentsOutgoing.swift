import Foundation
import Postbox
import SwiftSignalKit

/// A message typed in an agent chat goes to pai (`POST /agents/<slug>/message`). It waits in the chat under an id
/// above every row's until its row in the log arrives: an agent's send answers with the row, pai's with only its
/// session, so pai's waits for the row to come in through sync and takes its place then.

/// Ids of messages still waiting for their row, counted down from the top of the range.
private let pendingTop: Int32 = Int32.max - 2

private func entry(_ id: MessageId) -> PaiAgentsState.Sending {
    return PaiAgentsState.Sending(peerId: id.peerId.toInt64(), id: id.id)
}

private func messageId(_ entry: PaiAgentsState.Sending) -> MessageId {
    return MessageId(peerId: PeerId(entry.peerId), namespace: Namespaces.Message.Box, id: entry.id)
}

func enqueuePaiAgentMessages(transaction: Transaction, accountPeerId: PeerId, peerId: PeerId, messages: [EnqueueMessage]) -> [MessageId] {
    let now = Int32(Date().timeIntervalSince1970)
    var ids: [MessageId] = []
    var next = pendingTop
    for message in messages {
        guard case let .message(text, attributes, _, _, _, _, _, _, _, _) = message else {
            continue
        }
        while transaction.getMessage(MessageId(peerId: peerId, namespace: Namespaces.Message.Box, id: next)) != nil {
            next -= 1
        }
        let id = MessageId(peerId: peerId, namespace: Namespaces.Message.Box, id: next)
        next -= 1
        let entities = (attributes.first(where: { $0 is TextEntitiesMessageAttribute }) as? TextEntitiesMessageAttribute)?.entities ?? []
        var stored: [MessageAttribute] = [TextEntitiesMessageAttribute(entities: entities)]
        let globallyUniqueId = Int64.random(in: Int64.min ... Int64.max)
        // The chat clears its composer (and plays the send animation) only once a message carrying this id lands.
        if let correlationId = message.correlationId {
            stored.append(OutgoingMessageInfoAttribute(uniqueId: globallyUniqueId, flags: [], acknowledged: false, correlationId: correlationId, bubbleUpEmojiOrStickersets: [], partialReference: nil))
        }
        let (tags, globalTags) = tagsForStoreMessage(incoming: false, attributes: stored, media: [], textEntities: entities, isPinned: false)
        let _ = transaction.addMessages([StoreMessage(id: id, customStableId: nil, globallyUniqueId: globallyUniqueId, groupingKey: nil, threadId: nil, timestamp: now, flags: [.Sending], tags: tags, globalTags: globalTags, localTags: [], forwardInfo: nil, authorId: accountPeerId, text: text, attributes: stored, media: [])], location: .Random)
        ids.append(id)
    }
    updatePaiAgentsState(transaction: transaction, { state in
        var state = state
        state.sending.append(contentsOf: ids.map(entry))
        return state
    })
    return ids
}

/// The waiting message gives way to its row.
private func replace(transaction: Transaction, pending id: MessageId) {
    if transaction.getMessage(id) != nil {
        transaction.deleteMessages([id], forEachMedia: nil)
    }
    updatePaiAgentsState(transaction: transaction, { state in
        var state = state
        state.sending.removeAll(where: { $0 == entry(id) })
        return state
    })
}

/// A row of the user's to an agent arriving: the message waiting for it (the same text, else the oldest) goes.
func settleAwaited(transaction: Transaction, row: PaiLogRow, slug: String) {
    guard row.from == "user", row.to == slug, row.kind == "chat" else {
        return
    }
    let peerId = paiAgentPeerId(slug: slug)
    let waiting = currentPaiAgentsState(transaction: transaction).sending.map(messageId).filter { $0.peerId == peerId }.compactMap { transaction.getMessage($0) }.filter { !$0.flags.contains(.Failed) }
    guard let match = waiting.first(where: { $0.text == row.body }) ?? waiting.min(by: { $0.timestamp < $1.timestamp }) else {
        return
    }
    replace(transaction: transaction, pending: match.id)
}

func sendPaiAgentMessage(postbox: Postbox, accountPeerId: PeerId, messageId: MessageId) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> (String, String)? in
        guard let message = transaction.getMessage(messageId), let slug = currentPaiAgentsState(transaction: transaction).agent(peerId: messageId.peerId)?.slug else {
            return nil
        }
        return (slug, message.text)
    }
    |> mapToSignal { request -> Signal<Void, NoError> in
        guard let (slug, text) = request else {
            return .complete()
        }
        return BoxClient.postData("/agents/\(slug)/message", json: ["text": text])
        |> map(Optional.init)
        |> `catch` { error -> Signal<Data?, NoError> in
            Logger.shared.log("PaiAgents", "send to \(slug) failed: \(error)")
            return .single(nil)
        }
        |> mapToSignal { data -> Signal<Void, NoError> in
            return postbox.transaction { transaction -> Void in
                guard let data else {
                    failBoxMessages(transaction: transaction, ids: [messageId])
                    return
                }
                if let json = try? JSONSerialization.jsonObject(with: data), let row = PaiLogRow(json: json) {
                    replace(transaction: transaction, pending: messageId)
                    let agents = currentPaiAgentsState(transaction: transaction).agents
                    storePaiRow(transaction: transaction, accountPeerId: accountPeerId, row: row, slug: slug, agents: agents)
                } else if transaction.getMessage(messageId) != nil {
                    transaction.updateMessage(messageId, update: { current in
                        return updatedBoxMessage(current, flags: { $0.remove(.Sending); $0.remove(.Failed) })
                    })
                }
            }
            |> afterCompleted {
                PaiAgentsSync.request()
            }
        }
    }
}

func resendPaiAgentMessages(postbox: Postbox, accountPeerId: PeerId, messageIds: [MessageId]) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> Void in
        markBoxMessagesSending(transaction: transaction, ids: messageIds)
    }
    |> mapToSignal { _ -> Signal<Void, NoError> in
        return combineLatest(messageIds.map { sendPaiAgentMessage(postbox: postbox, accountPeerId: accountPeerId, messageId: $0) |> then(.single(Void())) })
        |> map { _ in Void() }
    }
}

/// Sends the app quit in the middle of are failed; waiting messages already gone are forgotten.
func failInterruptedPaiAgentSends(postbox: Postbox) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> Void in
        let ids = currentPaiAgentsState(transaction: transaction).sending.map(messageId)
        failBoxMessages(transaction: transaction, ids: ids)
        updatePaiAgentsState(transaction: transaction, { state in
            var state = state
            state.sending.removeAll(where: { transaction.getMessage(messageId($0)) == nil })
            return state
        })
    }
}

/// The metadata a message's trailer carries (`paiRowContent`).
func paiTrailerMeta(_ message: Message) -> [String: Any]? {
    guard let entities = message.textEntitiesAttribute?.entities else {
        return nil
    }
    for entity in entities.reversed() {
        guard case let .TextUrl(url) = entity.type, let range = url.range(of: "/m/") else {
            continue
        }
        var encoded = String(url[range.upperBound...]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 {
            encoded += "="
        }
        guard let data = Data(base64Encoded: encoded), let meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return meta
    }
    return nil
}

/// An ask's message once answered: its buttons gone and the answer in its trailer, so the card shows it settled.
func markPaiAskAnswered(transaction: Transaction, id: MessageId, answer: String) {
    guard let message = transaction.getMessage(id), var meta = paiTrailerMeta(message) else {
        return
    }
    meta["answer"] = answer
    var text = message.text
    var entities = message.textEntitiesAttribute?.entities ?? []
    if text.hasSuffix(" ·") {
        text = String(text.dropLast(2))
        let length = (text as NSString).length
        entities = entities.filter { $0.range.upperBound <= length }
    }
    let (newText, newEntities) = paiWithTrailer(text, entities, meta: meta)
    transaction.updateMessage(id, update: { current in
        let attributes = current.attributes.filter { !($0 is ReplyMarkupMessageAttribute) && !($0 is TextEntitiesMessageAttribute) } + [TextEntitiesMessageAttribute(entities: newEntities)]
        return .update(StoreMessage(id: current.id, customStableId: nil, globallyUniqueId: current.globallyUniqueId, groupingKey: current.groupingKey, threadId: current.threadId, timestamp: current.timestamp, flags: StoreMessageFlags(current.flags), tags: current.tags, globalTags: current.globalTags, localTags: current.localTags, forwardInfo: nil, authorId: current.author?.id, text: newText, attributes: attributes, media: current.media))
    })
}

/// An ask's button tapped in an agent chat: `k:<ask>:<i>` answers with that option, `m:<ask>:<i>` ticks or unticks
/// it, `M:<ask>` answers with the ticked ones. Nil when the callback is not an ask's.
func paiAgentAskCallback(postbox: Postbox, messageId: MessageId, data: Data) -> Signal<Void, NoError>? {
    guard let string = String(data: data, encoding: .utf8) else {
        return nil
    }
    let parts = string.split(separator: ":").map(String.init)
    guard parts.count >= 2, ["k", "m", "M"].contains(parts[0]), let askId = Int(parts[1]) else {
        return nil
    }
    let index = parts.count > 2 ? Int(parts[2]) : nil
    return postbox.transaction { transaction -> String? in
        guard let message = transaction.getMessage(messageId), let meta = paiTrailerMeta(message), let options = meta["options"] as? [String] else {
            return nil
        }
        let markup = message.attributes.first(where: { $0 is ReplyMarkupMessageAttribute }) as? ReplyMarkupMessageAttribute
        let ticked = Set((markup?.rows ?? []).enumerated().compactMap { offset, row in row.buttons.first?.title.hasPrefix("☑") == true ? offset : nil })
        switch parts[0] {
        case "k":
            guard let index, index < options.count else {
                return nil
            }
            return options[index]
        case "m":
            guard let index, index < options.count else {
                return nil
            }
            var updated = ticked
            if updated.contains(index) {
                updated.remove(index)
            } else {
                updated.insert(index)
            }
            if let newMarkup = paiAskMarkup(meta: meta, ticked: updated) {
                transaction.updateMessage(messageId, update: { current in
                    let attributes = current.attributes.filter { !($0 is ReplyMarkupMessageAttribute) } + [newMarkup]
                    return .update(StoreMessage(id: current.id, customStableId: nil, globallyUniqueId: current.globallyUniqueId, groupingKey: current.groupingKey, threadId: current.threadId, timestamp: current.timestamp, flags: StoreMessageFlags(current.flags), tags: current.tags, globalTags: current.globalTags, localTags: current.localTags, forwardInfo: nil, authorId: current.author?.id, text: current.text, attributes: attributes, media: current.media))
                })
            }
            return nil
        default:
            let labels = ticked.sorted().filter { $0 < options.count }.map { options[$0] }
            return labels.isEmpty ? nil : labels.joined(separator: ", ")
        }
    }
    |> mapToSignal { answer -> Signal<Void, NoError> in
        guard let answer else {
            return .complete()
        }
        return BoxClient.postData("/asks/\(askId)/answer", json: ["text": answer])
        |> map { _ in true }
        |> `catch` { error -> Signal<Bool, NoError> in
            Logger.shared.log("PaiAgents", "answer to ask \(askId) failed: \(error)")
            // An ask answered elsewhere refuses another answer: its buttons go all the same.
            if case let .http(status, _) = error, status == 404 || status == 409 || status == 400 {
                return .single(true)
            }
            return .single(false)
        }
        |> mapToSignal { answered -> Signal<Void, NoError> in
            guard answered else {
                return .complete()
            }
            return postbox.transaction { transaction -> Void in
                markPaiAskAnswered(transaction: transaction, id: messageId, answer: answer)
            }
            |> afterCompleted {
                PaiAgentsSync.request()
            }
        }
    }
}
