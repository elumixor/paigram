import Foundation
import Postbox
import SwiftSignalKit

/// Keeps the WhatsApp chats equal to the box: its chat list once (and again whenever it says so), then its change
/// log, at start, every half minute and whenever the app asks.
private let syncRequests = ValuePipe<Void>()
private let syncInterval: Double = 30.0

/// Syncs now rather than at the next tick.
func requestWhatsAppSync() {
    syncRequests.putNext(Void())
}

/// A chat, its latest message, then the box's unread count over what storing the message counted.
private func storeChat(transaction: Transaction, mediaBox: MediaBox, accountPeerId: PeerId, chat: WhatsAppChatData) {
    let peerId = storeWhatsAppChatPeer(transaction: transaction, chat: chat)
    if let last = chat.last {
        storeWhatsAppMessage(transaction: transaction, mediaBox: mediaBox, accountPeerId: accountPeerId, data: last)
    }
    resetBoxReadState(transaction: transaction, peerId: peerId, unread: chat.unread, oldestUnread: chat.unread > 0 ? chat.last?.at : nil)
}

private func applyChats(postbox: Postbox, accountPeerId: PeerId, response: WhatsAppChatsResponse) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> Void in
        rememberWhatsAppPeople(transaction: transaction, response.people + (response.me.map { [$0] } ?? []))
        for chat in response.chats {
            storeChat(transaction: transaction, mediaBox: postbox.mediaBox, accountPeerId: accountPeerId, chat: chat)
        }
        updateWhatsAppState(transaction: transaction, { state in
            var state = state
            state.seq = response.seq
            state.me = response.me?.id ?? state.me
            return state
        })
    }
}

private func applyChanges(postbox: Postbox, accountPeerId: PeerId, response: WhatsAppChangesResponse) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> Void in
        for change in response.changes {
            switch change.kind {
            case "person":
                if let person = change.personData {
                    rememberWhatsAppPeople(transaction: transaction, [person])
                }
            case "chat":
                if let chat = change.chatData {
                    storeChat(transaction: transaction, mediaBox: postbox.mediaBox, accountPeerId: accountPeerId, chat: chat)
                }
            case "message":
                if let message = change.messageData {
                    storeWhatsAppMessage(transaction: transaction, mediaBox: postbox.mediaBox, accountPeerId: accountPeerId, data: message)
                }
            case "delete":
                if let chatKind = change.payload.chatKind, let chat = change.payload.chat, case let .string(id)? = change.payload.id {
                    removeWhatsAppMessage(transaction: transaction, chatKind: chatKind, chat: chat, id: id)
                }
            case "read":
                if let chatKind = change.payload.chatKind, let chat = change.payload.chat {
                    resetBoxReadState(transaction: transaction, peerId: whatsAppChatPeerId(kind: chatKind, id: chat), unread: change.payload.unread ?? 0, oldestUnread: nil)
                }
            case "removeChat":
                if let chatKind = change.payload.chatKind, let chat = change.payload.chat {
                    removeWhatsAppChat(transaction: transaction, peerId: whatsAppChatPeerId(kind: chatKind, id: chat))
                }
            default:
                break
            }
        }
        updateWhatsAppState(transaction: transaction, { state in
            var state = state
            state.seq = response.seq
            return state
        })
    }
}

private func syncChats(postbox: Postbox, accountPeerId: PeerId) -> Signal<Void, BoxError> {
    return (BoxClient.get("/whatsapp/chats") as Signal<WhatsAppChatsResponse, BoxError>)
    |> mapToSignal { response -> Signal<Void, BoxError> in
        return applyChats(postbox: postbox, accountPeerId: accountPeerId, response: response) |> castError(BoxError.self)
    }
}

/// Reads the change log from where this device stopped, page after page; a reset starts from the chat list.
private func syncChanges(postbox: Postbox, accountPeerId: PeerId) -> Signal<Void, BoxError> {
    return postbox.transaction { transaction -> Int64 in
        return currentWhatsAppState(transaction: transaction).seq
    }
    |> castError(BoxError.self)
    |> mapToSignal { seq -> Signal<Void, BoxError> in
        if seq == 0 {
            return syncChats(postbox: postbox, accountPeerId: accountPeerId)
        }
        return (BoxClient.get("/whatsapp/changes", query: ["since": "\(seq)"]) as Signal<WhatsAppChangesResponse, BoxError>)
        |> mapToSignal { response -> Signal<Void, BoxError> in
            if response.reset == true {
                return syncChats(postbox: postbox, accountPeerId: accountPeerId)
            }
            let applied = applyChanges(postbox: postbox, accountPeerId: accountPeerId, response: response) |> castError(BoxError.self)
            return response.more ? applied |> then(syncChanges(postbox: postbox, accountPeerId: accountPeerId)) : applied
        }
    }
}

