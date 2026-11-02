import AccountContext
import Display
import Foundation
import GraphUI
import ItemListUI
import PaiUI
import PresentationDataUtils
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramStringFormatting
import UIKit

/// Settings › Stats: what the box did for the app over the last 30 days, drawn like a channel's statistics — a grid
/// of this week's figures against the week before, then a chart per day for AI, mail and WhatsApp.

private struct SpendLine: Decodable {
    let key: String
    let apiUsd: Double
    let realUsd: Double
    let calls: Int
}

private struct AgentDaily: Decodable {
    let key: String
    let calls: [Double]
    let apiUsd: [Double]
}

private struct SpendReport: Decodable {
    struct Credits: Decodable {
        let usedUsd: Double
        let monthlyUsd: Double
    }

    let credits: Credits?
    let daily: [SpendLine]
    let dailyAgents: [AgentDaily]
}

private struct EmailStats: Decodable {
    struct Daily: Decodable {
        let days: [String]
        let received: [Double]
        let sent: [Double]
        let summarised: [Double]
        let bodies: [Double]
        let pushed: [Double]
    }

    struct Total: Decodable {
        let indexed: Int
        let summaries: Int
        let contacts: Int
        let pictures: Int
    }

    let sentFromApp: Int
    let readFromApp: Int
    let trashedFromApp: Int
    let daily: Daily
    let total: Total
}

private struct WhatsAppStats: Decodable {
    struct Daily: Decodable {
        let days: [String]
        let received: [Double]
        let sent: [Double]
    }

    struct Total: Decodable {
        let messages: Int
        let withMedia: Int
        let chats: Int
        let groups: Int
        let people: Int
    }

    let activeChats: Int
    let daily: Daily
    let total: Total
}

private struct PaiStatsData {
    let spend: SpendReport?
    let email: EmailStats?
    let whatsApp: WhatsAppStats?
    let errors: [String]
}

private let periodDays = 30
private let weekDays = 7

/// The features the app itself asks the box's models for, by the name the spending log files them under.
private let appFeatures: [(key: String, title: String, color: String)] = [
    ("compose", "Drafts", "#3497ED"),
    ("email: mail summary", "Mail summaries", "#F5A623"),
    ("summaries", "Headlines", "#4BD964")
]

private enum PaiStatsSection: Int32 {
    case ai
    case aiCalls
    case aiSpend
    case email
    case emailDaily
    case whatsApp
    case whatsAppDaily
    case errors
}

private enum PaiStatsEntry: ItemListNodeEntry {
    case header(PaiStatsSection, Int32, String, String?)
    case overview(PaiStatsSection, Int32, OverviewValues)
    case graph(PaiStatsSection, Int32, StatsGraph, ChartType)
    case footer(PaiStatsSection, Int32, String)

    var section: ItemListSectionId {
        switch self {
        case let .header(section, _, _, _), let .overview(section, _, _), let .graph(section, _, _, _), let .footer(section, _, _):
            return section.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case let .header(_, id, _, _), let .overview(_, id, _), let .graph(_, id, _, _), let .footer(_, id, _):
            return id
        }
    }

