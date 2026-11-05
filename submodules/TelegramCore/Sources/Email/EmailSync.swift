import Foundation
import Postbox
import SwiftSignalKit

/// Keeps the email chats equal to the box: its contact list once (and again whenever it says so), then its
/// change log — at start, every half minute, and the moment the app asks (a push came in, it came to the front).
private let syncRequests = ValuePipe<Void>()
private let syncInterval: Double = 30.0

/// Syncs now rather than at the next tick.
func requestEmailSync() {
    syncRequests.putNext(Void())
}


private func applyContacts(postbox: Postbox, accountPeerId: PeerId, response: EmailContactsResponse) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> Void in
        let state = currentEmailState(transaction: transaction)
        let previous = Set(state.contacts.map(\.id))
        let current = Set(response.contacts.map(\.id))
        if state.textVersion < EmailState.currentTextVersion {
            // Mail stored the old way is fetched again, drawn the box's current way, as it is scrolled.
            for id in previous.union(current) {
                refillBoxChat(transaction: transaction, peerId: emailPeerId(contactId: id))
            }
        }
        for contact in response.contacts {
            let peerId = storeEmailContactPeer(transaction: transaction, contact: contact)
            if let last = contact.last {
                storeEmailMessage(transaction: transaction, accountPeerId: accountPeerId, peerId: peerId, data: last)
            }
            resetEmailReadState(transaction: transaction, peerId: peerId, contact: contact)
        }
        // Chats the box no longer lists leave the list, unless pinned.
        for id in previous.subtracting(current) {
            let peerId = emailPeerId(contactId: id)
            if case let .ifHasMessagesOrOneOf(_, pinningIndex, _) = transaction.getPeerChatListInclusion(peerId), pinningIndex == nil {
                transaction.updatePeerChatListInclusion(peerId, inclusion: .notIncluded)
            }
        }
        rememberEmailContacts(transaction: transaction, response.contacts)
        updateEmailState(transaction: transaction, { state in
            var state = state
            state.seq = response.seq
            state.accounts = response.accounts
            state.textVersion = EmailState.currentTextVersion
            return state
        })
    }
}

/// Mail the box is still reading arrives finished in its change log within seconds: read it then, not at the
/// next half-minute tick.
private func followPending(_ messages: [EmailMessageData]) {
    guard messages.contains(where: { $0.pending == true }) else {
        return
    }
    for delay in [6.0, 20.0, 45.0] {
        Queue.concurrentDefaultQueue().after(delay, {
            syncRequests.putNext(Void())
        })
    }
}

private func applyChanges(postbox: Postbox, accountPeerId: PeerId, response: EmailChangesResponse) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> Void in
        followPending(response.changes.compactMap(\.payload.message))
        for change in response.changes {
            let peerId = change.payload.contact.map { storeEmailContactPeer(transaction: transaction, contact: $0) }
            switch change.kind {
            case "message":
                if let peerId, let message = change.payload.message {
                    storeEmailMessage(transaction: transaction, accountPeerId: accountPeerId, peerId: peerId, data: message)
                }
            case "deleted":
                if let peerId, let id = change.payload.id {
                    removeEmailMessage(transaction: transaction, peerId: peerId, gmailId: id)
                }
            default:
                break
            }
            if let peerId, let contact = change.payload.contact {
                resetEmailReadState(transaction: transaction, peerId: peerId, contact: contact)
            }
        }
        rememberEmailContacts(transaction: transaction, response.changes.compactMap(\.payload.contact))
        updateEmailState(transaction: transaction, { state in
            var state = state
            state.seq = response.seq
            return state
        })
    }
}

private func syncContacts(postbox: Postbox, accountPeerId: PeerId) -> Signal<Void, BoxError> {
    return (BoxClient.get("/gmail/contacts") as Signal<EmailContactsResponse, BoxError>)
    |> mapToSignal { response -> Signal<Void, BoxError> in
        return applyContacts(postbox: postbox, accountPeerId: accountPeerId, response: response) |> castError(BoxError.self)
    }
}

