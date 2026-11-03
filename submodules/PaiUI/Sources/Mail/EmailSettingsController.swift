import AccountContext
import Display
import Foundation
import ItemListUI
import PresentationDataUtils
import PromptUI
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import UIKit

/// Settings › Email: the mailboxes the box reads (renamed, recoloured, reconnected or removed here, and new ones
/// connected with Google's consent in a sheet), and a chat with a new address, from a chosen mailbox under a subject.

/// The colours a mailbox can take, as Spark offers them.
private let mailboxColors: [(name: String, hex: String)] = [
    ("Blue", "#3478f6"), ("Green", "#34c759"), ("Orange", "#ff9500"), ("Red", "#ff3b30"),
    ("Purple", "#af52de"), ("Pink", "#ff2d55"), ("Teal", "#30b0c7"), ("Gray", "#8e8e93")
]

private struct Removed: Decodable {
    let removed: String
}

private struct LooksUpdated: Decodable {
    let updated: [String]
}

private func mailboxTitle(_ account: EmailAccountData) -> String {
    return account.title.isEmpty ? account.label : account.title
}

/// What the box answers with; a failed load says why instead of leaving the screen waiting.
@available(iOS 16.0, *)
private func loadMailboxes(_ client: PaiClient) async throws -> [EmailAccountData] {
    return try await client.call([EmailAccountData].self, "/gmail/accounts")
}

/// Opens Google's consent for `label` in a sheet that closes itself once the box has the mailbox.
@MainActor
private func connectMailbox(label: String) async throws -> String {
    var components = URLComponents(string: PaiSecrets.baseURL)
    components?.path = "/gmail/connect"
    components?.queryItems = [URLQueryItem(name: "label", value: label), URLQueryItem(name: "app", value: "1")]
    guard let url = components?.url else {
        throw PaiClientError(message: "Server address is not a valid URL")
    }
    let callback = try await PaiWebSheet.run(url: url, callbackScheme: "paigram")
    let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
    guard callback.host == "pai-mailbox", let email = items.first(where: { $0.name == "email" })?.value else {
        throw PaiClientError(message: "The box did not connect the mailbox")
    }
    if let missing = items.first(where: { $0.name == "missing" })?.value {
        throw PaiClientError(message: "\(email) is connected, but Google did not allow pai to \(missing). Reconnect it and leave every box ticked.")
    }
    return email
}

private func alertError(_ context: AccountContext, _ text: String) -> ViewController {
    return textAlertController(context: context, title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: "OK", action: {})])
}

// MARK: - The list

private struct EmailSettingsState: Equatable {
    var signedIn = PaiAuth.isSignedIn
    var accounts: [EmailAccountData] = EmailChats.accounts
    var isLoading = true
    var loadError: String?
    var isConnecting = false
}

/// A short name as the box keys a mailbox by: lowercase, dashes for spaces, ASCII letters, digits and dashes.
private func mailboxLabel(_ text: String) -> String? {
    let label = text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "-")
    guard !label.isEmpty, label.count <= 40, label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }), label.unicodeScalars.allSatisfy(\.isASCII) else {
        return nil
    }
    return label
}

private final class EmailSettingsArguments {
    let signIn: () -> Void
    let retry: () -> Void
    let editMailbox: (EmailAccountData) -> Void
    let addMailbox: () -> Void
    let newEmail: () -> Void

    init(signIn: @escaping () -> Void, retry: @escaping () -> Void, editMailbox: @escaping (EmailAccountData) -> Void, addMailbox: @escaping () -> Void, newEmail: @escaping () -> Void) {
        self.signIn = signIn
        self.retry = retry
        self.editMailbox = editMailbox
        self.addMailbox = addMailbox
        self.newEmail = newEmail
    }
}

private enum EmailSettingsSection: Int32 {
    case signIn
    case mailboxes
    case actions
}

private enum EmailSettingsEntry: ItemListNodeEntry {
    case signIn
    case signInInfo
    case mailboxesHeader
    case mailbox(Int32, EmailAccountData)
    case loading(String)
    case retry
    case mailboxesInfo(String)
    case addMailbox(Bool, Bool)
    case newEmail(Bool)

