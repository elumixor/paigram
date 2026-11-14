import Foundation
import Postbox
import SwiftSignalKit

/// Each of pai's agents talks in its own forum topic of the pai bot's chat, made when the agent was (or, for an agent
/// older than topics, when pai backfilled it). What the agent said before its topic is only in pai's message log, so
/// the topic keeps a `Box` hole below its first message, filled from `GET /messages?agent=&beforeAt=` the way
/// Telegram fills any history: a page as the topic is scrolled back to it.

private func fetchRows(_ query: [String: String]) -> Signal<[PaiLogRow], BoxError> {
    return BoxClient.getData("/messages", query: query)
    |> mapToSignal { data -> Signal<[PaiLogRow], BoxError> in
        guard let rows = PaiLogRow.list(data) else {
            return .fail(.decoding("messages"))
        }
        return .single(rows)
    }
}

/// The agents the app read from pai (`/agents`) and the bot's peer: agent peers made or updated, topics new to this
/// device given their history hole; the agent chats an earlier build kept go, once.
func updatePaiAgents(postbox: Postbox, agents: [PaiAgentInfo], botPeerId: PeerId?) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> Void in
        let previous = currentPaiAgentsState(transaction: transaction)
        var state = previous
        if state.cleared != true {
            for slug in Set((state.agents + agents).map(\.slug)) {
                clearPaiAgentChat(transaction: transaction, slug: slug)
            }
            state.cleared = true
        }
        if state.agents != agents {
            for agent in agents {
                storePaiAgentPeer(transaction: transaction, agent: agent)
            }
            state.agents = agents
        }
        if let botPeerId {
            if state.botPeerId != botPeerId.toInt64() {
                state.botPeerId = botPeerId.toInt64()
                state.historyTopics = []
            }
            var given = Set(state.historyTopics ?? [])
            // pai's own topic is the bot chat's oldest: everything it said was said there.
            for agent in agents where agent.slug != "pai" {
                guard let thread = agent.threadId, !given.contains(thread) else {
                    continue
                }
                transaction.addHole(peerId: botPeerId, threadId: thread, namespace: Namespaces.Message.Box, space: .everywhere, range: 1 ... Int32.max - 1)
                given.insert(thread)
            }
            state.historyTopics = given.sorted()
        }
        if state != previous {
            updatePaiAgentsState(transaction: transaction, { _ in state })
        }
    }
}

/// When a topic began: its creation, else its first message's date (the topic-created message's id is the topic's).
private func topicStart(transaction: Transaction, peerId: PeerId, thread: Int64) -> Int32? {
    if let data = transaction.getMessageHistoryThreadInfo(peerId: peerId, threadId: thread)?.data.get(MessageHistoryThreadData.self), data.creationDate > 0 {
        return data.creationDate
    }
    if thread > 0, thread < Int64(Int32.max), let message = transaction.getMessage(MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: Int32(thread))) {
        return message.timestamp
    }
    return nil
}

/// A page of an agent's history from before its topic, as the topic is scrolled back to it. A hole that is not an agent
/// topic's goes; a page pai could not give stays a hole, asked again the next time the topic is open.
func fetchPaiTopicHistoryHole(postbox: Postbox, peerId: PeerId, thread: Int64, namespace: MessageId.Namespace, direction: MessageHistoryViewRelativeHoleDirection, space: MessageHistoryHoleOperationSpace, count: Int) -> Signal<FetchMessageHistoryHoleResult?, NoError> {
    let window: ClosedRange<MessageId.Id>
    switch direction {
    case let .range(start, end):
        window = min(start.id, end.id) ... max(start.id, end.id)
    case let .aroundId(id):
        window = 1 ... max(1, id.id)
    }
    let filled = { (range: ClosedRange<MessageId.Id>, ids: [MessageId]) -> Signal<FetchMessageHistoryHoleResult?, NoError> in
        return postbox.transaction { transaction -> FetchMessageHistoryHoleResult? in
            transaction.removeHole(peerId: peerId, threadId: thread, namespace: namespace, space: space, range: range)
            let indices = IndexSet(integersIn: Int(range.lowerBound) ... Int(range.upperBound))
            return FetchMessageHistoryHoleResult(removedIndices: indices, strictRemovedIndices: indices, actualPeerId: peerId, actualThreadId: thread, ids: ids)
        }
    }
    guard case .everywhere = space, namespace == Namespaces.Message.Box else {
        return filled(window, [])
    }
    // Pai could not give the first page: while the topic holds none of it, the hole would be the only one the topic
    // asks for (Postbox asks for an empty space's hole first), so it goes for now and comes back with the next agent
    // list. With a page held it stays, and is asked again later.
    let unavailable: () -> Signal<FetchMessageHistoryHoleResult?, NoError> = {
        guard window == 1 ... Int32.max - 1 else {
            return .single(nil)
        }
        return postbox.transaction { transaction -> Void in
            updatePaiAgentsState(transaction: transaction, { state in
                var state = state
                state.historyTopics = state.historyTopics?.filter { $0 != thread }
                return state
            })
        }
        |> mapToSignal { _ in filled(window, []) }
    }
    let limit = min(max(count, 20), 100)
    return postbox.transaction { transaction -> (slug: String, start: Int32?, agents: [PaiAgentInfo])? in
        let state = currentPaiAgentsState(transaction: transaction)
        guard state.botPeerId == peerId.toInt64(), let agent = state.agent(thread: thread), agent.slug != "pai" else {
            return nil
        }
        return (agent.slug, topicStart(transaction: transaction, peerId: peerId, thread: thread), state.agents)
    }
    |> mapToSignal { topic -> Signal<FetchMessageHistoryHoleResult?, NoError> in
        guard let topic else {
            return filled(1 ... Int32.max - 1, [])
        }
        guard let start = topic.start, PaiBox.configuration != nil else {
            return unavailable()
        }
        var query = ["agent": topic.slug, "limit": "\(limit)", "beforeAt": "\(Int64(start) * 1000)"]
        if window.upperBound < Int32.max - 1 {
            query["before"] = "\(paiLogRowBound(historyMessageId: window.upperBound))"
        }
        return (fetchRows(query) |> map(Optional.init) |> `catch` { error -> Signal<[PaiLogRow]?, NoError> in
            Logger.shared.log("PaiAgents", "history of \(topic.slug) failed: \(error)")
            return .single(nil)
        })
        |> mapToSignal { rows -> Signal<FetchMessageHistoryHoleResult?, NoError> in
            guard let rows else {
                return unavailable()
            }
            return postbox.transaction { transaction -> [MessageId] in
                return rows.map { storePaiHistoryRow(transaction: transaction, botPeerId: peerId, thread: thread, row: $0, slug: topic.slug, agents: topic.agents) }
            }
            |> mapToSignal { ids -> Signal<FetchMessageHistoryHoleResult?, NoError> in
                // Everything older is loaded once pai gives less than a page; otherwise down to the oldest that came.
                let oldest = ids.map(\.id).min() ?? window.lowerBound
                let lower = rows.count < limit || oldest <= window.lowerBound ? window.lowerBound : oldest
                return filled(lower ... window.upperBound, ids)
            }
        }
    }
}
