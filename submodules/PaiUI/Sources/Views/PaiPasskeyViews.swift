import AccountContext
import Display
import Foundation
import PaiPasskeyCore
import SwiftUI
import UIKit

/// Settings' passkey rows: add one bound to this phone, then open or close pai's unlock window with it.
@available(iOS 16.0, *)
final class PaiPasskeyModel: ObservableObject {
    @Published private(set) var enrolled = PaiPasskeys.enrolledCredential != nil
    @Published private(set) var state: PaiUnlockState?
    @Published private(set) var busy = false
    /// pai holds a watch key for this phone.
    @Published private(set) var watchAdded = false
    /// The enrol found this phone already holds one of pai's passkeys.
    var alreadySaved: Bool { PaiPasskeys.enrolledCredential == PaiPasskeys.alreadySaved }
    @Published var error: String?
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: PaiPasskeys.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.enrolled = PaiPasskeys.enrolledCredential != nil
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    @MainActor func load() async {
        state = try? await PaiPasskeys.state()
        if let keys = try? await PaiPasskeys.watchKeys() { watchAdded = !keys.isEmpty }
    }

    @MainActor func addWatch() async {
        await run { try await PaiPasskeys.addWatch() }
        await load()
    }

    @MainActor func enrol(invite: String?) async {
        await run { try await PaiPasskeys.enrol(invite: invite) }
        await load()
    }

    @MainActor func finish(_ prepared: PaiPasskeys.PreparedEnrol) async {
        await run { try await PaiPasskeys.finish(prepared) }
        await load()
    }

    @MainActor func unlock(minutes: Int) async {
        await run { self.state = try await PaiPasskeys.unlock(minutes: minutes) }
    }

    @MainActor func lock() async {
        await run { self.state = try await PaiPasskeys.lock() }
    }

    @MainActor private func run(_ body: @escaping () async throws -> Void) async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await body()
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
        enrolled = PaiPasskeys.enrolledCredential != nil
    }
}

@available(iOS 16.0, *)
struct PaiPasskeySection: View {
    @StateObject private var model = PaiPasskeyModel()

    private static let windows: [(String, Int)] = [("15 minutes", 15), ("1 hour", 60), ("4 hours", 240)]

    var body: some View {
        Section {
            if model.enrolled {
                SettingsRow(symbol: "person.badge.key.fill", color: .blue, title: "Passkey", value: model.alreadySaved ? "Saved on this iPhone" : "Added")
                if let until = model.state?.untilDate, model.state?.unlocked == true {
                    SettingsRow(symbol: "lock.open.fill", color: .orange, title: "Unlocked", value: "until \(until.formatted(date: .omitted, time: .shortened))")
                    Button("Lock now") { Task { await model.lock() } }.disabled(model.busy)
                } else {
                    Menu {
                        ForEach(Self.windows, id: \.1) { window in
                            Button(window.0) { Task { await model.unlock(minutes: window.1) } }
                        }
                    } label: {
                        SettingsRow(symbol: "lock.fill", color: .orange, title: "Unlock", value: nil)
                    }
                    .disabled(model.busy)
                }
                if PaiGlanceSync.shared.watchAvailable || model.watchAdded {
                    Button { Task { await model.addWatch() } } label: {
                        SettingsRow(symbol: "applewatch", color: .green, title: model.watchAdded ? "Apple Watch" : "Add Apple Watch", value: model.watchAdded ? "Added" : nil)
                    }
                    .disabled(model.busy)
                }
            } else {
                Menu {
                    Button("Add passkey") { Task { await model.enrol(invite: nil) } }
                    Button("Scan code from Mac") { PaiInviteScannerPresenter.present(model: model) }
                } label: {
                    SettingsRow(symbol: "person.badge.key.fill", color: .blue, title: "Add passkey", value: nil)
                }
                .disabled(model.busy)
            }
        } header: {
            Text("Passkey")
        } footer: {
            if let error = model.error {
                Text(error).foregroundStyle(.red)
            } else if model.enrolled, !model.watchAdded, PaiGlanceSync.shared.watchAvailable {
                Text("Add Apple Watch lets the watch approve pai's change cards with its own key, after Face ID here.")
            } else if !model.enrolled {
                Text("A passkey on this phone unlocks pai and approves its changes. First passkey on Mac? Open pai on Mac › Settings › Account › Add another device, then Scan code from Mac here.")
            }
        }
        .task { await model.load() }
    }
}

