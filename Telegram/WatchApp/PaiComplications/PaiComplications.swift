import SwiftUI
import WidgetKit

/// Pai on the watch face and in the Smart Stack: usage, the asks waiting on the user, and the agents at work.
/// Each reads what the watch app last stored (`PaiVault`) and, when that is stale and the box is known, asks
/// the box itself.
@main
struct PaiComplications: WidgetBundle {
    var body: some Widget {
        PaiUsageComplication()
        PaiAsksComplication()
        PaiAgentsComplication()
    }
}

/// The window that runs out first as a gauge, with today's spend and what waits on the user in the larger families.
struct PaiUsageComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PaiUsage", provider: PaiComplicationProvider()) { entry in
            PaiComplicationView(entry: entry)
                .containerBackground(.clear, for: .widget)
                .widgetURL(PaiGlanceLink.usage)
        }
        .configurationDisplayName("Pai usage")
        .description("Plan usage, today's spend and waiting questions.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

/// The oldest ask and how many wait; a tap opens its agent.
struct PaiAsksComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PaiAsks", provider: PaiComplicationProvider()) { entry in
            PaiAsksView(entry: entry)
                .containerBackground(.clear, for: .widget)
                .widgetURL(entry.glance?.oldestNeed?.agent.map(PaiGlanceLink.agent) ?? PaiGlanceLink.usage)
        }
        .configurationDisplayName("Pai asks")
        .description("Questions waiting on you.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

/// The agents at work and what each is on.
struct PaiAgentsComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PaiAgents", provider: PaiComplicationProvider()) { entry in
            PaiAgentsView(entry: entry)
                .containerBackground(.clear, for: .widget)
                .widgetURL(PaiGlanceLink.usage)
        }
        .configurationDisplayName("Pai agents")
        .description("Who is working and on what.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct PaiComplicationEntry: TimelineEntry {
    let date: Date
    let glance: PaiGlance?
}

struct PaiComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> PaiComplicationEntry {
        PaiComplicationEntry(date: Date(), glance: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (PaiComplicationEntry) -> Void) {
        completion(PaiComplicationEntry(date: Date(), glance: context.isPreview ? (PaiVault.glance ?? .sample) : PaiVault.glance))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PaiComplicationEntry>) -> Void) {
        let stored = PaiVault.glance
        let finish = { (glance: PaiGlance?) in
            completion(Timeline(entries: [PaiComplicationEntry(date: Date(), glance: glance)], policy: .after(Date().addingTimeInterval(15 * 60))))
        }
        guard let config = PaiVault.config, (stored.map { Date().timeIntervalSince($0.at) > 10 * 60 } ?? true) else {
            finish(stored)
            return
        }
        PaiGlanceLiveSource(config: config).glance { result in
            if case let .success(fresh) = result {
                let glance = fresh.keepingWindows(of: stored)
                PaiVault.glance = glance
                finish(glance)
            } else {
                finish(stored)
            }
        }
    }
}

