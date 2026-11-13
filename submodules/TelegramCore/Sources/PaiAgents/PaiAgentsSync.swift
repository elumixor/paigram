import Foundation
import Postbox
import SwiftSignalKit

/// Keeps the agent chats equal to pai's message log: a new agent's chat gets a hole for its history and its newest
/// page; then every row after the newest one stored goes to the chats it concerns. At start, every minute, whenever
/// the app asks, and row by row as pai's event stream delivers them.
private let syncRequests = ValuePipe<Void>()
private let receivedRows = ValuePipe<Data>()
private let syncInterval: Double = 60.0
private let seedPage = 30
private let logPage = 1000

/// pai's event stream, as the app receives it, for agent chats to follow live.
public enum PaiAgentsSync {
    /// A row of the message log (`message.new`, `message.updated`), as JSON.
    public static func receive(rowJSON: Data) {
        receivedRows.putNext(rowJSON)
    }

    /// Reads the message log now rather than at the next tick.
    public static func request() {
        syncRequests.putNext(Void())
    }
}

private func store(transaction: Transaction, accountPeerId: PeerId, rows: [PaiLogRow]) {
    let state = currentPaiAgentsState(transaction: transaction)
    let seeded = Set(state.seeded).intersection(state.agents.map(\.slug))
    for row in rows {
        for slug in row.chats(known: seeded) {
            storePaiRow(transaction: transaction, accountPeerId: accountPeerId, row: row, slug: slug, agents: state.agents)
            settleAwaited(transaction: transaction, row: row, slug: slug)
        }
    }
}

private func fetchRows(_ query: [String: String]) -> Signal<[PaiLogRow], BoxError> {
    return BoxClient.getData("/messages", query: query)
    |> mapToSignal { data -> Signal<[PaiLogRow], BoxError> in
        guard let rows = PaiLogRow.list(data) else {
            return .fail(.decoding("messages"))
        }
        return .single(rows)
    }
}

/// The agents the app knows, as peers under the pai row.
func updatePaiAgents(postbox: Postbox, agents: [PaiAgentInfo]) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> Void in
        let state = currentPaiAgentsState(transaction: transaction)
        guard state.agents != agents else {
            return
        }
        for agent in agents {
            storePaiAgentPeer(transaction: transaction, agent: agent)
        }
        // An agent pai no longer lists is closed.
        for gone in state.agents where !agents.contains(where: { $0.slug == gone.slug }) {
            transaction.updatePeerChatListInclusion(paiAgentPeerId(slug: gone.slug), inclusion: .notIncluded)
        }
        updatePaiAgentsState(transaction: transaction, { state in
            var state = state
            state.agents = agents
            return state
        })
    }
    |> afterCompleted {
        PaiAgentsSync.request()
    }
}

/// A new agent's chat: a hole for all its history, its newest page stored and read, so only what comes after counts.
private func seed(postbox: Postbox, accountPeerId: PeerId, slug: String) -> Signal<Void, BoxError> {
    let peerId = paiAgentPeerId(slug: slug)
    return fetchRows(["agent": slug, "limit": "\(seedPage)"])
    |> mapToSignal { rows -> Signal<Void, BoxError> in
        return postbox.transaction { transaction -> Void in
            let agents = currentPaiAgentsState(transaction: transaction).agents
            transaction.addHole(peerId: peerId, threadId: nil, namespace: Namespaces.Message.Box, space: .everywhere, range: 1 ... Int32.max - 1)
            for row in rows {
                storePaiRow(transaction: transaction, accountPeerId: accountPeerId, row: row, slug: slug, agents: agents)
            }
            let oldest = rows.map(\.id).min()
            let lower: Int32 = rows.count >= seedPage ? (oldest ?? 1) : 1
            transaction.removeHole(peerId: peerId, threadId: nil, namespace: Namespaces.Message.Box, space: .everywhere, range: lower ... Int32.max - 1)
            markPaiAgentChatRead(transaction: transaction, peerId: peerId)
            updatePaiAgentsState(transaction: transaction, { state in
                var state = state
                if !state.seeded.contains(slug) {
                    state.seeded.append(slug)
                }
                return state
            })
        }
        |> castError(BoxError.self)
    }
}

