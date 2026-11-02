import AccountContext
import Foundation
import SwiftUI
import TelegramCore
import UIKit

/// Settings › WhatsApp: whether the box is linked to his WhatsApp, linking it from this phone with a code (a QR
/// shown on the phone that has to scan it is no use), linking again, the box's pushes, and reloading the chats.
@available(iOS 16.0, *)
public final class WhatsAppSettingsController: PaiHostedController {
    public override init(context: AccountContext) {
        super.init(context: context)
        let model = WhatsAppSettingsModel(engine: context.engine)
        self.host(WhatsAppSettingsView(model: model, close: { [weak self] in
            self?.dismiss()
        }))
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// The box's WhatsApp connection as `/whatsapp/status` reports it.
struct WhatsAppStatus: Decodable {
    struct Seen: Decodable {
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

@available(iOS 16.0, *)
@MainActor
final class WhatsAppSettingsModel: ObservableObject {
    @Published private(set) var status: WhatsAppStatus?
    @Published var phone = ""
    @Published private(set) var code: String?
    @Published private(set) var isBusy = false
    @Published private(set) var error: String?
    private let engine: TelegramEngine
    private let client = PaiClient()
    /// While a code is shown the status is polled, so the screen says "linked" the moment WhatsApp accepts it.
    private var polling: Task<Void, Never>?
    private static let pollInterval: UInt64 = 3_000_000_000

    init(engine: TelegramEngine) {
        self.engine = engine
    }

    deinit {
        self.polling?.cancel()
    }

    func load() async {
        await self.run {
            let status = try await self.client.call(WhatsAppStatus.self, "/whatsapp/status")
            self.status = status
            if self.phone.isEmpty, let me = status.me {
                self.phone = "+\(me)"
            }
            if status.linked {
                self.code = nil
            }
        }
    }

    func requestCode() async {
        await self.run {
            self.code = try await self.client.call(PairingCode.self, "/whatsapp/pair", method: "POST", body: ["phone": self.phone]).code
            self.startPolling()
        }
    }

    func relink() async {
        await self.run {
            _ = try await self.client.call(Relinking.self, "/whatsapp/relink", method: "POST", body: [:])
        }
        await self.load()
    }

    func setNotify(_ on: Bool) async {
        await self.run {
            self.status = try await self.client.call(WhatsAppStatus.self, "/whatsapp/settings", method: "POST", body: ["notify": on])
        }
    }

    func reloadChats() {
        self.engine.whatsApp.reloadChats()
    }

    private func startPolling() {
        self.polling?.cancel()
        self.polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: WhatsAppSettingsModel.pollInterval)
                guard let self else {
                    return
                }
                await self.load()
                if self.status?.linked == true {
                    self.reloadChats()
                    return
                }
            }
        }
    }

    private func run(_ work: () async throws -> Void) async {
        self.isBusy = true
        self.error = nil
        do {
            try await work()
        } catch {
            self.error = error.localizedDescription
        }
        self.isBusy = false
    }
}

@available(iOS 16.0, *)
struct WhatsAppSettingsView: View {
    @ObservedObject var model: WhatsAppSettingsModel
    let close: () -> Void
    @State private var confirmingRelink = false

    private var statusLine: String {
        guard let status = self.model.status else {
            return "Checking…"
        }
        if status.linked, let me = status.me {
            return "Linked as \(status.name.map { "\($0), " } ?? "")+\(me)"
        }
        return status.state == "linking" ? "Not linked: waiting for a phone" : "Not linked (\(status.state))"
    }

    var body: some View {
        NavigationView {
            List {
                Section(footer: Text(self.model.status?.cached.map { "The box has seen \($0.chats) chats and \($0.messages) messages. Older messages come from your phone as you scroll up in a chat." } ?? "")) {
                    Text(self.statusLine)
                    if let error = self.model.status?.error, self.model.status?.linked == false {
                        Text(error).font(.footnote).foregroundColor(.secondary)
                    }
                }
                if self.model.status?.linked == false {
                    self.linkSection
                }
                Section(footer: Text("WhatsApp's own app notifies too: turn one of them off.")) {
                    Toggle("Notify about new messages", isOn: Binding(get: { self.model.status?.notify ?? true }, set: { on in
                        Task { await self.model.setNotify(on) }
                    }))
                    .disabled(self.model.status == nil)
                }
                Section(footer: Text(self.model.error ?? "")) {
                    Button("Reload all chats") {
                        self.model.reloadChats()
                    }
                    if self.model.status?.linked == true {
                        Button("Link again", role: .destructive) {
                            self.confirmingRelink = true
                        }
                    }
                }
            }
            .navigationTitle("WhatsApp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: self.close)
                }
            }
            .confirmationDialog("Unlink the box from WhatsApp and link it again? Its chats stay; you'll enter a new code on your phone.", isPresented: self.$confirmingRelink, titleVisibility: .visible) {
                Button("Link again", role: .destructive) {
                    Task { await self.model.relink() }
                }
            }
            .task {
                await self.model.load()
            }
        }
    }

    @ViewBuilder
    private var linkSection: some View {
        Section(header: Text("Link this phone"), footer: Text("In WhatsApp: Settings › Linked devices › Link a device › Link with phone number instead, then type the code.")) {
            TextField("Your WhatsApp number", text: self.$model.phone)
                .keyboardType(.phonePad)
            if let code = self.model.code {
                HStack {
                    Text(code)
                        .font(.system(size: 28, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy") {
                        UIPasteboard.general.string = code
                    }
                }
                Button("Open WhatsApp") {
                    if let url = URL(string: "whatsapp://") {
                        UIApplication.shared.open(url)
                    }
                }
            }
            Button(self.model.isBusy ? "Asking WhatsApp…" : (self.model.code == nil ? "Get a code" : "Get a new code")) {
                Task { await self.model.requestCode() }
            }
            .disabled(self.model.isBusy || self.model.phone.filter(\.isNumber).count < 8)
        }
    }
}
