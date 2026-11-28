import CryptoKit
import Foundation
import Security
import SwiftUI
import UserNotifications
import WatchKit

/// This watch's approval key. watchOS has no passkeys, so the watch signs pai's change approvals with a P-256 key made
/// in its own Secure Enclave: it never leaves the watch and signs only while the watch is unlocked with a passcode.
/// The phone adds its public key to pai (Paigram › Settings › Passkey › Add Apple Watch, vouched by the phone's
/// passkey); pai then takes this key's signature for ordinary change cards, never for anything else.
enum PaiWatchKey {
    private static let service = "pai.watchkey"
    private static let account = "signing"
    static let addHint = "Add this watch first: on iPhone, Paigram › Settings › Passkey › Add Apple Watch."

    enum KeyError: LocalizedError {
        case unavailable
        case unreadable

        var errorDescription: String? {
            switch self {
            case .unavailable: return "This watch can't make a secure key: set a passcode first."
            case .unreadable: return "This watch's key can't be used now: unlock the watch."
            }
        }
    }

    /// The key, made on first use. A stored key that will not load is never replaced (that would drop the one pai knows).
    static func key() throws -> SecureEnclave.P256.Signing.PrivateKey {
        if let blob = read() {
            guard let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob) else { throw KeyError.unreadable }
            return key
        }
        guard SecureEnclave.isAvailable,
              let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .privateKeyUsage, nil)
        else { throw KeyError.unavailable }
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        write(key.dataRepresentation)
        return key
    }

    /// The public key as pai takes it: SPKI DER, base64url.
    static func publicKey() throws -> String {
        base64url(try key().publicKey.derRepresentation)
    }

    /// pai's id for a public key: the first 16 bytes of SHA-256 of its base64url text, base64url.
    static func id(of publicKey: String) -> String {
        base64url(Data(SHA256.hash(data: Data(publicKey.utf8)).prefix(16)))
    }

    /// The signature (DER, base64url) over exactly what pai checks for change `hash` and its challenge.
    static func sign(hash: String, challenge: String) throws -> String {
        let message = Data("pai-watch-approve-change\n\(hash)\n\(challenge)".utf8)
        return base64url(try key().signature(for: message).derRepresentation)
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func read() -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// The Secure Enclave's wrapped key (useless off this watch), kept on this device only.
    private static func write(_ data: Data) {
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemDelete(query as CFDictionary)
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// A sensitive change an agent asks to make: where, why and what it does, approved with this watch's key or denied.
/// A root script or a datovka send says to approve it on the iPhone: pai takes only a passkey for those.
struct PaiChangeView: View {
    /// Who asks, from the glance's need; nil when a notification opened it (the change's agent stands in).
    let from: String?
    let hash: String
    @State private var pai = PaiWatch.shared
    @State private var change: PaiGlance.Change?
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss

    private var busy: Bool { pai.answering.contains("change:\(hash)") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if let who = from ?? change?.agent { Text(who).font(.footnote.weight(.semibold)).foregroundStyle(.orange) }
                if let change {
                    if let site = change.site { Text(site).font(.headline) }
                    if let reason = change.reason, !reason.isEmpty { Text(reason).font(.footnote) }
                    ForEach(Array(change.lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    if change.isPending {
                        if change.needsPasskey {
                            Text("Approve this one with your passkey on iPhone.").font(.footnote).foregroundStyle(.orange)
                        } else {
                            Button { decide(approve: true) } label: { Label("Approve", systemImage: "checkmark.seal.fill") }
                                .tint(.green)
                                .disabled(busy)
                        }
                        Button(role: .destructive) { decide(approve: false) } label: { Label("Deny", systemImage: "xmark") }
                            .disabled(busy)
                    } else {
                        Text(change.status.capitalized).font(.footnote).foregroundStyle(.secondary)
                    }
                } else if message == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }
                if busy { ProgressView().frame(maxWidth: .infinity) }
                if let message = message ?? pai.changeFailure[hash] { Text(message).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Approve")
        .task { load() }
        // An Approve from the notification signs while this screen shows; read the card again once it is done.
        .onChange(of: busy) { _, now in
            if !now { load() }
        }
    }

    private func load() {
        pai.change(hash) { result in
            switch result {
            case let .success(change): self.change = change
            case .failure: message = "Can't reach pai"
            }
        }
    }

    private func decide(approve: Bool) {
        message = nil
        pai.decideChange(hash: hash, approve: approve) { error in
            if let error { message = error } else { dismiss() }
        }
    }
}

/// The long look of a `pai.change` push on the wrist: what the change does and its own Approve / Deny, which sign here with
/// this watch's key (a notification forwarded from the iPhone does not reliably hand its action buttons to this app).
final class PaiChangeNotificationController: WKUserNotificationHostingController<PaiChangeNotificationView> {
    private var title = ""
    private var text = ""
    private var changeHash: String?

    override class var isInteractive: Bool { true }

    override var body: PaiChangeNotificationView {
        PaiChangeNotificationView(title: title, text: text, hash: changeHash)
    }

    override func didReceive(_ notification: UNNotification) {
        let content = notification.request.content
        title = content.title
        text = content.body
        changeHash = PaiWatch.changeHash(content.userInfo)
        // The view's own buttons sign in this process; the category's would go wherever watchOS sends them.
        if changeHash != nil { notificationActions = [] }
    }
}

struct PaiChangeNotificationView: View {
    let title: String
    let text: String
    let hash: String?
    @State private var pai = PaiWatch.shared
    @State private var change: PaiGlance.Change?
    @State private var message: String?
    @State private var done: String?

    private var busy: Bool { hash.map { pai.answering.contains("change:\($0)") } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if let change {
                if let site = change.site { Text(site).font(.footnote.weight(.semibold)) }
                if let reason = change.reason, !reason.isEmpty { Text(reason).font(.footnote) }
                ForEach(Array(change.lines.prefix(6).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                }
            } else {
                Text(text).font(.footnote)
            }
            if let done {
                Label(done, systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green)
            } else if let hash, change?.isPending ?? true {
                if change?.needsPasskey == true {
                    Text("Approve this one with your passkey on iPhone.").font(.footnote).foregroundStyle(.orange)
                } else {
                    Button { decide(hash, approve: true) } label: { Label("Approve", systemImage: "checkmark.seal.fill") }
                        .tint(.green)
                        .disabled(busy)
                }
                Button(role: .destructive) { decide(hash, approve: false) } label: { Label("Deny", systemImage: "xmark") }
                    .disabled(busy)
            } else if let change {
                Text(change.status.capitalized).font(.footnote).foregroundStyle(.secondary)
            }
            if busy { ProgressView().frame(maxWidth: .infinity) }
            if let message { Text(message).font(.footnote).foregroundStyle(.red) }
        }
        .task {
            guard let hash else { return }
            pai.change(hash) { if case let .success(change) = $0 { self.change = change } }
        }
    }

    private func decide(_ hash: String, approve: Bool) {
        message = nil
        pai.decideChange(hash: hash, approve: approve) { error in
            if let error { message = error } else { done = approve ? "Approved" : "Denied" }
        }
    }
}
