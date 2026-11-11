import SwiftUI

/// Shared by the watch app and its complications.
enum PaiFormat {
    static func usd(_ value: Double) -> String {
        value >= 100 ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
    }

    /// Green under 50%, yellow under 80%, orange under 100%, red at the limit.
    static func tint(_ percent: Double) -> Color {
        switch percent {
        case ..<50: return .green
        case ..<80: return .yellow
        case ..<100: return .orange
        default: return .red
        }
    }
}