    static func ==(lhs: PaiStatsEntry, rhs: PaiStatsEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.header(_, lhsId, lhsText, lhsAccessory), .header(_, rhsId, rhsText, rhsAccessory)):
            return lhsId == rhsId && lhsText == rhsText && lhsAccessory == rhsAccessory
        case let (.overview(_, lhsId, lhsValues), .overview(_, rhsId, rhsValues)):
            return lhsId == rhsId && lhsValues == rhsValues
        case let (.graph(_, lhsId, lhsGraph, _), .graph(_, rhsId, rhsGraph, _)):
            return lhsId == rhsId && lhsGraph == rhsGraph
        case let (.footer(_, lhsId, lhsText), .footer(_, rhsId, rhsText)):
            return lhsId == rhsId && lhsText == rhsText
        default:
            return false
        }
    }

    static func <(lhs: PaiStatsEntry, rhs: PaiStatsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let context = arguments as! AccountContext
        switch self {
        case let .header(_, _, text, accessory):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, accessoryText: accessory.map { ItemListSectionHeaderAccessoryText(value: $0, color: .generic) }, sectionId: self.section)
        case let .overview(_, _, values):
            return StatsOverviewItem(context: context, presentationData: presentationData, systemStyle: .glass, isGroup: false, stats: values, sectionId: self.section, style: .blocks)
        case let .graph(_, _, graph, type):
            return StatsGraphItem(presentationData: presentationData, systemStyle: .glass, graph: graph, type: type, sectionId: self.section, style: .blocks)
        case let .footer(_, _, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private func sum(_ values: [Double], weeksBack: Int) -> Double {
    let end = values.count - weeksBack * weekDays
    return values[max(0, end - weekDays) ..< max(0, end)].reduce(0, +)
}

private func countText(_ value: Double) -> String {
    return compactNumericCountString(Int(value.rounded()))
}

private func dollars(_ value: Double) -> String {
    return value > 0 && value < 0.01 ? "<$0.01" : String(format: "$%.2f", value)
}

/// This week's total of a daily series, with its change against the week before.
private func weekly(_ title: String, _ series: [Double], format: (Double) -> String = countText) -> OverviewValues.Value {
    let current = sum(series, weeksBack: 0)
    let previous = sum(series, weeksBack: 1)
    let change = current - previous
    let delta: String? = change == 0 ? nil : (change > 0 ? "+" : "−") + format(abs(change)) + (previous > 0 ? String(format: " (%.0f%%)", abs(change) / previous * 100.0) : "")
    return OverviewValues.Value(value: format(current), title: title, delta: delta, isPositive: change > 0)
}

private func plain(_ title: String, _ value: String) -> OverviewValues.Value {
    return OverviewValues.Value(value: value, title: title, delta: nil, isPositive: true)
}

private let dayParser: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

/// A chart in Telegram's statistics JSON: one column of days, one per series.
private func graph(days: [String], _ series: [(name: String, color: String, values: [Double])], kind: String, stacked: Bool = false) -> StatsGraph {
    let x: [Any] = ["x"] + days.map { (dayParser.date(from: $0)?.timeIntervalSince1970 ?? 0) * 1000.0 }
    var columns: [[Any]] = [x]
    var types: [String: String] = ["x": "x"]
    var names: [String: String] = [:]
    var colors: [String: String] = [:]
    for (index, line) in series.enumerated() {
        let id = "y\(index)"
        columns.append([id] + line.values)
        types[id] = kind
        names[id] = line.name
        colors[id] = line.color
    }
    var json: [String: Any] = ["columns": columns, "types": types, "names": names, "colors": colors]
    if stacked {
        json["stacked"] = true
    }
    guard let data = try? JSONSerialization.data(withJSONObject: json), let text = String(data: data, encoding: .utf8) else {
        return .Empty
    }
    return .Loaded(token: nil, data: text)
}

private func paiStatsEntries(_ data: PaiStatsData) -> [PaiStatsEntry] {
    var entries: [PaiStatsEntry] = []
    if let spend = data.spend {
        let days = spend.daily.map(\.key)
        let lines = Dictionary(spend.dailyAgents.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let zero = Array(repeating: 0.0, count: days.count)
        let calls = appFeatures.map { lines[$0.key]?.calls ?? zero }
        let appSpend = appFeatures.map { lines[$0.key]?.apiUsd ?? zero }.reduce(zero) { zip($0, $1).map(+) }
        var values = zip(appFeatures, calls).map { weekly($0.0.title, $0.1) }
        values.append(weekly("App AI cost", appSpend, format: dollars))
        values.append(weekly("All AI, real cost", spend.daily.map(\.realUsd), format: dollars))
        if let credits = spend.credits, credits.monthlyUsd > 0 {
            values.append(plain("API credits, 30 days", "\(dollars(credits.usedUsd)) / \(dollars(credits.monthlyUsd))"))
        }
        entries.append(.header(.ai, 0, "AI", "LAST 7 DAYS"))
        entries.append(.overview(.ai, 1, OverviewValues(values: values)))
        entries.append(.header(.aiCalls, 2, "AI REQUESTS PER DAY", nil))
        entries.append(.graph(.aiCalls, 3, graph(days: days, zip(appFeatures, calls).map { ($0.0.title, $0.0.color, $0.1) }, kind: "bar", stacked: true), .bars))
        entries.append(.header(.aiSpend, 4, "AI COST PER DAY, $", nil))
        entries.append(.graph(.aiSpend, 5, graph(days: days, [("App features", "#3497ED", appSpend), ("All AI, real cost", "#FE3C30", spend.daily.map(\.realUsd))], kind: "line"), .lines))
        entries.append(.footer(.aiSpend, 6, "App features run on the plan's API credits; the real cost counts sessions and agents at the subscription's price."))
    }
    if let email = data.email {
        let daily = email.daily
        entries.append(.header(.email, 10, "EMAIL", "LAST 7 DAYS"))
        entries.append(.overview(.email, 11, OverviewValues(values: [
            weekly("Received", daily.received),
            weekly("Summarised", daily.summarised),
            weekly("Sent", daily.sent),
            weekly("Opened in full", daily.bodies),
            weekly("Notifications", daily.pushed),
            plain("Sent from Paigram, 30 days", countText(Double(email.sentFromApp))),
            plain("Read / trashed here", "\(email.readFromApp) / \(email.trashedFromApp)"),
            plain("Contacts with a picture", "\(email.total.pictures) / \(email.total.contacts)")
        ])))
        entries.append(.header(.emailDaily, 12, "MAIL PER DAY", nil))
        entries.append(.graph(.emailDaily, 13, graph(days: daily.days, [("Received", "#3497ED", daily.received), ("Summarised", "#F5A623", daily.summarised), ("Sent", "#4BD964", daily.sent)], kind: "line"), .lines))
        entries.append(.footer(.emailDaily, 14, "\(email.total.indexed) emails indexed, \(email.total.summaries) summarised."))
    }
    if let whatsApp = data.whatsApp {
        let daily = whatsApp.daily
        entries.append(.header(.whatsApp, 20, "WHATSAPP", "LAST 7 DAYS"))
        entries.append(.overview(.whatsApp, 21, OverviewValues(values: [
            weekly("Received", daily.received),
            weekly("Sent", daily.sent),
            plain("Active chats, 30 days", countText(Double(whatsApp.activeChats))),
            plain("Chats / groups", "\(whatsApp.total.chats) / \(whatsApp.total.groups)")
        ])))
        entries.append(.header(.whatsAppDaily, 22, "MESSAGES PER DAY", nil))
        entries.append(.graph(.whatsAppDaily, 23, graph(days: daily.days, [("Received", "#25D366", daily.received), ("Sent", "#3497ED", daily.sent)], kind: "bar", stacked: true), .bars))
        entries.append(.footer(.whatsAppDaily, 24, "\(whatsApp.total.messages) messages kept, \(whatsApp.total.withMedia) with media, \(whatsApp.total.people) people."))
    }
    if !data.errors.isEmpty {
        entries.append(.footer(.errors, 30, data.errors.joined(separator: "\n")))
    }
    return entries
}

@available(iOS 16.0, *)
private func fetch<T: Decodable>(_ client: PaiClient, _ type: T.Type, _ path: String) async -> Result<T, Error> {
    do {
        return .success(try await client.call(type, path, query: ["days": "\(periodDays)"]))
    } catch {
        return .failure(error)
    }
}

private func failure<T>(_ result: Result<T, Error>) -> String? {
    if case let .failure(error) = result {
        return error.localizedDescription
    }
    return nil
}

/// The three reports at once; one failing (WhatsApp off) leaves the others.
@available(iOS 16.0, *)
private func loadPaiStats() -> Signal<PaiStatsData, NoError> {
    return Signal<PaiStatsData, NoError> { subscriber in
        let task = Task {
            let client = PaiClient()
            async let spend = fetch(client, SpendReport.self, "/spend")
            async let email = fetch(client, EmailStats.self, "/gmail/stats")
            async let whatsApp = fetch(client, WhatsAppStats.self, "/whatsapp/stats")
            let (spendResult, emailResult, whatsAppResult) = await (spend, email, whatsApp)
            let errors: [String] = [failure(spendResult), failure(emailResult), failure(whatsAppResult)].compactMap { $0 }
            subscriber.putNext(PaiStatsData(spend: try? spendResult.get(), email: try? emailResult.get(), whatsApp: try? whatsAppResult.get(), errors: errors))
            subscriber.putCompletion()
        }
        return ActionDisposable {
            task.cancel()
        }
    }
}

@available(iOS 16.0, *)
public func paiStatsController(context: AccountContext) -> ViewController {
    let data = Promise<PaiStatsData?>(nil)
    data.set(loadPaiStats() |> map(Optional.init))

    let signal = combineLatest(context.sharedContext.presentationData, data.get())
    |> deliverOnMainQueue
    |> map { presentationData, data -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("Stats"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: data.map(paiStatsEntries) ?? [], style: .blocks, emptyStateItem: data == nil ? ItemListLoadingIndicatorEmptyStateItem(theme: presentationData.theme) : nil, crossfadeState: false, animateChanges: false)
        return (controllerState, (listState, context))
    }

    let controller = ItemListController(context: context, state: signal)
    controller.contentOffsetChanged = { [weak controller] _, _ in
        controller?.forEachItemNode({ itemNode in
            if let itemNode = itemNode as? StatsGraphItemNode {
                itemNode.resetInteraction()
            }
        })
    }
    return controller
}