    var section: ItemListSectionId {
        switch self {
        case .signIn, .signInInfo:
            return EmailSettingsSection.signIn.rawValue
        case .mailboxesHeader, .mailbox, .loading, .retry, .mailboxesInfo:
            return EmailSettingsSection.mailboxes.rawValue
        case .addMailbox, .newEmail:
            return EmailSettingsSection.actions.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .signIn: return 0
        case .signInInfo: return 1
        case .mailboxesHeader: return 10
        case let .mailbox(index, _): return 11 + index
        case .loading: return 90
        case .retry: return 91
        case .mailboxesInfo: return 99
        case .addMailbox: return 100
        case .newEmail: return 101
        }
    }

    static func <(lhs: EmailSettingsEntry, rhs: EmailSettingsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! EmailSettingsArguments
        switch self {
        case .signIn:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: "Sign In to pai", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: arguments.signIn)
        case .signInInfo:
            return ItemListTextItem(presentationData: presentationData, text: .plain("Mail comes through your pai box; this phone has to be signed in to it first."), sectionId: self.section)
        case .mailboxesHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "MAILBOXES", sectionId: self.section)
        case let .mailbox(_, account):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: mailboxIcon(hex: account.color), title: mailboxTitle(account), label: account.email, sectionId: self.section, style: .blocks, action: {
                arguments.editMailbox(account)
            })
        case let .loading(text):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: text, label: "", sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        case .retry:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: "Try Again", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: arguments.retry)
        case let .mailboxesInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .addMailbox(isConnecting, enabled):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: isConnecting ? "Connecting…" : "Add Mailbox…", kind: enabled ? .generic : .disabled, alignment: .natural, sectionId: self.section, style: .blocks, action: arguments.addMailbox)
        case let .newEmail(enabled):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: "New Email…", kind: enabled ? .generic : .disabled, alignment: .natural, sectionId: self.section, style: .blocks, action: arguments.newEmail)
        }
    }
}

/// The mailbox's colour (`#rrggbb`) as a dot in the row's icon slot.
private func mailboxIcon(hex: String) -> UIImage? {
    let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x888888
    return generateImage(CGSize(width: 30.0, height: 30.0), rotatedContext: { size, context in
        context.clear(CGRect(origin: CGPoint(), size: size))
        context.setFillColor(UIColor(rgb: value).cgColor)
        context.fillEllipse(in: CGRect(x: 9.0, y: 9.0, width: 12.0, height: 12.0))
    })
}

private func emailSettingsEntries(_ state: EmailSettingsState) -> [EmailSettingsEntry] {
    var entries: [EmailSettingsEntry] = []
    if !state.signedIn {
        entries += [.signIn, .signInInfo]
    }
    entries.append(.mailboxesHeader)
    entries += state.accounts.enumerated().map { .mailbox(Int32($0.offset), $0.element) }
    if let loadError = state.loadError {
        if state.accounts.isEmpty {
            entries.append(.loading("Couldn't load mailboxes"))
        }
        if state.signedIn {
            entries.append(.retry)
        }
        entries.append(.mailboxesInfo(loadError))
    } else if state.accounts.isEmpty {
        entries.append(.loading(state.isLoading ? "Loading…" : "No mailboxes yet"))
    } else {
        entries.append(.mailboxesInfo("\(EmailChats.chatCount) email chats. Tap a mailbox to rename, recolour, reconnect or remove it."))
    }
    entries += [.addMailbox(state.isConnecting, state.signedIn && !state.isConnecting), .newEmail(state.signedIn && !state.accounts.isEmpty)]
    return entries
}