/// Reads the change log from where this device stopped, page after page; a reset, or mail stored before the box
/// drew text its current way, starts from the contact list.
private func syncChanges(postbox: Postbox, accountPeerId: PeerId) -> Signal<Void, BoxError> {
    return postbox.transaction { transaction -> EmailState in
        moveStoredEmailChatsToGroup(transaction: transaction)
        return currentEmailState(transaction: transaction)
    }
    |> castError(BoxError.self)
    |> mapToSignal { state -> Signal<Void, BoxError> in
        let seq = state.seq
        if seq == 0 || state.textVersion < EmailState.currentTextVersion {
            return syncContacts(postbox: postbox, accountPeerId: accountPeerId)
        }
        return (BoxClient.get("/gmail/changes", query: ["since": "\(seq)"]) as Signal<EmailChangesResponse, BoxError>)
        |> mapToSignal { response -> Signal<Void, BoxError> in
            if response.reset {
                return syncContacts(postbox: postbox, accountPeerId: accountPeerId)
            }
            let applied = applyChanges(postbox: postbox, accountPeerId: accountPeerId, response: response) |> castError(BoxError.self)
            if response.more == true {
                return applied |> then(syncChanges(postbox: postbox, accountPeerId: accountPeerId))
            }
            return applied
        }
    }
}

/// One sync, errors logged: the next tick tries again.
func emailSyncOnce(postbox: Postbox, accountPeerId: PeerId) -> Signal<Void, NoError> {
    guard PaiBox.configuration != nil else {
        return .complete()
    }
    return syncChanges(postbox: postbox, accountPeerId: accountPeerId)
    |> `catch` { error -> Signal<Void, NoError> in
        Logger.shared.log("Email", "sync failed: \(error)")
        return .complete()
    }
}

func managedEmailSync(postbox: Postbox, accountPeerId: PeerId) -> Signal<Void, NoError> {
    return managedBoxSync(interval: syncInterval, requests: syncRequests, once: {
        emailSyncOnce(postbox: postbox, accountPeerId: accountPeerId)
    })
}

/// An email chat's older mail, a page at a time as it is scrolled.
func fetchEmailHistoryHole(postbox: Postbox, accountPeerId: PeerId, peerId: PeerId, namespace: MessageId.Namespace, direction: MessageHistoryViewRelativeHoleDirection, space: MessageHistoryHoleOperationSpace, count: Int) -> Signal<FetchMessageHistoryHoleResult?, NoError> {
    return fillBoxHistoryHole(postbox: postbox, peerId: peerId, namespace: namespace, direction: direction, space: space, count: count, fetchPage: { before, limit in
        var query = ["contact": "\(peerId.id._internalGetInt64Value())", "limit": "\(limit)"]
        if let before {
            query["before"] = "\(before)"
        }
        return (BoxClient.get("/gmail/conversation", query: query) as Signal<EmailConversationResponse, BoxError>)
        |> map(Optional.init)
        |> `catch` { error -> Signal<EmailConversationResponse?, NoError> in
            Logger.shared.log("Email", "history of \(peerId) failed: \(error)")
            return .single(nil)
        }
        |> mapToSignal { response -> Signal<BoxHistoryPage?, NoError> in
            guard let response else {
                return .single(nil)
            }
            return postbox.transaction { transaction -> BoxHistoryPage? in
                followPending(response.messages)
                let ids = response.messages.compactMap { storeEmailMessage(transaction: transaction, accountPeerId: accountPeerId, peerId: peerId, data: $0) }
                resetEmailReadState(transaction: transaction, peerId: peerId, contact: response.contact)
                return BoxHistoryPage(ids: ids, more: response.more)
            }
        }
    })
}

private struct ReadBody: Encodable {
    let contact: Int64
    let before: Int64
}

/// A read in an email chat marks its mail read in Gmail; the box answers with the chat's new count.
func synchronizeEmailReadState(postbox: Postbox, peerId: PeerId, push: Bool) -> Signal<Never, NoError> {
    return synchronizeBoxReadState(postbox: postbox, peerId: peerId, push: push, post: { index in
        let body = ReadBody(contact: peerId.id._internalGetInt64Value(), before: Int64(index.timestamp) * 1000 + 999)
        return (BoxClient.post("/gmail/read", body: body) as Signal<EmailReadResponse, BoxError>)
        |> map { response -> ((Transaction) -> Void)? in
            return { transaction in
                resetEmailReadState(transaction: transaction, peerId: peerId, contact: response.contact)
            }
        }
        |> `catch` { error -> Signal<((Transaction) -> Void)?, NoError> in
            Logger.shared.log("Email", "read of \(peerId) failed: \(error)")
            return .single(nil)
        }
    })
}
