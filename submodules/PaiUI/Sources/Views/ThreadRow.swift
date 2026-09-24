import SwiftUI

/// One thread, one line: its state, what it is about, and how long ago it moved.
@available(iOS 16.0, *)
struct ThreadRow: View {
    let session: PaiSession

    var body: some View {
        HStack(spacing: 10) {
            StateDot(session: session)
            Text(session.displayTitle.paiPlain).font(.callout).lineLimit(1)
            Spacer(minLength: 8)
            if session.isWaiting {
                Image(systemName: "questionmark.bubble").font(.footnote).foregroundStyle(Color.paiWaiting)
            }
            Text(session.lastActivityDate.paiAge).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
        }
    }
}
