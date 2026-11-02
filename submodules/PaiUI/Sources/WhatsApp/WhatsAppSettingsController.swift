import AccountContext
import AlertUI
import Display
import Foundation
import ItemListUI
import PresentationDataUtils
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import UIKit

/// Settings › WhatsApp: whether the box is linked to his WhatsApp, linking it from this phone with a code (a QR
/// shown on the phone that has to scan it is no use), linking again, the box's pushes, and reloading the chats.

/// The box's WhatsApp connection as `/whatsapp/status` reports it.
struct WhatsAppStatus: Decodable, Equatable {
    struct Seen: Decodable, Equatable {
        let chats: Int
        let messages: Int
    }

    let state: String
    let linked: Bool
    let me: String?
    let name: String?
    let cached: Seen?
    let notify: Bool?
    let error: String?
}

private struct PairingCode: Decodable {
    let code: String
}

/// `/whatsapp/relink` answers only that it started; the next status read says where it is.
private struct Relinking: Decodable {
    let relinking: Bool
}

private struct WhatsAppSettingsState: Equatable {
    var status: WhatsAppStatus?
    var phone = ""
    var code: String?
    var isBusy = false
    var error: String?
}

private final class WhatsAppSettingsArguments {
    let updatePhone: (String) -> Void
    let requestCode: () -> Void
    let copyCode: () -> Void
    let openWhatsApp: () -> Void
    let setNotify: (Bool) -> Void
    let reloadChats: () -> Void
    let relink: () -> Void

    init(updatePhone: @escaping (String) -> Void, requestCode: @escaping () -> Void, copyCode: @escaping () -> Void, openWhatsApp: @escaping () -> Void, setNotify: @escaping (Bool) -> Void, reloadChats: @escaping () -> Void, relink: @escaping () -> Void) {
        self.updatePhone = updatePhone
        self.requestCode = requestCode
        self.copyCode = copyCode
        self.openWhatsApp = openWhatsApp
        self.setNotify = setNotify
        self.reloadChats = reloadChats
        self.relink = relink
    }
}

private enum WhatsAppSettingsSection: Int32 {
    case account
    case link
    case notifications
    case actions
}

private enum WhatsAppSettingsEntry: ItemListNodeEntry {
    case account(String, String)
    case accountInfo(String)
    case linkHeader
    case phone(String)
    case code(String)
    case openWhatsApp
    case requestCode(String, Bool)
    case linkInfo
    case notify(Bool, Bool)
    case notifyInfo
    case reload
    case relink
    case actionsInfo(String)

    var section: ItemListSectionId {
        switch self {
        case .account, .accountInfo:
            return WhatsAppSettingsSection.account.rawValue
        case .linkHeader, .phone, .code, .openWhatsApp, .requestCode, .linkInfo:
            return WhatsAppSettingsSection.link.rawValue
        case .notify, .notifyInfo:
            return WhatsAppSettingsSection.notifications.rawValue
        case .reload, .relink, .actionsInfo:
            return WhatsAppSettingsSection.actions.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .account: return 0
        case .accountInfo: return 1
        case .linkHeader: return 10
        case .phone: return 11
        case .code: return 12
        case .openWhatsApp: return 13
        case .requestCode: return 14
        case .linkInfo: return 15
        case .notify: return 20
        case .notifyInfo: return 21
        case .reload: return 30
        case .relink: return 31
        case .actionsInfo: return 32
        }
    }

    static func <(lhs: WhatsAppSettingsEntry, rhs: WhatsAppSettingsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! WhatsAppSettingsArguments
        switch self {
        case let .account(title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: PresentationResourcesSettings.whatsApp, title: title, label: label, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .accountInfo(text), let .actionsInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case .linkHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "LINK THIS PHONE", sectionId: self.section)
        case let .phone(text):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: text, placeholder: "Your WhatsApp number", type: .number, sectionId: self.section, textUpdated: arguments.updatePhone, action: arguments.requestCode)
        case let .code(code):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: code, titleFont: .bold, label: "Copy", labelStyle: .text, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: arguments.copyCode)
        case .openWhatsApp:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: "Open WhatsApp", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: arguments.openWhatsApp)
        case let .requestCode(title, enabled):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: enabled ? .generic : .disabled, alignment: .natural, sectionId: self.section, style: .blocks, action: arguments.requestCode)
        case .linkInfo:
            return ItemListTextItem(presentationData: presentationData, text: .plain("In WhatsApp: Settings › Linked devices › Link a device › Link with phone number instead, then type the code."), sectionId: self.section)
        case let .notify(value, enabled):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Notify about new messages", value: value, enabled: enabled, sectionId: self.section, style: .blocks, updated: arguments.setNotify)
        case .notifyInfo:
            return ItemListTextItem(presentationData: presentationData, text: .plain("WhatsApp's own app notifies too: turn one of them off."), sectionId: self.section)
        case .reload:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: "Reload All Chats", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: arguments.reloadChats)
        case .relink:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: "Link Again", kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: arguments.relink)
        }
    }
}