/// Shows the scanner as a plain UIKit modal on the topmost controller. SwiftUI's `.sheet` + `dismiss` from inside
/// Telegram's controller tree never closed it (only a swipe did), so Add passkey and Cancel looked dead; here every
/// button dismisses the host itself.
@available(iOS 16.0, *)
enum PaiInviteScannerPresenter {
    private final class WeakHost {
        weak var controller: UIViewController?
    }

    @MainActor static func present(model: PaiPasskeyModel) {
        guard let top = topController() else { return }
        let box = WeakHost()
        let view = PaiInviteScannerView(
            close: { box.controller?.dismiss(animated: true) },
            add: { prepared in
                let enrol = { Task { await model.finish(prepared) } }
                if let host = box.controller {
                    host.dismiss(animated: true) { _ = enrol() }
                } else {
                    _ = enrol()
                }
            }
        )
        let host = UIHostingController(rootView: view)
        host.modalPresentationStyle = .pageSheet
        box.controller = host
        top.present(host, animated: true)
    }

    private static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

// MARK: Change approval

/// A change an agent asks to make (from its push or a `paigram://change/<hash>` link), approved with this phone's
/// passkey or denied with its token.
@available(iOS 16.0, *)
public func paiChangeController(context: AccountContext, hash: String) -> ViewController {
    PaiChangeController(context: context, hash: hash)
}

@available(iOS 16.0, *)
final class PaiChangeController: PaiHostedController {
    init(context: AccountContext, hash: String) {
        super.init(context: context)
        let close: () -> Void = { [weak self] in self?.dismiss() }
        self.host(PaiChangeView(model: PaiChangeModel(hash: hash), close: close))
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@available(iOS 16.0, *)
final class PaiChangeModel: ObservableObject {
    let hash: String
    @Published private(set) var change: PaiChange?
    @Published private(set) var busy = false
    /// pai holds a watch key for this phone.
    @Published private(set) var watchAdded = false
    @Published private(set) var error: String?

    init(hash: String) {
        self.hash = hash
    }

    @MainActor func load() async {
        do {
            change = try await PaiPasskeys.change(hash)
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor func decide(approve: Bool) async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            if approve { try await PaiPasskeys.approve(hash) } else { try await PaiPasskeys.deny(hash) }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
        await load()
    }
}

@available(iOS 16.0, *)
struct PaiChangeView: View {
    @StateObject var model: PaiChangeModel
    let close: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if let change = model.change {
                    Section {
                        if let agent = change.agent { row("Agent", agent) }
                        if let site = change.site ?? change.page?.host { row("Site", site) }
                        if let summary = Self.summary(change) { row("Change", summary) }
                        row("Status", change.status.capitalized)
                        if let expires = change.expires, change.isPending {
                            row("Expires", Date(timeIntervalSince1970: expires / 1000).formatted(date: .omitted, time: .shortened))
                        }
                    } footer: {
                        if let reason = change.reason { Text(reason) }
                    }
                    let details = Self.details(change)
                    if !details.isEmpty {
                        Section("Details") {
                            ForEach(details, id: \.title) { detail in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(detail.title).font(.footnote).foregroundStyle(.secondary)
                                    ScrollView(.vertical) {
                                        Text(detail.text)
                                            .font(.system(.footnote, design: .monospaced))
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .frame(maxHeight: 280)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    if change.isPending {
                        Section {
                            Button { Task { await model.decide(approve: true) } } label: {
                                Label("Approve with passkey", systemImage: "person.badge.key.fill")
                            }
                            Button(role: .destructive) { Task { await model.decide(approve: false) } } label: { Text("Deny") }
                        }
                        .disabled(model.busy)
                    }
                } else if model.error == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }
                if let error = model.error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Change")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(action: close) { Image(systemName: "chevron.left") } }
            }
            .refreshable { await model.load() }
        }
        .task { await model.load() }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 16)
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }

    /// Everything the passkey signs off on, so approving is never blind: the op's arguments, or the page edit.
    static func details(_ change: PaiChange) -> [(title: String, text: String)] {
        let values: [(String, JSONValue?)] = [
            ("Arguments", change.op?.args),
            ("Page changes", change.page?.changes),
            ("Click target", change.page?.clickTarget),
            ("Before", change.page?.before)
        ]
        return values.compactMap { title, value in
            value.flatMap { PaiChangeFormat.text($0) }.map { (title, $0) }
        }
    }

    static func summary(_ change: PaiChange) -> String? {
        if let op = change.op {
            return [op.connector, op.op].compactMap { $0 }.joined(separator: " · ")
        }
        if let page = change.page {
            return [page.host, page.path].compactMap { $0 }.joined()
        }
        return nil
    }
}
