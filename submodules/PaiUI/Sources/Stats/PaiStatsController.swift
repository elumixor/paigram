import AccountContext
import Foundation
import SwiftUI
import UIKit

/// Settings › Stats: what the box did for the app over a day, a week or a month — AI spend by feature (compose,
/// mail summaries, the rest), mail in, out and summarised, WhatsApp traffic, and the totals it keeps.
@available(iOS 16.0, *)
public final class PaiStatsController: PaiHostedController {
    public override init(context: AccountContext) {
        super.init(context: context)
        self.host(PaiStatsView(model: PaiStatsModel(), close: { [weak self] in
            self?.dismiss()
        }))
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct SpendLine: Decodable {
    let key: String
    let apiUsd: Double
    let realUsd: Double
    let calls: Int
    let input: Int
    let output: Int
}

struct SpendReport: Decodable {
    struct Credits: Decodable {
        let usedUsd: Double
        let monthlyUsd: Double
    }

    struct By: Decodable {
        let agent: [SpendLine]
    }

    let credits: Credits?
    let total: SpendLine
    let by: By
}

struct EmailStats: Decodable {
    struct Total: Decodable {
        let indexed: Int
        let summaries: Int
        let contacts: Int
        let pictures: Int
    }

    let received: Int
    let sentByMail: Int
    let sentFromApp: Int
    let bodiesFetched: Int
    let summarised: Int
    let readFromApp: Int
    let trashedFromApp: Int
    let pushed: Int
    let total: Total
}

struct WhatsAppStats: Decodable {
    struct Total: Decodable {
        let messages: Int
        let withMedia: Int
        let mediaDownloaded: Int
        let chats: Int
        let groups: Int
        let people: Int
        let pictures: Int
    }

    let received: Int
    let sent: Int
    let activeChats: Int
    let total: Total
}

enum StatsPeriod: Int, CaseIterable, Identifiable {
    case day = 1
    case week = 7
    case month = 30

    var id: Int {
        return self.rawValue
    }

    var title: String {
        switch self {
        case .day:
            return "Today"
        case .week:
            return "7 days"
        case .month:
            return "30 days"
        }
    }
}

@available(iOS 16.0, *)
@MainActor
final class PaiStatsModel: ObservableObject {
    @Published var period: StatsPeriod = .week
    @Published private(set) var spend: SpendReport?
    @Published private(set) var email: EmailStats?
    @Published private(set) var whatsApp: WhatsAppStats?
    @Published private(set) var errors: [String] = []
    private let client = PaiClient()

    /// The three reports at once; one failing (WhatsApp off) leaves the others.
    func load() async {
        let days = ["days": "\(self.period.rawValue)"]
        async let spend = self.fetch(SpendReport.self, "/spend", days)
        async let email = self.fetch(EmailStats.self, "/gmail/stats", days)
        async let whatsApp = self.fetch(WhatsAppStats.self, "/whatsapp/stats", days)
        let results = await (spend, email, whatsApp)
        self.spend = try? results.0.get()
        self.email = try? results.1.get()
        self.whatsApp = try? results.2.get()
        self.errors = [results.0.error, results.1.error, results.2.error].compactMap { $0 }
    }

    private func fetch<T: Decodable>(_ type: T.Type, _ path: String, _ query: [String: String]) async -> Result<T, Error> {
        do {
            return .success(try await self.client.call(type, path, query: query))
        } catch {
            return .failure(error)
        }
    }
}

private extension Result {
    var error: String? {
        if case let .failure(error) = self {
            return error.localizedDescription
        }
        return nil
    }
}

/// The features the app itself asks the box's models for, by the name the spending log files them under.
private let appFeatures: [(key: String, title: String)] = [
    ("compose", "Drafts rewritten"),
    ("email: mail summary", "Mail summaries"),
    ("summaries", "Headlines and gists")
]

private func dollars(_ value: Double) -> String {
    return value < 0.01 && value > 0 ? "<$0.01" : String(format: "$%.2f", value)
}

private func tokens(_ value: Int) -> String {
    return value >= 1_000_000 ? String(format: "%.1fM", Double(value) / 1_000_000) : value >= 1_000 ? String(format: "%.0fk", Double(value) / 1_000) : "\(value)"
}

@available(iOS 16.0, *)
struct PaiStatsView: View {
    @ObservedObject var model: PaiStatsModel
    let close: () -> Void

    var body: some View {
        NavigationView {
            List {
                Picker("Period", selection: self.$model.period) {
                    ForEach(StatsPeriod.allCases) { period in
                        Text(period.title).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                if let spend = self.model.spend {
                    self.aiSection(spend)
                }
                if let email = self.model.email {
                    self.emailSection(email)
                }
                if let whatsApp = self.model.whatsApp {
                    self.whatsAppSection(whatsApp)
                }
                if !self.model.errors.isEmpty {
                    Section(footer: Text(self.model.errors.joined(separator: "\n"))) {}
                }
            }
            .navigationTitle("Stats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: self.close)
                }
            }
            .refreshable {
                await self.model.load()
            }
            .task(id: self.model.period) {
                await self.model.load()
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundColor(.secondary).monospacedDigit()
        }
    }

    @ViewBuilder
    private func aiSection(_ spend: SpendReport) -> some View {
        let lines = Dictionary(spend.by.agent.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let others = spend.by.agent.filter { line in !appFeatures.contains(where: { $0.key == line.key }) }
        Section(header: Text("AI"), footer: Text("Features on the plan's API credits cost nothing extra until the month's credits run out; sessions are on the subscription.")) {
            if let credits = spend.credits {
                VStack(alignment: .leading, spacing: 6) {
                    self.row("API credits this month", "\(dollars(credits.usedUsd)) of \(dollars(credits.monthlyUsd))")
                    ProgressView(value: min(credits.usedUsd, credits.monthlyUsd), total: max(credits.monthlyUsd, 1))
                }
            }
            ForEach(appFeatures, id: \.key) { feature in
                let line = lines[feature.key]
                self.row(feature.title, "\(line?.calls ?? 0) · \(dollars(line?.apiUsd ?? 0))")
            }
            self.row("Claude sessions and agents", "\(others.reduce(0) { $0 + $1.calls }) · \(dollars(others.reduce(0) { $0 + $1.realUsd }))")
            self.row("Tokens in / out", "\(tokens(spend.total.input)) / \(tokens(spend.total.output))")
        }
    }

    @ViewBuilder
    private func emailSection(_ email: EmailStats) -> some View {
        Section(header: Text("Email"), footer: Text("\(email.total.indexed) emails indexed, \(email.total.summaries) summarised, \(email.total.pictures) of \(email.total.contacts) correspondents with a picture.")) {
            self.row("Received", "\(email.received)")
            self.row("Summarised", "\(email.summarised)")
            self.row("Opened in full", "\(email.bodiesFetched)")
            self.row("Sent from Paigram", "\(email.sentFromApp)")
            self.row("Sent from any client", "\(email.sentByMail)")
            self.row("Read / trashed here", "\(email.readFromApp) / \(email.trashedFromApp)")
            self.row("Notifications", "\(email.pushed)")
        }
    }

    @ViewBuilder
    private func whatsAppSection(_ whatsApp: WhatsAppStats) -> some View {
        Section(header: Text("WhatsApp"), footer: Text("\(whatsApp.total.messages) messages kept (\(whatsApp.total.withMedia) with media, \(whatsApp.total.mediaDownloaded) downloaded), \(whatsApp.total.chats) chats and \(whatsApp.total.groups) groups, \(whatsApp.total.pictures) pictures.")) {
            self.row("Received", "\(whatsApp.received)")
            self.row("Sent", "\(whatsApp.sent)")
            self.row("Active chats", "\(whatsApp.activeChats)")
        }
    }
}
