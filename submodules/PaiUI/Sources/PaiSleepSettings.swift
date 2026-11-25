import Foundation
import PaiSleep
import SwiftUI
import UIKit

/// Starts the sleep upload at launch with the box's auth (`PaiSleepMonitor`).
public enum PaiSleepSharing {
    public static func start() {
        guard #available(iOS 16.0, *) else { return }
        let client = PaiClient()
        PaiSleepMonitor.shared.start(
            transport: { path, body in try await client.send(path, method: "POST", body: body) },
            isSignedIn: { PaiAuth.token != nil }
        )
    }
}

/// Settings' "Sleep" section: the toggle that sends each night from Health to Balance.
@available(iOS 16.0, *)
struct PaiSleepSection: View {
    @ObservedObject var monitor = PaiSleepMonitor.shared

    var body: some View {
        if monitor.isAvailable {
            Section {
                Toggle(isOn: Binding(get: { monitor.isEnabled }, set: { monitor.setEnabled($0) })) {
                    SettingsRow(symbol: "bed.double.fill", color: .indigo, title: "Share sleep with Balance")
                }
            } header: {
                Text("Sleep")
            } footer: {
                Text(footer)
            }
        }
    }

    private var footer: String {
        let base = "Sends each night's sleep from Health to pai, which puts it on your Balance calendar."
        guard monitor.isEnabled else { return base }
        if let error = monitor.lastError { return base + " " + error + "." }
        guard let night = monitor.lastNight else { return base + " If no nights arrive, allow Sleep for Paigram in Health ▸ Sharing ▸ Apps." }
        return base + " Last night sent: " + night.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + "."
    }
}