func markPaiAgentChatRead(transaction: Transaction, peerId: PeerId) {
    let namespace = Namespaces.Message.Box
    let top = transaction.getTopPeerMessageIndex(peerId: peerId, namespace: namespace) ?? MessageIndex(id: MessageId(peerId: peerId, namespace: namespace, id: 0), timestamp: 0)
    let state = PeerReadState.indexBased(maxIncomingReadIndex: top, maxOutgoingReadIndex: MessageIndex.upperBound(peerId: peerId, namespace: namespace), count: 0, markedUnread: false)
    transaction.resetIncomingReadStates([peerId: [namespace: state]])
}

/// Every row after the newest stored, a thousand at a time; the very first sync only learns where the log ends.
private func syncLog(postbox: Postbox, accountPeerId: PeerId) -> Signal<Void, BoxError> {
    return postbox.transaction { transaction -> Int32 in
        return currentPaiAgentsState(transaction: transaction).maxId
    }
    |> castError(BoxError.self)
    |> mapToSignal { maxId -> Signal<Void, BoxError> in
        let query = maxId == 0 ? ["limit": "1"] : ["after": "\(maxId)", "limit": "\(logPage)"]
        return fetchRows(query)
        |> mapToSignal { rows -> Signal<Void, BoxError> in
            let applied = postbox.transaction { transaction -> Void in
                if maxId != 0 {
                    store(transaction: transaction, accountPeerId: accountPeerId, rows: rows)
                }
                if let newest = rows.map(\.id).max(), newest > maxId {
                    updatePaiAgentsState(transaction: transaction, { state in
                        var state = state
                        state.maxId = newest
                        return state
                    })
                }
            }
            |> castError(BoxError.self)
            return maxId != 0 && rows.count >= logPage ? applied |> then(syncLog(postbox: postbox, accountPeerId: accountPeerId)) : applied
        }
    }
}

private func syncOnce(postbox: Postbox, accountPeerId: PeerId) -> Signal<Void, NoError> {
    guard PaiBox.configuration != nil else {
        return .complete()
    }
    let seeding = postbox.transaction { transaction -> [String] in
        let state = currentPaiAgentsState(transaction: transaction)
        return state.agents.filter { !$0.closed && !state.seeded.contains($0.slug) }.map(\.slug)
    }
    |> castError(BoxError.self)
    |> mapToSignal { slugs -> Signal<Void, BoxError> in
        return slugs.reduce(Signal<Void, BoxError>.complete(), { signal, slug in
            return signal |> then(seed(postbox: postbox, accountPeerId: accountPeerId, slug: slug))
        })
    }
    return (seeding |> then(syncLog(postbox: postbox, accountPeerId: accountPeerId)))
    |> `catch` { error -> Signal<Void, NoError> in
        Logger.shared.log("PaiAgents", "sync failed: \(error)")
        return .complete()
    }
}

func managedPaiAgentsSync(postbox: Postbox, accountPeerId: PeerId) -> Signal<Void, NoError> {
    let live = receivedRows.signal()
    |> mapToSignal { data -> Signal<Void, NoError> in
        guard let json = try? JSONSerialization.jsonObject(with: data), let row = PaiLogRow(json: json) else {
            return .complete()
        }
        return postbox.transaction { transaction -> Void in
            store(transaction: transaction, accountPeerId: accountPeerId, rows: [row])
        }
    }
    let periodic = managedBoxSync(interval: syncInterval, requests: syncRequests, once: {
        syncOnce(postbox: postbox, accountPeerId: accountPeerId)
    })
    return Signal { subscriber in
        let disposables = DisposableSet()
        disposables.add(live.start())
        disposables.add(periodic.start())
        return disposables
    }
}

