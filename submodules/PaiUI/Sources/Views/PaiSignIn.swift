import SwiftUI

/// Whether this phone is signed in to pai, for SwiftUI.
@available(iOS 16.0, *)
@MainActor
final class PaiAuthModel: ObservableObject {
    @Published private(set) var isSignedIn = PaiAuth.isSignedIn
    @Published private(set) var isSigningIn = false
    @Published var error: String?
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: PaiAuth.didChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.isSignedIn = PaiAuth.isSignedIn }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func signIn() async {
        isSigningIn = true
        error = nil
        defer { isSigningIn = false }
        do {
            try await PaiAuth.signIn()
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    func signOut() {
        PaiAuth.signOut()
    }
}

/// pai's screens show their content once the phone is signed in; until then, the way to sign in.
@available(iOS 16.0, *)
struct PaiSignInGate<Content: View>: View {
    @StateObject private var auth = PaiAuthModel()
    let close: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        if auth.isSignedIn {
            content()
        } else {
            NavigationStack {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "sparkle").font(.system(size: 48, weight: .medium)).foregroundStyle(Color.accentColor)
                    Text("Sign in to pai").font(.title2.weight(.semibold))
                    Text("Link this phone with your Desk account. It gets its own key, which you can revoke at any time.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button {
                        Task { await auth.signIn() }
                    } label: {
                        if auth.isSigningIn { ProgressView() } else { Text("Sign in").frame(minWidth: 160) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(auth.isSigningIn)
                    if let error = auth.error {
                        Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal, 32)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button(action: close) { Image(systemName: "chevron.left") } }
                }
            }
        }
    }
}

/// The last section of pai's settings: unlink this phone.
@available(iOS 16.0, *)
struct PaiSignOutSection: View {
    @StateObject private var auth = PaiAuthModel()

    var body: some View {
        Section {
            Button(role: .destructive) { auth.signOut() } label: { Text("Sign out of pai") }
        } footer: {
            Text("Revokes this phone's key on the box.")
        }
    }
}
