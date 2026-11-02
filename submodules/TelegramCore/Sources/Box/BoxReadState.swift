import Foundation
import Postbox
import SwiftSignalKit

/// The box counts what is unread in a chat; the read line sits just before its oldest unread message. What went
/// out shows as read: the box carries no read receipts.
func resetBoxReadState(transaction: Transaction, peerId: PeerId, unread: Int32, oldestUnread: Int64?) {
    let namespace = Namespaces.Message.Box
    let maxIncomingReadIndex: MessageIndex
    if unread > 0, let oldestUnread {
        maxIncomingReadIndex = MessageIndex(id: MessageId(peerId: peerId, namespace: namespace, id: BoxMessageIds.base(date: oldestUnread) - 1), timestamp: Int32(clamping: oldestUnread / 1000) - 1)
    } else {
        maxIncomingReadIndex = MessageIndex.upperBound(peerId: peerId, namespace: namespace)
    }
    let state = PeerReadState.indexBased(maxIncomingReadIndex: maxIncomingReadIndex, maxOutgoingReadIndex: MessageIndex.upperBound(peerId: peerId, namespace: namespace), count: unread, markedUnread: false)
    if transaction.getPeerReadStates(peerId)?.first(where: { $0.0 == namespace })?.1 != state {
        transaction.resetIncomingReadStates([peerId: [namespace: state]])
    }
}

/// A read in a box chat goes to the box (`post`, given how far the chat is read), which answers with the chat's
/// new count; the read state is confirmed either way, so a failure never loops.
func synchronizeBoxReadState(postbox: Postbox, peerId: PeerId, push: Bool, post: @escaping (MessageIndex) -> Signal<((Transaction) -> Void)?, NoError>) -> Signal<Never, NoError> {
    let confirm = postbox.transaction { transaction -> Void in
        transaction.confirmSynchronizedIncomingReadState(peerId)
    }
    guard push, PaiBox.configuration != nil else {
        return confirm |> ignoreValues
    }
    return postbox.transaction { transaction -> MessageIndex? in
        if case let .indexBased(maxIncomingReadIndex, _, _, _)? = transaction.getPeerReadStates(peerId)?.first(where: { $0.0 == Namespaces.Message.Box })?.1 {
            return maxIncomingReadIndex
        }
        return nil
    }
    |> mapToSignal { index -> Signal<Void, NoError> in
        guard let index, index.timestamp < Int32.max - 1 else {
            return confirm
        }
        return post(index)
        |> mapToSignal { apply -> Signal<Void, NoError> in
            return postbox.transaction { transaction -> Void in
                transaction.confirmSynchronizedIncomingReadState(peerId)
                apply?(transaction)
            }
        }
    }
    |> ignoreValues
}
