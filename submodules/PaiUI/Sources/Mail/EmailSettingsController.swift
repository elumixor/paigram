import AccountContext
import Display
import Foundation
import ItemListUI
import PresentationDataUtils
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import UIKit

/// Settings › Email: the mailboxes the box reads (named and coloured as in Spark), and a chat with a new address.

private struct EmailSettingsState: Equatable {
    var address = ""
    var name = ""
    var isOpening = false
    var error: String?

    var canOpen: Bool {
        let trimmed = self.address.trimmingCharacters(in: .whitespaces)
        return !self.isOpening && trimmed.contains("@") && trimmed.contains(".")
    }
}

private final class EmailSettingsArguments {
    let updateAddress: (String) -> Void
    let updateName: (String) -> Void
    let open: () -> Void

    init(updateAddress: @escaping (String) -> Void, updateName: @escaping (String) -> Void, open: @escaping () -> Void) {
        self.updateAddress = updateAddress
        self.updateName = updateName
        self.open = open
    }
}

private enum EmailSettingsSection: Int32 {
    case mailboxes
    case newEmail
}

private enum EmailSettingsEntry: ItemListNodeEntry {
    case mailboxesHeader
    case mailbox(Int32, EmailAccountData)
    case mailboxesInfo(Int)
    case newEmailHeader
    case address(String)
    case name(String)
    case open(Bool, Bool)
    case newEmailInfo(String?)

    var section: ItemListSectionId {
        switch self {
        case .mailboxesHeader, .mailbox, .mailboxesInfo:
            return EmailSettingsSection.mailboxes.rawValue
        case .newEmailHeader, .address, .name, .open, .newEmailInfo:
            return EmailSettingsSection.newEmail.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .mailboxesHeader: return 0
        case let .mailbox(index, _): return 1 + index
        case .mailboxesInfo: return 99
        case .newEmailHeader: return 100
        case .address: return 101
        case .name: return 102
        case .open: return 103
        case .newEmailInfo: return 104
        }
    }

    static func <(lhs: EmailSettingsEntry, rhs: EmailSettingsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! EmailSettingsArguments
        switch self {
        case .mailboxesHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "MAILBOXES", sectionId: self.section)
        case let .mailbox(_, account):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: mailboxIcon(hex: account.color), title: account.title.isEmpty ? account.label : account.title, label: account.email, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .mailboxesInfo(count):
            return ItemListTextItem(presentationData: presentationData, text: .plain("\(count) email chats. New mail arrives as a message from its sender; what you send goes out as an email from the mailbox its thread is in."), sectionId: self.section)
        case .newEmailHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "NEW EMAIL", sectionId: self.section)
        case let .address(text):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: text, placeholder: "Address", type: .email, sectionId: self.section, textUpdated: arguments.updateAddress, action: arguments.open)
        case let .name(text):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: text, placeholder: "Name (optional)", sectionId: self.section, textUpdated: arguments.updateName, action: arguments.open)
        case let .open(isOpening, enabled):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: isOpening ? "Opening…" : "Open Chat", kind: enabled ? .generic : .disabled, alignment: .natural, sectionId: self.section, style: .blocks, action: arguments.open)
        case let .newEmailInfo(error):
            return ItemListTextItem(presentationData: presentationData, text: .plain(error ?? "Opens a chat with the address; your first message becomes the email, its first line the subject."), sectionId: self.section)
        }
    }
}

/// The mailbox's colour from Spark (`#rrggbb`) as a dot in the row's icon slot.
private func mailboxIcon(hex: String) -> UIImage? {
    let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x888888
    return generateImage(CGSize(width: 30.0, height: 30.0), rotatedContext: { size, context in
        context.clear(CGRect(origin: CGPoint(), size: size))
        context.setFillColor(UIColor(rgb: value).cgColor)
        context.fillEllipse(in: CGRect(x: 9.0, y: 9.0, width: 12.0, height: 12.0))
    })
}

public func emailSettingsController(context: AccountContext, openChat: @escaping (EnginePeer.Id) -> Void) -> ViewController {
    let statePromise = ValuePromise(EmailSettingsState(), ignoreRepeated: true)
    let stateValue = Atomic(value: EmailSettingsState())
    let updateState: ((inout EmailSettingsState) -> Void) -> Void = { f in
        statePromise.set(stateValue.modify { state in
            var state = state
            f(&state)
            return state
        })
    }
    let disposable = MetaDisposable()

    let arguments = EmailSettingsArguments(updateAddress: { address in
        updateState { $0.address = address }
    }, updateName: { name in
        updateState { $0.name = name }
    }, open: {
        let state = stateValue.with { $0 }
        guard state.canOpen else {
            return
        }
        updateState { $0.isOpening = true; $0.error = nil }
        let address = state.address.trimmingCharacters(in: .whitespaces).lowercased()
        disposable.set((context.engine.email.openChat(address: address, name: state.name.trimmingCharacters(in: .whitespaces))
        |> deliverOnMainQueue).start(next: { peerId in
            updateState { $0.isOpening = false }
            openChat(peerId)
        }, error: { error in
            updateState { $0.isOpening = false; $0.error = error.description }
        }))
    })

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var entries: [EmailSettingsEntry] = [.mailboxesHeader]
        entries += EmailChats.accounts.enumerated().map { .mailbox(Int32($0.offset), $0.element) }
        entries += [.mailboxesInfo(EmailChats.chatCount), .newEmailHeader, .address(state.address), .name(state.name), .open(state.isOpening, state.canOpen), .newEmailInfo(state.error)]
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("Email"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        disposable.dispose()
    }

    return ItemListController(context: context, state: signal)
}