@available(iOS 16.0, *)
public func emailSettingsController(context: AccountContext, openChat: @escaping (EnginePeer.Id) -> Void) -> ViewController {
    let client = PaiClient()
    let statePromise = ValuePromise(EmailSettingsState(), ignoreRepeated: true)
    let stateValue = Atomic(value: EmailSettingsState())
    let updateState: ((inout EmailSettingsState) -> Void) -> Void = { f in
        statePromise.set(stateValue.modify { state in
            var state = state
            f(&state)
            return state
        })
    }
    var tasks: [Task<Void, Never>] = []
    var presentImpl: ((ViewController) -> Void)?
    var pushImpl: ((ViewController) -> Void)?
    var authObserver: NSObjectProtocol?

    /// The mailboxes as the box has them now; a failure is said on the screen and in an alert, never as a spinner.
    let reload: (Bool) -> Void = { alertOnFailure in
        updateState { $0.signedIn = PaiAuth.isSignedIn; $0.isLoading = true; $0.loadError = nil }
        guard PaiAuth.isSignedIn else {
            updateState { $0.isLoading = false }
            return
        }
        tasks.append(Task { @MainActor in
            do {
                let accounts = try await loadMailboxes(client)
                updateState { $0.accounts = accounts; $0.isLoading = false }
                EmailChats.syncNow()
            } catch {
                updateState { $0.isLoading = false; $0.loadError = error.localizedDescription }
                if alertOnFailure {
                    presentImpl?(alertError(context, "Couldn't load your mailboxes: \(error.localizedDescription)"))
                }
            }
        })
    }

    let connect: (String) -> Void = { label in
        updateState { $0.isConnecting = true }
        tasks.append(Task { @MainActor in
            do {
                _ = try await connectMailbox(label: label)
            } catch is CancellationError {
            } catch {
                presentImpl?(alertError(context, error.localizedDescription))
            }
            updateState { $0.isConnecting = false }
            reload(false)
        })
    }

    let arguments = EmailSettingsArguments(signIn: {
        tasks.append(Task { @MainActor in
            do {
                try await PaiAuth.signIn()
            } catch is CancellationError {
            } catch {
                presentImpl?(alertError(context, error.localizedDescription))
            }
        })
    }, retry: {
        reload(true)
    }, editMailbox: { account in
        pushImpl?(mailboxEditController(context: context, client: client, account: account, changed: {
            reload(false)
        }))
    }, addMailbox: {
        presentImpl?(promptController(context: context, text: "Add Mailbox", subtitle: "Signs in to a Gmail or Google Workspace account and gives pai its mail. The short name is how pai refers to it.", value: nil, placeholder: "Short name, e.g. work", characterLimit: 40, apply: { text in
            guard let text else {
                return
            }
            guard let label = mailboxLabel(text) else {
                presentImpl?(alertError(context, "A short name takes letters, digits and dashes only."))
                return
            }
            if let existing = stateValue.with({ $0.accounts }).first(where: { $0.label == label }) {
                presentImpl?(textAlertController(context: context, title: "Reconnect \(mailboxTitle(existing))?", text: "\(label) is already \(existing.email). Sign in as that account to renew pai's access.", actions: [
                    TextAlertAction(type: .genericAction, title: "Cancel", action: {}),
                    TextAlertAction(type: .defaultAction, title: "Reconnect", action: { connect(label) })
                ]))
            } else {
                connect(label)
            }
        }))
    }, newEmail: {
        pushImpl?(newEmailController(context: context, accounts: stateValue.with { $0.accounts }, address: "", openChat: openChat))
    })

    reload(true)
    authObserver = NotificationCenter.default.addObserver(forName: PaiAuth.didChange, object: nil, queue: .main, using: { _ in
        reload(false)
    })

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("Email"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: emailSettingsEntries(state), style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        tasks.forEach { $0.cancel() }
        if let authObserver {
            NotificationCenter.default.removeObserver(authObserver)
        }
    }

    let controller = ItemListController(context: context, state: signal)
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    pushImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    return controller
}

// MARK: - A new email

private struct NewEmailState: Equatable {
    var accounts: [EmailAccountData]
    var address: String
    var name = ""
    var from: String?
    var subject = ""
    var isOpening = false
    var error: String?

