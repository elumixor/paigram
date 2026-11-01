import Foundation
import Postbox
import SwiftSignalKit

/// Keeps the email chats equal to the box: its contact list once (and again whenever it says so), then its
/// change log — at start, every half minute, and the moment the app asks (a push came in, it came to the front).
private let syncRequests = ValuePipe<Void>()
private let syncInterval: Double = 30.0
private let changesPerPage = 200

/// Syncs now rather than at the next tick.
func requestEmailSync() {
    syncRequests.putNext(Void())
}

/// Every email chat emptied down to a hole, so its mail is fetched again, drawn the box's current way, as it is scrolled.
private func refillEmailChats(transaction: Transaction, contactIds: Set<Int64>) {
    for id in contactIds {
        let peerId = emailPeerId(contactId: id)
        transaction.clearHistory(peerId, threadId: nil, minTimestamp: nil, maxTimestamp: nil, namespaces: .just([Namespaces.Message.Email]), forEachMedia: nil)
        transaction.addHole(peerId: peerId, threadId: nil, namespace: Namespaces.Message.Email, space: .everywhere, range: 1 ... Int32.max - 1)
    }
}

private func applyContacts(postbox: Postbox, accountPeerId: PeerId, response: EmailContactsResponse) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> Void in
        let state = currentEmailState(transaction: transaction)
        let previous = Set(state.contacts.map(\.id))
        let current = Set(response.contacts.map(\.id))
        if state.textVersion < EmailState.currentTextVersion {
            refillEmailChats(transaction: transaction, contactIds: previous.union(current))
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

private func applyChanges(postbox: Postbox, accountPeerId: PeerId, response: EmailChangesResponse) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> Void in
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

private func syncContacts(postbox: Postbox, accountPeerId: PeerId) -> Signal<Void, EmailBoxError> {
    return (EmailClient.get("/gmail/contacts") as Signal<EmailContactsResponse, EmailBoxError>)
    |> mapToSignal { response -> Signal<Void, EmailBoxError> in
        return applyContacts(postbox: postbox, accountPeerId: accountPeerId, response: response) |> castError(EmailBoxError.self)
    }
}

/// Reads the change log from where this device stopped, page after page; a reset, or mail stored before the box
/// drew text its current way, starts from the contact list.
private func syncChanges(postbox: Postbox, accountPeerId: PeerId) -> Signal<Void, EmailBoxError> {
    return postbox.transaction { transaction -> EmailState in
        return currentEmailState(transaction: transaction)
    }
    |> castError(EmailBoxError.self)
    |> mapToSignal { state -> Signal<Void, EmailBoxError> in
        let seq = state.seq
        if seq == 0 || state.textVersion < EmailState.currentTextVersion {
            return syncContacts(postbox: postbox, accountPeerId: accountPeerId)
        }
        return (EmailClient.get("/gmail/changes", query: ["since": "\(seq)"]) as Signal<EmailChangesResponse, EmailBoxError>)
        |> mapToSignal { response -> Signal<Void, EmailBoxError> in
            if response.reset {
                return syncContacts(postbox: postbox, accountPeerId: accountPeerId)
            }
            let applied = applyChanges(postbox: postbox, accountPeerId: accountPeerId, response: response) |> castError(EmailBoxError.self)
            if response.more == true {
                return applied |> then(syncChanges(postbox: postbox, accountPeerId: accountPeerId))
            }
            return applied
        }
    }
}

/// One sync, errors logged: the next tick tries again.
func emailSyncOnce(postbox: Postbox, accountPeerId: PeerId) -> Signal<Void, NoError> {
    guard EmailBox.configuration != nil else {
        return .complete()
    }
    return syncChanges(postbox: postbox, accountPeerId: accountPeerId)
    |> `catch` { error -> Signal<Void, NoError> in
        Logger.shared.log("Email", "sync failed: \(error)")
        return .complete()
    }
}

/// The main app's sync loop, one at a time: a request while a sync runs is served by the next one.
func managedEmailSync(postbox: Postbox, accountPeerId: PeerId) -> Signal<Void, NoError> {
    let triggers = Signal<Void, NoError>.single(Void())
    |> then(
        (Signal<Void, NoError>.complete() |> delay(syncInterval, queue: Queue.concurrentDefaultQueue()) |> then(.single(Void()))) |> restart
    )
    let ticks = Signal<Void, NoError> { subscriber in
        let disposables = DisposableSet()
        disposables.add(triggers.start(next: { subscriber.putNext(Void()) }))
        disposables.add(syncRequests.signal().start(next: { subscriber.putNext(Void()) }))
        return disposables
    }
    return ticks
    |> mapToQueue { _ -> Signal<Void, NoError> in
        return emailSyncOnce(postbox: postbox, accountPeerId: accountPeerId)
    }
}

/// An email chat's older mail, a page at a time as it is scrolled: the hole Postbox wants filled is an id
/// range, and ids follow dates, so it becomes "mail before this date".
func fetchEmailHistoryHole(postbox: Postbox, accountPeerId: PeerId, peerId: PeerId, namespace: MessageId.Namespace, direction: MessageHistoryViewRelativeHoleDirection, space: MessageHistoryHoleOperationSpace, count: Int) -> Signal<FetchMessageHistoryHoleResult?, NoError> {
    let window: ClosedRange<MessageId.Id>
    switch direction {
    case let .range(start, end):
        window = min(start.id, end.id) ... max(start.id, end.id)
    case let .aroundId(id):
        window = 1 ... id.id
    }
    let filled = { (range: ClosedRange<MessageId.Id>, ids: [MessageId]) -> Signal<FetchMessageHistoryHoleResult?, NoError> in
        return postbox.transaction { transaction -> FetchMessageHistoryHoleResult? in
            transaction.removeHole(peerId: peerId, threadId: nil, namespace: namespace, space: space, range: range)
            let indices = IndexSet(integersIn: Int(range.lowerBound) ... Int(range.upperBound))
            return FetchMessageHistoryHoleResult(removedIndices: indices, strictRemovedIndices: indices, actualPeerId: peerId, actualThreadId: nil, ids: ids)
        }
    }
    // Only the whole history has holes worth asking the box about; a tag's (media, files) holds what is stored.
    guard case .everywhere = space, EmailBox.configuration != nil, namespace == Namespaces.Message.Email else {
        return filled(window, [])
    }
    var query = ["contact": "\(peerId.id._internalGetInt64Value())", "limit": "\(min(max(count, 20), 50))"]
    if let before = EmailMessageIds.dateAfter(id: window.upperBound) {
        query["before"] = "\(before)"
    }
    return (EmailClient.get("/gmail/conversation", query: query) as Signal<EmailConversationResponse, EmailBoxError>)
    |> map(Optional.init)
    |> `catch` { error -> Signal<EmailConversationResponse?, NoError> in
        Logger.shared.log("Email", "history of \(peerId) failed: \(error)")
        return .single(nil)
    }
    |> mapToSignal { response -> Signal<FetchMessageHistoryHoleResult?, NoError> in
        guard let response else {
            return .single(nil)
        }
        return postbox.transaction { transaction -> (ClosedRange<MessageId.Id>, [MessageId]) in
            let ids = response.messages.compactMap { storeEmailMessage(transaction: transaction, accountPeerId: accountPeerId, peerId: peerId, data: $0) }
            resetEmailReadState(transaction: transaction, peerId: peerId, contact: response.contact)
            // Everything older is loaded once the box says there is no more; otherwise down to the oldest that came.
            let oldest = ids.map(\.id).min() ?? window.lowerBound
            let lower = !response.more || oldest <= window.lowerBound ? window.lowerBound : oldest
            return (lower ... window.upperBound, ids)
        }
        |> mapToSignal { range, ids in
            return filled(range, ids)
        }
    }
}

/// A read in an email chat marks its mail read in Gmail; the box answers with the chat's new count.
func synchronizeEmailReadState(postbox: Postbox, peerId: PeerId, push: Bool) -> Signal<Never, NoError> {
    let confirm = postbox.transaction { transaction -> Void in
        transaction.confirmSynchronizedIncomingReadState(peerId)
    }
    guard push, EmailBox.configuration != nil else {
        return confirm |> ignoreValues
    }
    return postbox.transaction { transaction -> MessageIndex? in
        if case let .indexBased(maxIncomingReadIndex, _, _, _)? = transaction.getPeerReadStates(peerId)?.first(where: { $0.0 == Namespaces.Message.Email })?.1 {
            return maxIncomingReadIndex
        }
        return nil
    }
    |> mapToSignal { index -> Signal<Void, NoError> in
        guard let index, index.timestamp < Int32.max - 1 else {
            return confirm
        }
        struct Body: Encodable {
            let contact: Int64
            let before: Int64
        }
        let body = Body(contact: peerId.id._internalGetInt64Value(), before: Int64(index.timestamp) * 1000 + 999)
        return (EmailClient.post("/gmail/read", body: body) as Signal<EmailReadResponse, EmailBoxError>)
        |> map(Optional.init)
        |> `catch` { error -> Signal<EmailReadResponse?, NoError> in
            Logger.shared.log("Email", "read of \(peerId) failed: \(error)")
            return .single(nil)
        }
        |> mapToSignal { response -> Signal<Void, NoError> in
            return postbox.transaction { transaction -> Void in
                transaction.confirmSynchronizedIncomingReadState(peerId)
                if let response {
                    resetEmailReadState(transaction: transaction, peerId: peerId, contact: response.contact)
                }
            }
        }
    }
    |> ignoreValues
}
