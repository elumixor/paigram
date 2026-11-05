import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore
import AccountContext
import TextFormat
import LocalizedPeerData
import UndoUI
import PaiUI
import ChatInterfaceState
import ChatPresentationInterfaceState

extension ChatControllerImpl {
    /// Rewrites the composer's draft (or the message being edited) into what the user would actually send here:
    /// the box writes it from the chat's recent history in the chat's language and the user's style.
    func openPaiCompose() {
        guard #available(iOS 16.0, *) else {
            self.chatDisplayNode.openTextProcessing()
            return
        }
        guard let peerId = self.chatLocation.peerId, let panel = self.chatDisplayNode.textInputPanelNode, !panel.isPaiComposing else {
            return
        }
        let original = panel.inputTextState
        let draft = paiComposeDraft(original)
        if draft.isEmpty {
            return
        }
        self.runPaiCompose(peerId: peerId, draft: draft, original: original, answers: [])
    }

    /// A reply button under an email: the answer it names, drafted in the user's voice as a reply to that email.
    /// Only drafted: the composer gets the text and the user sends it, or not.
    func unsubscribeFromEmail(_ messageId: EngineMessage.Id, progress: Promise<Bool>?) {
        progress?.set(.single(true))
        let _ = (self.context.engine.email.unsubscribe(messageId: messageId)
        |> deliverOnMainQueue).startStandalone(error: { [weak self] error in
            progress?.set(.single(false))
            Logger.shared.log("Email", "unsubscribe failed: \(error)")
            guard let self else {
                return
            }
            self.present(UndoOverlayController(presentationData: self.presentationData, content: .info(title: nil, text: "Could not unsubscribe", timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }), in: .current)
        }, completed: { [weak self] in
            progress?.set(.single(false))
            guard let self else {
                return
            }
            self.present(UndoOverlayController(presentationData: self.presentationData, content: .succeed(text: "Unsubscribed", timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }), in: .current)
        })
    }
    
    func draftEmailReply(to messageId: EngineMessage.Id, intent: String) {
        self.updateChatPresentationInterfaceState(animated: true, interactive: true, { state in
            var state = state.updatedInterfaceState { interfaceState in
                return interfaceState
                    .withUpdatedReplyMessageSubject(ChatInterfaceState.ReplyMessageSubject(messageId: messageId, quote: nil, innerSubject: nil))
                    .withUpdatedEffectiveInputState(ChatTextInputState(inputText: NSAttributedString(string: intent)))
            }
            if state.inputMode == .none {
                state = state.updatedInputMode { _ in .text }
            }
            return state
        })
        // The panel takes the new text on this pass; compose reads it from there.
        DispatchQueue.main.async { [weak self] in
            self?.openPaiCompose()
        }
    }

    @available(iOS 16.0, *)
    private func runPaiCompose(peerId: EnginePeer.Id, draft: String, original: ChatTextInputState, answers: [PaiComposeAnswer]) {
        self.chatDisplayNode.textInputPanelNode?.isPaiComposing = true
        let _ = (self.paiComposeContext(peerId: peerId)
        |> deliverOnMainQueue).startStandalone(next: { [weak self] composeContext in
            Task { @MainActor [weak self] in
                let result: Result<PaiComposeResult, Error>
                do {
                    result = .success(try await PaiClient().compose(context: composeContext, draft: draft, answers: answers))
                } catch {
                    result = .failure(error)
                }
                guard let self else {
                    return
                }
                self.chatDisplayNode.textInputPanelNode?.isPaiComposing = false

                switch result {
                case let .failure(error):
                    self.presentPaiComposeToast(title: nil, text: error.localizedDescription, undo: nil)
                case let .success(composed):
                    // A draft typed on while the box was writing is newer than its answer; keep it.
                    guard let panel = self.chatDisplayNode.textInputPanelNode, paiComposeDraft(panel.inputTextState) == draft else {
                        self.presentPaiComposeToast(title: nil, text: "The draft changed while it was being rewritten", undo: nil)
                        return
                    }
                    if composed.questions.isEmpty {
                        self.applyPaiCompose(text: composed.text, original: original, notes: composed.notes)
                        return
                    }
                    let controller = PaiComposeQuestionsController(context: self.context, result: composed)
                    controller.rewrite = { [weak self] newAnswers in
                        self?.runPaiCompose(peerId: peerId, draft: draft, original: original, answers: answers + newAnswers)
                    }
                    controller.useText = { [weak self] in
                        self?.applyPaiCompose(text: composed.text, original: original, notes: composed.notes)
                    }
                    self.push(controller)
                }
            }
        })
    }

    private func applyPaiCompose(text: String, original: ChatTextInputState, notes: [String]) {
        if text.isEmpty {
            self.presentPaiComposeToast(title: nil, text: "Nothing came back to replace the draft with", undo: nil)
            return
        }
        self.updateChatPresentationInterfaceState(animated: true, interactive: true, { state in
            return state.updatedInterfaceState { $0.withUpdatedEffectiveInputState(ChatTextInputState(inputText: NSAttributedString(string: text))) }
        })
        // The box's notes ride on the undo toast rather than a sheet: there is nothing to answer.
        self.presentPaiComposeToast(title: notes.isEmpty ? nil : "Rewritten", text: notes.isEmpty ? "Rewritten" : notes.joined(separator: "\n"), undo: { [weak self] in
            // Sent or edited since: the draft is gone and must not come back into the field.
            guard let self, let panel = self.chatDisplayNode.textInputPanelNode, paiComposeDraft(panel.inputTextState) == text.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return
            }
            self.updateChatPresentationInterfaceState(animated: true, interactive: true, { state in
                return state.updatedInterfaceState { $0.withUpdatedEffectiveInputState(original) }
            })
        })
    }

    private func presentPaiComposeToast(title: String?, text: String, undo: (() -> Void)?) {
        let content: UndoOverlayContent = .info(title: title, text: text, timeout: nil, customUndoText: undo != nil ? "Undo" : nil)
        self.present(UndoOverlayController(presentationData: self.presentationData, content: content, elevatedLayout: false, action: { action in
            if case .undo = action {
                undo?()
            }
            return false
        }), in: .current)
    }

    /// The chat as the box reads it: its title, kind and the last 40 messages that carry text, oldest first.
    private func paiComposeContext(peerId: EnginePeer.Id) -> Signal<PaiComposeContext, NoError> {
        let presentationData = self.presentationData
        let accountPeerId = self.context.account.peerId
        let peer = self.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
        // Local history only: the chat is open, so what the user sees is already in Postbox.
        let history = self.context.account.postbox.aroundMessageHistoryViewForLocation(.peer(peerId: peerId, threadId: self.chatLocation.threadId), anchor: .upperBound, ignoreMessagesInTimestampRange: nil, ignoreMessageIds: Set(), count: 100, fixedCombinedReadStates: nil, topTaggedMessageIdNamespaces: Set(), tag: nil, appendMessagesFromTheSameGroup: false, namespaces: .not(Namespaces.Message.allNonRegular), orderStatistics: [])
        |> take(1)

        return combineLatest(peer, history)
        |> map { peer, view -> PaiComposeContext in
            let all = view.0.entries.map(\.message)
            let chatTitle = peer?.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder) ?? ""
            let messages = all.filter { !$0.text.isEmpty }.suffix(40).map { message -> PaiComposeMessage in
                let author = message.author.flatMap { EnginePeer($0).displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder) } ?? chatTitle
                return PaiComposeMessage(fromMe: !message.effectivelyIncoming(accountPeerId), author: author, text: message.text, at: message.timestamp)
            }

            let kind: PaiComposeContext.Kind
            var subject: String?
            if peerId.isEmail {
                kind = .email
                subject = all.reversed().lazy.compactMap { message in
                    return message.attributes.first(where: { $0 is EmailMessageAttribute }) as? EmailMessageAttribute
                }.first(where: { !$0.subject.isEmpty })?.subject
            } else if peerId.isWhatsApp {
                kind = .whatsapp
            } else {
                kind = .telegram
            }
            return PaiComposeContext(kind: kind, chatTitle: chatTitle, subject: subject, messages: Array(messages))
        }
    }
}

/// The composer's text as the box gets it: plain, custom emoji back to their characters, rich structure dropped.
private func paiComposeDraft(_ state: ChatTextInputState) -> String {
    return expandedInputStateAttributedString(state.inputText).string.trimmingCharacters(in: .whitespacesAndNewlines)
}