    /// The mailbox a new email goes out from: the one picked, else the box's own default.
    var fromAccount: EmailAccountData? {
        return self.accounts.first(where: { $0.label == self.from }) ?? self.accounts.first(where: { $0.label == "personal" }) ?? self.accounts.first
    }

    var canOpen: Bool {
        let trimmed = self.address.trimmingCharacters(in: .whitespaces)
        return !self.isOpening && trimmed.contains("@") && trimmed.contains(".")
    }
}

private final class NewEmailArguments {
    let updateAddress: (String) -> Void
    let updateName: (String) -> Void
    let pickFrom: () -> Void
    let updateSubject: (String) -> Void
    let open: () -> Void

    init(updateAddress: @escaping (String) -> Void, updateName: @escaping (String) -> Void, pickFrom: @escaping () -> Void, updateSubject: @escaping (String) -> Void, open: @escaping () -> Void) {
        self.updateAddress = updateAddress
        self.updateName = updateName
        self.pickFrom = pickFrom
        self.updateSubject = updateSubject
        self.open = open
    }
}

private enum NewEmailEntry: ItemListNodeEntry {
    case address(String)
    case name(String)
    case from(String, Bool)
    case subject(String)
    case info(String?)

    var section: ItemListSectionId {
        return 0
    }

    var stableId: Int32 {
        switch self {
        case .address: return 0
        case .name: return 1
        case .from: return 2
        case .subject: return 3
        case .info: return 4
        }
    }

    static func <(lhs: NewEmailEntry, rhs: NewEmailEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! NewEmailArguments
        // The field's own title, in the list's text colour (a bare string draws black, unreadable in the dark theme).
        let title: (String) -> NSAttributedString = { text in
            NSAttributedString(string: text, font: Font.regular(presentationData.fontSize.itemListBaseFontSize), textColor: presentationData.theme.list.itemPrimaryTextColor)
        }
        switch self {
        case let .address(text):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: title("To"), text: text, placeholder: "Address", type: .email, sectionId: self.section, textUpdated: arguments.updateAddress, action: arguments.open)
        case let .name(text):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: title("Name"), text: text, placeholder: "Optional", sectionId: self.section, textUpdated: arguments.updateName, action: arguments.open)
        case let .from(text, enabled):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: "From", enabled: enabled, label: text, sectionId: self.section, style: .blocks, action: enabled ? arguments.pickFrom : nil)
        case let .subject(text):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: title("Subject"), text: text, placeholder: "Optional", sectionId: self.section, textUpdated: arguments.updateSubject, action: arguments.open)
        case let .info(error):
            return ItemListTextItem(presentationData: presentationData, text: .plain(error ?? "Opens a chat with the address; your first message becomes the email. Without a subject, its first line is the subject."), sectionId: self.section)
        }
    }
}

