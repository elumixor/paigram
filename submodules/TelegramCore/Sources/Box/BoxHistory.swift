import Foundation
import Postbox
import SwiftSignalKit

/// One page of a box chat's older history, stored: the ids it got, and whether the box has older still.
struct BoxHistoryPage {
    let ids: [MessageId]
    let more: Bool
}

/// A box chat's older messages, a page at a time as it is scrolled: the hole Postbox wants filled is an id range,
/// and ids follow dates (`BoxMessageIds`), so it becomes "messages before this date". `fetchPage` asks the box for
/// up to `limit` messages before a date (nil: the newest) and stores them; nil when it failed.
func fillBoxHistoryHole(postbox: Postbox, peerId: PeerId, namespace: MessageId.Namespace, direction: MessageHistoryViewRelativeHoleDirection, space: MessageHistoryHoleOperationSpace, count: Int, fetchPage: @escaping (_ before: Int64?, _ limit: Int) -> Signal<BoxHistoryPage?, NoError>) -> Signal<FetchMessageHistoryHoleResult?, NoError> {
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
    guard case .everywhere = space, PaiBox.configuration != nil, namespace == Namespaces.Message.Box else {
        return filled(window, [])
    }
    return fetchPage(BoxMessageIds.dateAfter(id: window.upperBound), min(max(count, 20), 50))
    |> mapToSignal { page -> Signal<FetchMessageHistoryHoleResult?, NoError> in
        guard let page else {
            return .single(nil)
        }
        // Everything older is loaded once the box says there is no more; otherwise down to the oldest that came.
        let oldest = page.ids.map(\.id).min() ?? window.lowerBound
        let lower = !page.more || oldest <= window.lowerBound ? window.lowerBound : oldest
        return filled(lower ... window.upperBound, page.ids)
    }
}

/// A box chat emptied down to a hole, so its messages are fetched again, drawn the box's current way, as it is scrolled.
func refillBoxChat(transaction: Transaction, peerId: PeerId) {
    transaction.clearHistory(peerId, threadId: nil, minTimestamp: nil, maxTimestamp: nil, namespaces: .just([Namespaces.Message.Box]), forEachMedia: nil)
    transaction.addHole(peerId: peerId, threadId: nil, namespace: Namespaces.Message.Box, space: .everywhere, range: 1 ... Int32.max - 1)
}

/// A service's sync loop, one at a time: at start, every `interval`, and whenever `requests` fires (a push came in,
/// the app came to the front); a request while a sync runs is served by the next one.
func managedBoxSync(interval: Double, requests: ValuePipe<Void>, once: @escaping () -> Signal<Void, NoError>) -> Signal<Void, NoError> {
    let triggers = Signal<Void, NoError>.single(Void())
    |> then(
        (Signal<Void, NoError>.complete() |> delay(interval, queue: Queue.concurrentDefaultQueue()) |> then(.single(Void()))) |> restart
    )
    let ticks = Signal<Void, NoError> { subscriber in
        let disposables = DisposableSet()
        disposables.add(triggers.start(next: { subscriber.putNext(Void()) }))
        disposables.add(requests.signal().start(next: { subscriber.putNext(Void()) }))
        return disposables
    }
    return ticks |> mapToQueue { _ in once() }
}
