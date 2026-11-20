import SwiftUI

/// A message an agent drafted for the user to send as himself: read whole, edited (dictation, scribble or keyboard),
/// then sent or discarded from the wrist. A body the glance cut short is loaded whole before it can be edited.
struct PaiDraftView: View {
    let need: PaiGlance.Need
    let draft: PaiGlance.Need.Draft
    @State private var pai = PaiWatch.shared
    @State private var original: String?
    @State private var text = ""
    @State private var editing = false
    @State private var confirmingSend = false
    @State private var confirmingDiscard = false
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    private var busy: Bool { pai.answering.contains(need.id) }
    /// The whole body is known: the glance carried it uncut, or the box sent it.
    private var ready: Bool { original != nil }
    private var blank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(draft.to.map { "\(draft.label) to \($0)" } ?? draft.label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let subject = draft.subject {
                    Text(subject).font(.headline)
                }
                Text(ready ? text : draft.body)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if draft.awaitsRecipient {
                    Text("Pick the chat on your iPhone, then send.").font(.footnote).foregroundStyle(.secondary)
                }
                actions
                if let problem {
                    Text(problem).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(need.from)
        .task(id: draft.id) { load() }
        .sheet(isPresented: $editing) {
            NavigationStack {
                Form {
                    TextField("Message", text: $text, axis: .vertical)
                }
                .navigationTitle("Edit")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { editing = false }
                    }
                }
            }
        }
        .confirmationDialog("Send this \(draft.label.lowercased())?", isPresented: $confirmingSend) {
            Button("Send") { send() }
        }
        .confirmationDialog("Discard this draft?", isPresented: $confirmingDiscard) {
            Button("Discard", role: .destructive) { discard() }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if busy {
            ProgressView().frame(maxWidth: .infinity)
        } else if draft.sending {
            Label("Sending", systemImage: "paperplane").font(.footnote).foregroundStyle(.secondary)
        } else if !ready {
            ProgressView().frame(maxWidth: .infinity)
        } else {
            Button { editing = true } label: { Label("Edit", systemImage: "pencil") }
            if !draft.awaitsRecipient {
                Button { confirmingSend = true } label: { Label("Send", systemImage: "paperplane.fill") }
                    .disabled(blank)
            }
            Button(role: .destructive) { confirmingDiscard = true } label: { Label("Discard", systemImage: "trash") }
        }
    }

    private func load() {
        guard draft.cut else {
            original = draft.body
            text = draft.body
            return
        }
        pai.loadDraft(draft.id) { whole in
            guard let whole else {
                problem = "Open it on your iPhone to see the rest."
                return
            }
            original = whole.body
            text = whole.body
        }
    }

    private func send() {
        // Only an edit travels: an untouched draft is sent exactly as the box holds it.
        guard let original, !blank else { return }
        problem = nil
        pai.sendDraft(need, fields: text != original ? ["body": text] : [:]) { error in
            if let error { problem = "Not sent: \(error)" } else { dismiss() }
        }
    }

    private func discard() {
        problem = nil
        pai.answer(need, text: "Discard") { ok in
            if ok { dismiss() } else { problem = "Not discarded. Try again." }
        }
    }
}
