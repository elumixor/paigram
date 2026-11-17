import AccountContext
import Display
import Foundation
import ItemListUI
import Postbox
import PresentationDataUtils
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import UIKit

/// The decisions the user's agents wait on, across all of them: one row per ask, a tap jumps to it in its chat.

private final class PaiNeedsArguments {
    let open: (PaiNeed) -> Void

    init(open: @escaping (PaiNeed) -> Void) {
        self.open = open
    }
}

private struct PaiNeedsEntry: ItemListNodeEntry {
    let index: Int
    let need: PaiNeed

    var section: ItemListSectionId { 0 }
    var stableId: String { need.id }

    static func <(lhs: PaiNeedsEntry, rhs: PaiNeedsEntry) -> Bool {
        return lhs.index < rhs.index
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! PaiNeedsArguments
        let agent = PaiChat.agent(need.agent)
        let need = self.need
        return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: agent.map { PaiAgentList.portrait(agent: $0, size: 29.0) }, title: agent?.name ?? need.from, label: paiNeedExcerpt(need.question.paiPlain), labelStyle: .multilineDetailText, sectionId: self.section, style: .blocks, action: {
            arguments.open(need)
        })
    }
}

/// Questions arrive cut at a fixed length (often mid-word) or unbounded: show at most ~100 characters, ending on a word with an ellipsis.
private func paiNeedExcerpt(_ text: String) -> String {
    let flat = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    guard flat.count > 100 else { return flat }
    let head = String(flat.prefix(100))
    let cut = head.lastIndex(of: " ").map { String(head[..<$0]) } ?? head
    return cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;-")) + "…"
}

public func paiNeedsController(context: AccountContext, navigationController: NavigationController) -> ViewController {
    let arguments = PaiNeedsArguments(open: { [weak navigationController] need in
        guard let navigationController else {
            return
        }
        openPaiNeed(need, context: context, navigationController: navigationController)
    })
    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, PaiChat.needsSignal)
    |> map { presentationData, needs -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let title = needs.count == 1 ? "1 Decision" : "\(needs.count) Decisions"
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        let entries = needs.sorted { $0.createdAt > $1.createdAt }.enumerated().map { PaiNeedsEntry(index: $0.offset, need: $0.element) }
        let emptyState: ItemListControllerEmptyStateItem? = entries.isEmpty ? ItemListTextEmptyStateItem(text: "Nothing waits on you.") : nil
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, emptyStateItem: emptyState, animateChanges: true)
        return (controllerState, (listState, arguments))
    }
    return ItemListController(context: context, state: signal)
}

/// Into the ask's message in its topic, highlighted; into the agent's chat when the message is not stored here.
private func openPaiNeed(_ need: PaiNeed, context: AccountContext, navigationController: NavigationController) {
    let fallback = { [weak navigationController] in
        guard let navigationController else {
            return
        }
        PaiAgentList.open(slug: need.agent ?? PaiChat.paiSlug, context: context, navigationController: navigationController)
    }
    guard let askId = need.askId else {
        fallback()
        return
    }
    let _ = (PaiAgentList.botPeer(context: context)
    |> mapToSignal { peer -> Signal<(EnginePeer, MessageId, Int64?)?, NoError> in
        guard let peer else {
            return .single(nil)
        }
        return context.account.postbox.transaction { transaction -> (EnginePeer, MessageId, Int64?)? in
            var found: (MessageId, Int64?)?
            transaction.scanTopMessages(peerId: peer.id, namespace: Namespaces.Message.Cloud, limit: 500) { message in
                if let meta = PaiTrailer.find(message)?.meta, meta.kind == "ask", meta.askId == askId {
                    found = (message.id, message.threadId)
                    return false
                }
                return true
            }
            return found.map { (peer, $0.0, $0.1) }
        }
    }
    |> deliverOnMainQueue).startStandalone(next: { [weak navigationController] result in
        guard let navigationController else {
            return
        }
        guard let (peer, messageId, threadId) = result else {
            fallback()
            return
        }
        let location: NavigateToChatControllerParams.Location
        if let threadId {
            location = .replyThread(ChatReplyThreadMessage(peerId: peer.id, threadId: threadId, channelMessageId: nil, isChannelPost: false, isForumPost: true, isMonoforumPost: false, maxMessage: nil, maxReadIncomingMessageId: nil, maxReadOutgoingMessageId: nil, unreadCount: 0, initialFilledHoles: IndexSet(), initialAnchor: .automatic, isNotAvailable: false))
        } else {
            location = .peer(peer)
        }
        context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: context, chatLocation: location, subject: .message(id: .id(messageId), highlight: ChatControllerSubject.MessageHighlight(), timecode: nil, setupReply: false)))
    })
}