/// A chat with a new address, from a chosen mailbox under a subject. Also where a `mailto:` link lands.
@available(iOS 16.0, *)
public func newEmailController(context: AccountContext, accounts: [EmailAccountData], address: String, subject: String = "", openChat: @escaping (EnginePeer.Id) -> Void) -> ViewController {
    var initial = NewEmailState(accounts: accounts, address: address)
    initial.subject = subject
    let statePromise = ValuePromise(initial, ignoreRepeated: true)
    let stateValue = Atomic(value: initial)
    let updateState: ((inout NewEmailState) -> Void) -> Void = { f in
        statePromise.set(stateValue.modify { state in
            var state = state
            f(&state)
            return state
        })
    }
    let disposable = MetaDisposable()
    var presentImpl: ((ViewController) -> Void)?
    var replaceImpl: ((EnginePeer.Id) -> Void)?

    let arguments = NewEmailArguments(updateAddress: { address in
        updateState { $0.address = address }
    }, updateName: { name in
        updateState { $0.name = name }
    }, pickFrom: {
        let state = stateValue.with { $0 }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let sheet = ActionSheetController(presentationData: presentationData)
        let dismiss: () -> Void = { [weak sheet] in sheet?.dismissAnimated() }
        sheet.setItemGroups([
            ActionSheetItemGroup(items: state.accounts.map { account in
                ActionSheetButtonItem(title: "\(mailboxTitle(account)) · \(account.email)", color: .accent, action: {
                    dismiss()
                    updateState { $0.from = account.label }
                })
            }),
            ActionSheetItemGroup(items: [ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: dismiss)])
        ])
        presentImpl?(sheet)
    }, updateSubject: { subject in
        updateState { $0.subject = subject }
    }, open: {
        let state = stateValue.with { $0 }
        guard state.canOpen else {
            return
        }
        updateState { $0.isOpening = true; $0.error = nil }
        let address = state.address.trimmingCharacters(in: .whitespaces).lowercased()
        let subject = state.subject.trimmingCharacters(in: .whitespaces)
        disposable.set((context.engine.email.openChat(address: address, name: state.name.trimmingCharacters(in: .whitespaces), account: state.fromAccount?.label, subject: subject.isEmpty ? nil : subject)
        |> deliverOnMainQueue).start(next: { peerId in
            updateState { $0.isOpening = false }
            replaceImpl?(peerId)
        }, error: { error in
            updateState { $0.isOpening = false; $0.error = error.description }
        }))
    })

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let from = state.fromAccount.map { "\(mailboxTitle($0)) · \($0.email)" } ?? "—"
        let entries: [NewEmailEntry] = [.address(state.address), .name(state.name), .from(from, state.accounts.count > 1), .subject(state.subject), .info(state.error)]
        let open = ItemListNavigationButton(content: .text(state.isOpening ? "Opening…" : "Open"), style: .bold, enabled: state.canOpen, action: arguments.open)
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("New Email"), leftNavigationButton: nil, rightNavigationButton: open, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        disposable.dispose()
    }

    let controller = ItemListController(context: context, state: signal)
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    replaceImpl = { [weak controller] peerId in
        let _ = (controller?.navigationController as? NavigationController)?.popViewController(animated: false)
        openChat(peerId)
    }
    return controller
}

// MARK: - One mailbox

private struct MailboxEditState: Equatable {
    var title: String
    var color: String
    var isBusy = false
}

private final class MailboxEditArguments {
    let updateTitle: (String) -> Void
    let pickColor: (String) -> Void
    let reconnect: () -> Void
    let remove: () -> Void

    init(updateTitle: @escaping (String) -> Void, pickColor: @escaping (String) -> Void, reconnect: @escaping () -> Void, remove: @escaping () -> Void) {
        self.updateTitle = updateTitle
        self.pickColor = pickColor
        self.reconnect = reconnect
        self.remove = remove
    }
}

private enum MailboxEditSection: Int32 {
    case name
    case color
    case actions
}

private enum MailboxEditEntry: ItemListNodeEntry {
    case nameHeader
    case title(String, String)
    case nameInfo(String)
    case colorHeader
    case color(Int32, String, String, Bool)
    case reconnect
    case remove
    case actionsInfo(String)

    var section: ItemListSectionId {
        switch self {
        case .nameHeader, .title, .nameInfo:
            return MailboxEditSection.name.rawValue
        case .colorHeader, .color:
            return MailboxEditSection.color.rawValue
        case .reconnect, .remove, .actionsInfo:
            return MailboxEditSection.actions.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .nameHeader: return 0
        case .title: return 1
        case .nameInfo: return 2
        case .colorHeader: return 10
        case let .color(index, _, _, _): return 11 + index
        case .reconnect: return 100
        case .remove: return 101
        case .actionsInfo: return 102
        }
    }

    static func <(lhs: MailboxEditEntry, rhs: MailboxEditEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! MailboxEditArguments
        switch self {
        case .nameHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "NAME", sectionId: self.section)
        case let .title(text, placeholder):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: text, placeholder: placeholder, sectionId: self.section, textUpdated: arguments.updateTitle, action: {})
        case let .nameInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case .colorHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "COLOR", sectionId: self.section)
        case let .color(_, name, hex, checked):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, icon: mailboxIcon(hex: hex), title: name, style: .right, checked: checked, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.pickColor(hex)
            })
        case .reconnect:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: "Reconnect", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: arguments.reconnect)
        case .remove:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: "Remove Mailbox", kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: arguments.remove)
        case let .actionsInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

