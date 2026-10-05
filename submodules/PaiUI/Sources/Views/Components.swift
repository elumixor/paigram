import SwiftUI

/// One round bar button, filled when it is the main action.
@available(iOS 16.0, *)
struct BarButton: View {
    let symbol: String
    var filled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(filled ? Color.white : Color.accentColor)
                .frame(width: 40, height: 40)
                .background(filled ? Color.accentColor : Color(.secondarySystemBackground), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

@available(iOS 16.0, *)
struct ContentUnavailableCompat: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
        .listRowSeparator(.hidden)
    }
}

@available(iOS 16.0, *)
struct SkeletonRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 4).fill(Color(.tertiarySystemFill)).frame(width: 180, height: 14)
            RoundedRectangle(cornerRadius: 4).fill(Color(.tertiarySystemFill)).frame(width: 260, height: 11)
        }
        .padding(.vertical, 6)
        .modifier(Breathing())
        .listRowSeparator(.hidden)
    }
}
