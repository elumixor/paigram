import AccountContext
import Display
import Foundation
import SwiftUI
import UIKit

/// What the box asked before it could rewrite the draft: notes to read, questions to answer by tapping an option
/// or typing. The presenter runs the next request; this screen only collects the answers.
@available(iOS 16.0, *)
public final class PaiComposeQuestionsController: PaiHostedController {
    /// The answers given, one per answered question; the screen is already gone when this runs.
    public var rewrite: (([PaiComposeAnswer]) -> Void)?
    /// The box's best guess as it stands, taken without answering.
    public var useText: (() -> Void)?

    public init(context: AccountContext, result: PaiComposeResult) {
        super.init(context: context)
        let useText: (() -> Void)? = result.text.isEmpty ? nil : { [weak self] in
            guard let self else { return }
            self.dismiss()
            self.useText?()
        }
        self.host(PaiComposeQuestionsView(result: result, rewrite: { [weak self] answers in
            guard let self else { return }
            self.dismiss()
            self.rewrite?(answers)
        }, useText: useText, close: { [weak self] in
            self?.dismiss()
        }))
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@available(iOS 16.0, *)
struct PaiComposeQuestionsView: View {
    let result: PaiComposeResult
    let rewrite: ([PaiComposeAnswer]) -> Void
    let useText: (() -> Void)?
    let close: () -> Void
    /// Keyed by question; a typed answer replaces a tapped option.
    @State private var answers: [String: String] = [:]
    @EnvironmentObject private var insets: PaiInsets

    private var collected: [PaiComposeAnswer] {
        result.questions.compactMap { question in
            let answer = (answers[question.question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return answer.isEmpty ? nil : PaiComposeAnswer(question: question.question, answer: answer)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !result.notes.isEmpty {
                    Section {
                        ForEach(result.notes, id: \.self) { note in
                            Label(note, systemImage: "info.circle").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(result.questions) { question in
                    Section {
                        if !question.options.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(question.options, id: \.self) { option in
                                        chip(option, selected: answers[question.question] == option) {
                                            answers[question.question] = option
                                        }
                                    }
                                }
                            }
                        }
                        TextField("Your answer", text: binding(for: question.question), axis: .vertical)
                    } header: {
                        Text(question.question).font(.body).foregroundStyle(.primary).textCase(nil)
                    }
                }
            }
            .navigationTitle("Before rewriting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel", action: close) }
                if let useText {
                    ToolbarItem(placement: .topBarTrailing) { Button("Use as is", action: useText) }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    rewrite(collected)
                } label: {
                    Text("Rewrite").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(collected.isEmpty)
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8 + insets.bottom)
                .background(Color(.systemGroupedBackground))
            }
        }
    }

    private func binding(for question: String) -> Binding<String> {
        Binding(get: { answers[question] ?? "" }, set: { answers[question] = $0 })
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.accentColor : Color(.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