/// One sync, errors logged: the next tick tries again.
func whatsAppSyncOnce(postbox: Postbox, accountPeerId: PeerId) -> Signal<Void, NoError> {
    guard PaiBox.configuration != nil else {
        return .complete()
    }
    return syncChanges(postbox: postbox, accountPeerId: accountPeerId)
    |> `catch` { error -> Signal<Void, NoError> in
        Logger.shared.log("WhatsApp", "sync failed: \(error)")
        return .complete()
    }
}

func managedWhatsAppSync(postbox: Postbox, accountPeerId: PeerId) -> Signal<Void, NoError> {
    return managedBoxSync(interval: syncInterval, requests: syncRequests, once: {
        whatsAppSyncOnce(postbox: postbox, accountPeerId: accountPeerId)
    })
}

/// A WhatsApp chat's older messages as it is scrolled; the box asks the phone for what it has not seen.
func fetchWhatsAppHistoryHole(postbox: Postbox, accountPeerId: PeerId, peerId: PeerId, namespace: MessageId.Namespace, direction: MessageHistoryViewRelativeHoleDirection, space: MessageHistoryHoleOperationSpace, count: Int) -> Signal<FetchMessageHistoryHoleResult?, NoError> {
    let key = whatsAppChatKey(peerId)
    return fillBoxHistoryHole(postbox: postbox, peerId: peerId, namespace: namespace, direction: direction, space: space, count: count, fetchPage: { before, limit in
        var query = ["chatKind": key.kind, "chat": "\(key.chat)", "limit": "\(limit)"]
        if let before {
            query["before"] = "\(before)"
        }
        return (BoxClient.get("/whatsapp/conversation", query: query) as Signal<WhatsAppPageResponse, BoxError>)
        |> map(Optional.init)
        |> `catch` { error -> Signal<WhatsAppPageResponse?, NoError> in
            Logger.shared.log("WhatsApp", "history of \(peerId) failed: \(error)")
            return .single(nil)
        }
        |> mapToSignal { response -> Signal<BoxHistoryPage?, NoError> in
            guard let response else {
                return .single(nil)
            }
            return postbox.transaction { transaction -> BoxHistoryPage? in
                rememberWhatsAppPeople(transaction: transaction, response.people)
                let ids = response.messages.compactMap { storeWhatsAppMessage(transaction: transaction, mediaBox: postbox.mediaBox, accountPeerId: accountPeerId, data: $0) }
                return BoxHistoryPage(ids: ids, more: response.more ?? false)
            }
        }
    })
}

private struct ChatBody: Encodable {
    let chatKind: String
    let chat: Int64
}

/// Reading a WhatsApp chat here reads it on WhatsApp (blue ticks for the sender).
func synchronizeWhatsAppReadState(postbox: Postbox, peerId: PeerId, push: Bool) -> Signal<Never, NoError> {
    let key = whatsAppChatKey(peerId)
    return synchronizeBoxReadState(postbox: postbox, peerId: peerId, push: push, post: { _ in
        return (BoxClient.post("/whatsapp/read", body: ChatBody(chatKind: key.kind, chat: key.chat)) as Signal<WhatsAppReadResponse, BoxError>)
        |> map { response -> ((Transaction) -> Void)? in
            return { transaction in
                storeWhatsAppChatPeer(transaction: transaction, chat: response.chat)
                resetBoxReadState(transaction: transaction, peerId: peerId, unread: response.chat.unread, oldestUnread: nil)
            }
        }
        |> `catch` { error -> Signal<((Transaction) -> Void)?, NoError> in
            Logger.shared.log("WhatsApp", "read of \(peerId) failed: \(error)")
            return .single(nil)
        }
    })
}

private struct MuteBody: Encodable {
    let chatKind: String
    let chat: Int64
    let muted: Bool
}

/// Muting a WhatsApp chat here mutes it on WhatsApp, which is also what the box's pushes follow.
func pushWhatsAppNotificationSettings(postbox: Postbox, peerId: PeerId, settings: PeerNotificationSettings) -> Signal<Void, NoError> {
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
        let key = whatsAppChatKey(peerId)
        return (BoxClient.post("/whatsapp/mute", body: MuteBody(chatKind: key.kind, chat: key.chat, muted: muted)) as Signal<WhatsAppChatData, BoxError>)
        |> map { _ in Void() }
        |> `catch` { error -> Signal<Void, NoError> in
            Logger.shared.log("WhatsApp", "mute of \(peerId) failed: \(error)")
            return .complete()
        }
    }
}