struct PaiComplicationView: View {
    let entry: PaiComplicationEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let glance = entry.glance, let window = glance.limiting {
            switch family {
            case .accessoryCircular:
                gauge(window)
            case .accessoryCorner:
                Text(PaiFormat.usd(glance.todayUsd))
                    .widgetCurvesContent()
                    .widgetLabel {
                        Gauge(value: min(window.percent, 100), in: 0 ... 100) {
                            Text(short(window))
                        }
                        .tint(PaiFormat.tint(window.percent))
                    }
            case .accessoryInline:
                Text("\(short(window)) \(Int(window.percent.rounded()))% · \(PaiFormat.usd(glance.todayUsd))\(glance.needsCount > 0 ? " · \(glance.needsCount)?" : "")")
            default:
                rectangular(glance)
            }
        } else if let glance = entry.glance {
            switch family {
            case .accessoryInline: Text("\(PaiFormat.usd(glance.todayUsd))\(glance.needsCount > 0 ? " · \(glance.needsCount)?" : "")")
            case .accessoryRectangular: rectangular(glance)
            default: Text(PaiFormat.usd(glance.todayUsd)).font(.system(size: 12).monospacedDigit()).minimumScaleFactor(0.5)
            }
        } else {
            switch family {
            case .accessoryInline: Text("Pai")
            case .accessoryRectangular: Text("Open Paigram on iPhone").font(.footnote)
            default: Image(systemName: "gauge.with.dots.needle.0percent")
            }
        }
    }

    private func short(_ window: PaiGlance.Window) -> String {
        window.name == "Weekly" ? "W" : "5h"
    }

    private func gauge(_ window: PaiGlance.Window) -> some View {
        Gauge(value: min(window.percent, 100), in: 0 ... 100) {
            Text(short(window))
        } currentValueLabel: {
            Text("\(Int(window.percent.rounded()))")
        }
        .gaugeStyle(.accessoryCircular)
        .tint(PaiFormat.tint(window.percent))
    }

    private func rectangular(_ glance: PaiGlance) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(glance.windows.prefix(2)) { window in
                HStack(spacing: 4) {
                    Text(window.name == "Weekly" ? "Week" : "5h").frame(width: 34, alignment: .leading)
                    Gauge(value: min(window.percent, 100), in: 0 ... 100) { EmptyView() }
                        .gaugeStyle(.accessoryLinearCapacity)
                        .tint(PaiFormat.tint(window.percent))
                    Text("\(Int(window.percent.rounded()))%").frame(width: 34, alignment: .trailing)
                }
            }
            HStack(spacing: 6) {
                Text(PaiFormat.usd(glance.todayUsd))
                Spacer(minLength: 0)
                if glance.running > 0 { Label("\(glance.running)", systemImage: "bolt.fill") }
                if glance.needsCount > 0 { Label("\(glance.needsCount)", systemImage: "questionmark.bubble.fill") }
            }
            .labelStyle(PaiCompactLabel())
        }
        .font(.system(size: 12).monospacedDigit())
    }
}

struct PaiAsksView: View {
    let entry: PaiComplicationEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let count = entry.glance?.needsCount ?? 0
        let need = entry.glance?.oldestNeed
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: count > 0 ? "questionmark.bubble.fill" : "checkmark.bubble")
                        .font(.system(size: 14))
                    Text("\(count)").font(.system(size: 16, weight: .semibold).monospacedDigit())
                }
            }
        case .accessoryCorner:
            Image(systemName: count > 0 ? "questionmark.bubble.fill" : "checkmark.bubble")
                .font(.system(size: 20))
                .widgetLabel { Text(count > 0 ? "\(count) waiting" : "Nothing waiting") }
        case .accessoryInline:
            if let need {
                Text("\(count)? \(need.from): \(need.plainQuestion)")
            } else {
                Text(entry.glance == nil ? "Pai" : "No asks")
            }
        default:
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: "questionmark.bubble.fill")
                    Text(count > 0 ? "\(count) waiting" : "Nothing waiting").font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    if let need { Text(need.createdAt, style: .relative).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                if let need {
                    Text("\(need.from): \(need.plainQuestion)").font(.system(size: 13)).lineLimit(2)
                } else if entry.glance == nil {
                    Text("Open Paigram on iPhone").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct PaiAgentsView: View {
    let entry: PaiComplicationEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let team = entry.glance?.team ?? []
        let working = team.filter(\.working)
        let running = max(working.count, entry.glance?.running ?? 0)
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: "bolt.fill").font(.system(size: 14))
                    Text("\(running)").font(.system(size: 16, weight: .semibold).monospacedDigit())
                }
            }
        case .accessoryInline:
            if let first = working.first {
                Text("\(first.name): \(first.now?.text ?? first.doing ?? "working")")
            } else {
                Text(entry.glance == nil ? "Pai" : "\(running) running")
            }
        default:
            // Working agents first; when none work, the ones whose plan has a step under way.
            let shown = Array((working + team.filter { !$0.working && $0.now != nil }).prefix(2))
            VStack(alignment: .leading, spacing: 1) {
                if shown.isEmpty {
                    Label(entry.glance == nil ? "Open Paigram on iPhone" : "\(running) running", systemImage: "bolt.fill")
                        .font(.system(size: 13))
                }
                ForEach(shown) { member in
                    HStack(spacing: 3) {
                        Image(systemName: member.working ? "bolt.fill" : "arrow.right.circle")
                            .font(.system(size: 10))
                        Text(member.name).font(.system(size: 13, weight: .semibold))
                    }
                    Text(member.now?.text ?? member.doing ?? "").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(shown.count == 1 ? 2 : 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PaiCompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 1) {
            configuration.icon
            configuration.title
        }
    }
}
