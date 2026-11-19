import CoreLocation
import Foundation
import PaiPlaces
import SwiftUI
import UIKit

/// Starts the place fences at launch with the box's auth (`PaiPlacesMonitor`).
public enum PaiPlaceReminders {
    public static func start() {
        guard #available(iOS 16.0, *) else { return }
        let client = PaiClient()
        PaiPlacesMonitor.shared.start(transport: { request in
            try await client.send(request.path, method: request.method, body: request.body)
        })
    }
}

/// Settings' "Place reminders" section: the toggle, and what keeps it from working when location access falls short.
@available(iOS 16.0, *)
struct PaiPlacesSection: View {
    @ObservedObject var monitor = PaiPlacesMonitor.shared

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { monitor.isEnabled }, set: { monitor.setEnabled($0) })) {
                SettingsRow(symbol: "mappin.and.ellipse", color: .orange, title: "Tell pai where I am")
            }
            if monitor.isEnabled, needsSettings {
                Button("Allow location access in Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        } header: {
            Text("Place reminders")
        } footer: {
            Text(footer)
        }
    }

    private var needsSettings: Bool {
        monitor.authorization == .denied || monitor.authorization == .restricted || monitor.authorization == .authorizedWhenInUse
    }

    private var footer: String {
        let base = "Tells pai when you arrive at or leave your saved places, like the office, so it can remind you of tasks there."
        guard monitor.isEnabled else { return base }
        switch monitor.authorization {
        case .denied, .restricted: return base + " Location access is off for Paigram."
        case .authorizedWhenInUse: return base + " Set location access to Always so arrivals register while Paigram is closed."
        default:
            if let error = monitor.lastError { return base + " " + error + "." }
            return base + " Watching \(monitor.monitoredCount) place\(monitor.monitoredCount == 1 ? "" : "s")."
        }
    }
}