private func whatsAppSettingsEntries(_ state: WhatsAppSettingsState) -> [WhatsAppSettingsEntry] {
    var entries: [WhatsAppSettingsEntry] = []
    let status = state.status
    let label: String
    if let status {
        if status.linked, let me = status.me {
            label = "+\(me)"
        } else {
            label = status.state == "linking" ? "Waiting for a phone" : "Not linked"
        }
    } else {
        label = "Checking…"
    }
    entries.append(.account(status?.linked == true ? status?.name ?? "Linked" : "WhatsApp", label))
    var info = status?.cached.map { "The box has seen \($0.chats) chats and \($0.messages) messages. Older messages come from your phone as you scroll up in a chat." } ?? ""
    if let error = status?.error, status?.linked == false {
        info = error
    }
    if !info.isEmpty {
        entries.append(.accountInfo(info))
    }
    if status?.linked == false {
        entries.append(.linkHeader)
        entries.append(.phone(state.phone))
        if let code = state.code {
            entries.append(.code(code))
            entries.append(.openWhatsApp)
        }
        let title = state.isBusy ? "Asking WhatsApp…" : (state.code == nil ? "Get a Code" : "Get a New Code")
        entries.append(.requestCode(title, !state.isBusy && state.phone.filter(\.isNumber).count >= 8))
        entries.append(.linkInfo)
    }
    entries.append(.notify(status?.notify ?? true, status != nil))
    entries.append(.notifyInfo)
    entries.append(.reload)
    if status?.linked == true {
        entries.append(.relink)
    }
    if let error = state.error {
        entries.append(.actionsInfo(error))
    }
    return entries
}

@available(iOS 16.0, *)
public func whatsAppSettingsController(context: AccountContext) -> ViewController {
    let client = PaiClient()
    let statePromise = ValuePromise(WhatsAppSettingsState(), ignoreRepeated: true)
    let stateValue = Atomic(value: WhatsAppSettingsState())
    let updateState: ((inout WhatsAppSettingsState) -> Void) -> Void = { f in
        statePromise.set(stateValue.modify { state in
            var state = state
            f(&state)
            return state
        })
    }
    var presentImpl: ((ViewController) -> Void)?
    var tasks: [Task<Void, Never>] = []
    /// While a code is shown the status is polled, so the screen says "linked" the moment WhatsApp accepts it.
    var polling: Task<Void, Never>?

    let run: (@escaping () async throws -> Void) -> Void = { work in
        updateState { $0.isBusy = true; $0.error = nil }
        tasks.append(Task { @MainActor in
            do {
                try await work()
            } catch {
                updateState { $0.error = error.localizedDescription }
            }
            updateState { $0.isBusy = false }
        })
    }
    let load: () async throws -> WhatsAppStatus = {
        let status = try await client.call(WhatsAppStatus.self, "/whatsapp/status")
        await MainActor.run {
            updateState { state in
                state.status = status
                if state.phone.isEmpty, let me = status.me {
                    state.phone = "+\(me)"
                }
                if status.linked {
                    state.code = nil
                }
            }
        }
        return status
    }

    let arguments = WhatsAppSettingsArguments(updatePhone: { phone in
        updateState { $0.phone = phone }
    }, requestCode: {
        let phone = stateValue.with { $0.phone }
        run {
            let code = try await client.call(PairingCode.self, "/whatsapp/pair", method: "POST", body: ["phone": phone]).code
            updateState { $0.code = code }
            polling?.cancel()
            polling = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if let status = try? await load(), status.linked {
                        context.engine.whatsApp.reloadChats()
                        return
                    }
                }
            }
        }
    }, copyCode: {
        UIPasteboard.general.string = stateValue.with { $0.code }
    }, openWhatsApp: {
        if let url = URL(string: "whatsapp://") {
            UIApplication.shared.open(url)
        }
    }, setNotify: { on in
        run {
            let status = try await client.call(WhatsAppStatus.self, "/whatsapp/settings", method: "POST", body: ["notify": on])
            updateState { $0.status = status }
        }
    }, reloadChats: {
        context.engine.whatsApp.reloadChats()
    }, relink: {
        presentImpl?(textAlertController(context: context, title: "Link Again", text: "Unlink the box from WhatsApp and link it again? Its chats stay; you'll enter a new code on your phone.", actions: [
            TextAlertAction(type: .genericAction, title: "Cancel", action: {}),
            TextAlertAction(type: .destructiveAction, title: "Link Again", action: {
                run {
                    _ = try await client.call(Relinking.self, "/whatsapp/relink", method: "POST", body: [:])
                    _ = try await load()
                }
            })
        ]))
    })

    run {
        _ = try await load()
    }

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("WhatsApp"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: whatsAppSettingsEntries(state), style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        tasks.forEach { $0.cancel() }
        polling?.cancel()
    }

    let controller = ItemListController(context: context, state: signal)
    presentImpl = { [weak controller] alert in
        controller?.present(alert, in: .window(.root))
    }
    return controller
}
