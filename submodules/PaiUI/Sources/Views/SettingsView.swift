import SwiftUI

/// Where the box is, the token that opens it, and which language to listen for.
@available(iOS 16.0, *)
struct SettingsView: View {
    @EnvironmentObject private var settings: PaiSettings
    @EnvironmentObject private var store: PaiStore
    @Environment(\.dismiss) private var dismiss
    @State private var check: String?
    @State private var checking = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("https://pai.example.com", text: $settings.baseURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Token", text: $settings.token)
                    Button {
                        checkConnection()
                    } label: {
                        HStack {
                            Text("Check connection")
                            Spacer()
                            if checking { ProgressView() } else if let check { Text(check).font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                }
                Section("Dictation language") {
                    Picker("Language", selection: $settings.speechLocale) {
                        ForEach(PaiSettings.speechLocales, id: \.self) { id in
                            Text(Locale.current.localizedString(forIdentifier: id) ?? id).tag(id)
                        }
                    }
                    .pickerStyle(.inline).labelsHidden()
                }
            }
            .navigationTitle("Pai settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func checkConnection() {
        checking = true
        check = nil
        Task {
            defer { checking = false }
            do { check = "OK · \(try await store.client.health())" } catch { check = error.localizedDescription }
        }
    }
}