/// An agent chat's older messages as it is scrolled: message ids are the log's row ids, so a hole is "rows before".
func fetchPaiAgentHistoryHole(postbox: Postbox, accountPeerId: PeerId, peerId: PeerId, namespace: MessageId.Namespace, direction: MessageHistoryViewRelativeHoleDirection, space: MessageHistoryHoleOperationSpace, count: Int) -> Signal<FetchMessageHistoryHoleResult?, NoError> {
    let window: ClosedRange<MessageId.Id>
    switch direction {
    case let .range(start, end):
        window = min(start.id, end.id) ... max(start.id, end.id)
    case let .aroundId(id):
        window = 1 ... max(1, id.id)
    }
    let filled = { (range: ClosedRange<MessageId.Id>, ids: [MessageId]) -> Signal<FetchMessageHistoryHoleResult?, NoError> in
        return postbox.transaction { transaction -> FetchMessageHistoryHoleResult? in
            transaction.removeHole(peerId: peerId, threadId: nil, namespace: namespace, space: space, range: range)
            let indices = IndexSet(integersIn: Int(range.lowerBound) ... Int(range.upperBound))
            return FetchMessageHistoryHoleResult(removedIndices: indices, strictRemovedIndices: indices, actualPeerId: peerId, actualThreadId: nil, ids: ids)
        }
    }
    guard case .everywhere = space, PaiBox.configuration != nil, namespace == Namespaces.Message.Box else {
        return filled(window, [])
    }
    let limit = min(max(count, 20), 100)
    let page = postbox.transaction { transaction -> String? in
        return currentPaiAgentsState(transaction: transaction).agent(peerId: peerId)?.slug
    }
    |> mapToSignal { slug -> Signal<BoxHistoryPage?, NoError> in
        guard let slug else {
            return .single(BoxHistoryPage(ids: [], more: false))
        }
        var query = ["agent": slug, "limit": "\(limit)"]
        // Ids above any row's (a message still sending) ask for the newest.
        if window.upperBound < 0x40000000 {
            query["before"] = "\(window.upperBound + 1)"
        }
        return fetchRows(query)
        |> map(Optional.init)
        |> `catch` { error -> Signal<[PaiLogRow]?, NoError> in
            Logger.shared.log("PaiAgents", "history of \(slug) failed: \(error)")
            return .single(nil)
        }
        |> mapToSignal { rows -> Signal<BoxHistoryPage?, NoError> in
            guard let rows else {
                return .single(nil)
            }
            return postbox.transaction { transaction -> BoxHistoryPage? in
                let agents = currentPaiAgentsState(transaction: transaction).agents
                let ids = rows.map { storePaiRow(transaction: transaction, accountPeerId: accountPeerId, row: $0, slug: slug, agents: agents) }
                return BoxHistoryPage(ids: ids, more: rows.count >= limit)
            }
        }
    }
    return retryingBoxPage(page, attempts: 4, wait: 1.0)
    |> mapToSignal { page -> Signal<FetchMessageHistoryHoleResult?, NoError> in
        guard let page else {
            return .single(nil)
        }
        let oldest = page.ids.map(\.id).min() ?? window.lowerBound
        let lower = !page.more || oldest <= window.lowerBound ? window.lowerBound : oldest
        return filled(lower ... window.upperBound, page.ids)
    }
}

/// pai keeps no read state of its own: reading an agent chat stays on this device.
func synchronizePaiAgentReadState(postbox: Postbox, peerId: PeerId) -> Signal<Never, NoError> {
    return postbox.transaction { transaction -> Void in
        transaction.confirmSynchronizedIncomingReadState(peerId)
    }
    |> ignoreValues
}

/// Muting an agent chat stays on this device.
func pushPaiAgentNotificationSettings(postbox: Postbox, peerId: PeerId, settings: PeerNotificationSettings) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> Void in
        transaction.updateCurrentPeerNotificationSettings([peerId: settings])
        if let pending = transaction.getPendingPeerNotificationSettings(peerId), pending.isEqual(to: settings) {
            transaction.updatePendingPeerNotificationSettings(peerId: peerId, settings: nil)
        }
    }
}