@available(iOS 16.0, *)
private func mailboxEditController(context: AccountContext, client: PaiClient, account: EmailAccountData, changed: @escaping () -> Void) -> ViewController {
    let initial = MailboxEditState(title: account.title, color: account.color.lowercased())
    let statePromise = ValuePromise(initial, ignoreRepeated: true)
    let stateValue = Atomic(value: initial)
    let updateState: ((inout MailboxEditState) -> Void) -> Void = { f in
        statePromise.set(stateValue.modify { state in
            var state = state
            f(&state)
            return state
        })
    }
    var tasks: [Task<Void, Never>] = []
    var presentImpl: ((ViewController) -> Void)?
    var popImpl: (() -> Void)?

    let save: (MailboxEditState) -> Void = { state in
        let title = state.title.trimmingCharacters(in: .whitespaces)
        tasks.append(Task { @MainActor in
            do {
                _ = try await client.call(LooksUpdated.self, "/gmail/accounts/look", method: "PUT", body: [["label": account.label, "title": title, "color": state.color]])
                changed()
            } catch {
                presentImpl?(alertError(context, "Couldn't save the mailbox: \(error.localizedDescription)"))
            }
        })
    }

    let arguments = MailboxEditArguments(updateTitle: { title in
        updateState { $0.title = title }
    }, pickColor: { hex in
        updateState { $0.color = hex }
        save(stateValue.with { $0 })
    }, reconnect: {
        tasks.append(Task { @MainActor in
            do {
                _ = try await connectMailbox(label: account.label)
                changed()
            } catch is CancellationError {
            } catch {
                presentImpl?(alertError(context, error.localizedDescription))
            }
        })
    }, remove: {
        presentImpl?(textAlertController(context: context, title: "Remove \(mailboxTitle(account))?", text: "pai stops reading and sending from \(account.email). Its email chats stay on this phone; the mail stays in Gmail.", actions: [
            TextAlertAction(type: .genericAction, title: "Cancel", action: {}),
            TextAlertAction(type: .destructiveAction, title: "Remove", action: {
                updateState { $0.isBusy = true }
                tasks.append(Task { @MainActor in
                    do {
                        _ = try await client.call(Removed.self, "/gmail/accounts", method: "DELETE", query: ["label": account.label])
                        changed()
                        popImpl?()
                    } catch {
                        updateState { $0.isBusy = false }
                        presentImpl?(alertError(context, "Couldn't remove the mailbox: \(error.localizedDescription)"))
                    }
                })
            })
        ]))
    })

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var entries: [MailboxEditEntry] = [.nameHeader, .title(state.title, account.label), .nameInfo("\(account.email) · called \(account.label) by pai"), .colorHeader]
        var colors = mailboxColors
        if !colors.contains(where: { $0.hex == state.color }), !state.color.isEmpty {
            colors.insert(("Current", state.color), at: 0)
        }
        entries += colors.enumerated().map { .color(Int32($0.offset), $0.element.name, $0.element.hex, $0.element.hex == state.color) }
        entries += [.reconnect, .remove, .actionsInfo("Reconnect when Google's access has run out or pai says the mailbox needs it.")]
        let done = ItemListNavigationButton(content: .text(presentationData.strings.Common_Done), style: .bold, enabled: !state.isBusy, action: {
            popImpl?()
        })
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(mailboxTitle(account)), leftNavigationButton: nil, rightNavigationButton: done, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        // Leaving, by Done or the back swipe, keeps a typed name; a colour is saved as it is picked.
        let state = stateValue.with { $0 }
        if state.title != initial.title, !state.isBusy {
            save(state)
        }
    }

    let controller = ItemListController(context: context, state: signal)
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    popImpl = { [weak controller] in
        let _ = (controller?.navigationController as? NavigationController)?.popViewController(animated: true)
    }
    return controller
}
