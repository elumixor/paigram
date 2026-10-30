import AccountContext
import Foundation
import SwiftSignalKit
import SwiftUI
import TelegramCore
import UIKit

/// Settings › Email: the mailboxes the box reads (named and coloured as in Spark), and a chat with a new address.
public final class EmailSettingsController: PaiHostedController {
    public init(context: AccountContext, openChat: @escaping (EnginePeer.Id) -> Void) {
        super.init(context: context)
        let model = EmailSettingsModel(engine: context.engine)
        self.host(EmailSettingsView(model: model, close: { [weak self] in
            self?.dismiss()
        }, openChat: { [weak self] peerId in
            self?.dismiss()
            openChat(peerId)
        }))
    }
    
    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class EmailSettingsModel: ObservableObject {
    @Published var address = ""
    @Published var name = ""
    @Published private(set) var isOpening = false
    @Published private(set) var error: String?
    private let engine: TelegramEngine
    private let disposable = MetaDisposable()
    
    init(engine: TelegramEngine) {
        self.engine = engine
    }
    
    deinit {
        self.disposable.dispose()
    }
    
    var canOpen: Bool {
        let trimmed = self.address.trimmingCharacters(in: .whitespaces)
        return !self.isOpening && trimmed.contains("@") && trimmed.contains(".")
    }
    
    func open(_ completion: @escaping (EnginePeer.Id) -> Void) {
        self.isOpening = true
        self.error = nil
        let address = self.address.trimmingCharacters(in: .whitespaces).lowercased()
        self.disposable.set((self.engine.email.openChat(address: address, name: self.name.trimmingCharacters(in: .whitespaces))
        |> deliverOnMainQueue).start(next: { peerId in
            completion(peerId)
        }, error: { [weak self] error in
            self?.isOpening = false
            self?.error = error.description
        }))
    }
}

/// `#rrggbb` as Spark keeps it.
private func color(hex: String) -> Color {
    let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x888888
    return Color(red: Double((value >> 16) & 0xff) / 255.0, green: Double((value >> 8) & 0xff) / 255.0, blue: Double(value & 0xff) / 255.0)
}

struct EmailSettingsView: View {
    @ObservedObject var model: EmailSettingsModel
    let close: () -> Void
    let openChat: (EnginePeer.Id) -> Void
    
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Mailboxes"), footer: Text("\(EmailChats.chatCount) email chats. New mail arrives as a message from its sender; what you send goes out as an email from the mailbox its thread is in.")) {
                    ForEach(EmailChats.accounts, id: \.label) { account in
                        HStack(spacing: 12) {
                            Circle().fill(color(hex: account.color)).frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.title.isEmpty ? account.label : account.title)
                                Text(account.email).font(.footnote).foregroundColor(.secondary)
                            }
                        }
                    }
                }
                Section(header: Text("New email"), footer: Text(self.model.error ?? "Opens a chat with the address; your first message becomes the email, its first line the subject.")) {
                    TextField("Address", text: self.$model.address)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    TextField("Name (optional)", text: self.$model.name)
                    Button(self.model.isOpening ? "Opening…" : "Open chat") {
                        self.model.open(self.openChat)
                    }
                    .disabled(!self.model.canOpen)
                }
            }
            .navigationTitle("Email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: self.close)
                }
            }
        }
    }
}
