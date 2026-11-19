#if arch(arm64) || arch(x86_64)

import Foundation
import SwiftUI
import WidgetKit
import PaiGlance

/// Paigram's glance on the home and lock screens: what waits on the user, what the agents do, and the weekly window.
@available(iOS 14.0, *)
struct PaiUsageWidget: Widget {
    private let kind = "PaiUsage"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PaiGlanceProvider()) { entry in
            PaiGlanceWidgetView(entry: entry)
        }
        .configurationDisplayName("pai")
        .description("Questions waiting on you, what your agents are doing, and the weekly limit.")
        .supportedFamilies(PaiUsageWidget.families)
    }

    private static var families: [WidgetFamily] {
        if #available(iOS 16.0, *) {
            return [.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline]
        }
        return [.systemSmall, .systemMedium, .systemLarge]
    }
}

@available(iOS 14.0, *)
struct PaiGlanceEntry: TimelineEntry {
    let date: Date
    let glance: PaiGlance?
    let state: State

    enum State {
        case ready
        case signedOut
        /// Signed in, but the box could not be read and nothing is stored yet.
        case unreachable
    }
}

@available(iOS 14.0, *)
struct PaiGlanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> PaiGlanceEntry {
        PaiGlanceEntry(date: Date(), glance: .sample, state: .ready)
    }

    func getSnapshot(in context: Context, completion: @escaping (PaiGlanceEntry) -> Void) {
        let store = PaiGlanceStore.appGroup()
        if context.isPreview || store?.config == nil {
            completion(PaiGlanceEntry(date: Date(), glance: store?.glance ?? .sample, state: .ready))
            return
        }
        if let glance = store?.glance {
            completion(PaiGlanceEntry(date: Date(), glance: glance, state: .ready))
            return
        }
        fetch { completion($0) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PaiGlanceEntry>) -> Void) {
        fetch { entry in
            // Retry soon while there is nothing to show; otherwise every 15 minutes (the app reloads sooner).
            let minutes: Double = entry.glance == nil && entry.state == .unreachable ? 3 : 15
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(minutes * 60))))
        }
    }

    /// Reads the box and stores what it returned; falls back to the stored glance.
    private func fetch(completion: @escaping (PaiGlanceEntry) -> Void) {
        guard let store = PaiGlanceStore.appGroup(), let source = store.source else {
            completion(PaiGlanceEntry(date: Date(), glance: nil, state: .signedOut))
            return
        }
        source.glance { result in
            var glance = store.glance
            if case let .success(fresh) = result {
                let saved = store.saveGlance(fresh)
                PaiUsageAlerts.post(store.crossings(in: saved))
                glance = saved
            }
            completion(PaiGlanceEntry(date: Date(), glance: glance, state: glance == nil ? .unreachable : .ready))
        }
    }
}

// MARK: - Views

@available(iOS 14.0, *)
struct PaiGlanceWidgetView: View {
    let entry: PaiGlanceEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .paiWidgetBackground()
            .widgetURL(url)
    }

    private var url: URL {
        if let glance = entry.glance, let agent = PaiWidgetModel(glance: glance, now: entry.date).oldestAsk?.agent,
           family != .systemMedium, family != .systemLarge {
            return PaiGlanceLink.agent(agent)
        }
        return PaiGlanceLink.usage
    }

    @ViewBuilder
    private var content: some View {
        if let glance = entry.glance {
            let model = PaiWidgetModel(glance: glance, now: entry.date)
            switch family {
            case .systemMedium:
                PaiMediumView(model: model)
            case .systemLarge:
                PaiLargeView(model: model)
            case .systemSmall:
                PaiSmallView(model: model)
            default:
                if #available(iOS 16.0, *) {
                    PaiAccessoryView(model: model, family: family)
                } else {
                    PaiSmallView(model: model)
                }
            }
        } else {
            VStack(spacing: 4) {
                Image(systemName: "sparkles").font(.title3)
                Text(entry.state == .signedOut ? "Sign in to pai in Paigram" : "Can't reach pai. Retrying…")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
            }
            .padding()
        }
    }
}

enum PaiGlanceStyle {
    static func color(_ percent: Double?) -> Color {
        guard let percent = percent else { return .secondary }
        if percent >= 90 { return .red }
        if percent >= 70 { return .orange }
        return .green
    }
}

/// The weekly window as a capsule, with the 5-hour window as a thin strip inside it.
@available(iOS 14.0, *)
private struct PaiWeekBar: View {
    let bar: PaiWidgetModel.Bar
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    if let weekly = bar.weekly {
                        Capsule().fill(PaiGlanceStyle.color(bar.peakPercent).opacity(0.85))
                            .frame(width: max(proxy.size.height, proxy.size.width * CGFloat(weekly)))
                    }
                    if let session = bar.session {
                        Capsule().fill(Color.primary.opacity(0.55))
                            .frame(width: max(2, (proxy.size.width - 4) * CGFloat(session)), height: 2)
                            .padding(.leading, 2)
                    }
                }
            }
            .frame(height: 8)
            HStack(spacing: 4) {
                Text("Week \(bar.weeklyLabel)").foregroundColor(.primary)
                Text("5h \(bar.sessionLabel)")
                if !compact, let resets = bar.weeklyResetsIn {
                    Spacer(minLength: 0)
                    Text("resets \(resets)")
                }
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.secondary)
            .monospacedDigitIfAvailable()
            .lineLimit(1)
        }
    }
}

@available(iOS 14.0, *)
private struct PaiAsksHeader: View {
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(count)")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundColor(count > 0 ? .orange : .secondary)
                .monospacedDigitIfAvailable()
            Text(count == 1 ? "ask" : "asks").font(.subheadline.weight(.medium)).foregroundColor(.secondary)
        }
        .lineLimit(1)
    }
}

@available(iOS 14.0, *)
private struct PaiAskRow: View {
    let ask: PaiWidgetModel.Ask
    var lines = 2

    var body: some View {
        Link(destination: ask.agent.map(PaiGlanceLink.agent) ?? PaiGlanceLink.usage) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(ask.from) · \(ask.age)").font(.caption2.weight(.semibold)).foregroundColor(.secondary).lineLimit(1)
                Text(ask.question).font(.system(size: 12)).foregroundColor(.primary).lineLimit(lines)
            }
        }
    }
}

@available(iOS 14.0, *)
private struct PaiAgentRow: View {
    let agent: PaiWidgetModel.Agent

    var body: some View {
        Link(destination: PaiGlanceLink.agent(agent.slug)) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Circle().fill(agent.working ? Color.green : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                    Text(agent.name).font(.caption.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if let age = agent.age {
                        Text(age).font(.caption2).foregroundColor(.secondary).monospacedDigitIfAvailable()
                    }
                }
                Text(agent.line).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
            }
        }
    }
}

@available(iOS 14.0, *)
private struct PaiHoldLine: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "pause.circle.fill")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.orange)
            .lineLimit(1)
    }
}

@available(iOS 14.0, *)
private struct PaiSmallView: View {
    let model: PaiWidgetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PaiAsksHeader(count: model.asksCount)
            if let ask = model.oldestAsk {
                Text("\(ask.from) · \(ask.age)").font(.caption2.weight(.semibold)).foregroundColor(.secondary).lineLimit(1)
                Text(ask.question).font(.system(size: 12)).lineLimit(2)
            } else if let agent = model.agents.first {
                Text(agent.name).font(.caption2.weight(.semibold)).foregroundColor(.secondary).lineLimit(1)
                Text(agent.line).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            PaiWeekBar(bar: model.bar, compact: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
    }
}

@available(iOS 14.0, *)
private struct PaiMediumView: View {
    let model: PaiWidgetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    PaiAsksHeader(count: model.asksCount)
                    if let ask = model.oldestAsk {
                        PaiAskRow(ask: ask)
                    } else {
                        Text("Nothing waiting").font(.system(size: 12)).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.agents.prefix(model.holdLine == nil ? 3 : 2)) { PaiAgentRow(agent: $0) }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let hold = model.holdLine { PaiHoldLine(text: hold) }
            PaiWeekBar(bar: model.bar)
        }
        .padding(14)
    }
}

@available(iOS 14.0, *)
private struct PaiLargeView: View {
    let model: PaiWidgetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PaiAsksHeader(count: model.asksCount)
            ForEach(model.asks.prefix(2)) { PaiAskRow(ask: $0, lines: 1) }
            if !model.agents.isEmpty {
                Divider()
                ForEach(model.agents.prefix(model.asks.count > 1 ? 4 : 5)) { PaiAgentRow(agent: $0) }
            }
            Spacer(minLength: 0)
            if let hold = model.holdLine { PaiHoldLine(text: hold) }
            PaiWeekBar(bar: model.bar)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
    }
}

@available(iOS 16.0, *)
private struct PaiAccessoryView: View {
    let model: PaiWidgetModel
    let family: WidgetFamily

    var body: some View {
        switch family {
        case .accessoryCircular:
            if let weekly = model.bar.weekly {
                Gauge(value: weekly) {
                    Text("W")
                } currentValueLabel: {
                    Text("\(Int((weekly * 100).rounded()))")
                }
                .gaugeStyle(.accessoryCircular)
            } else {
                ZStack {
                    AccessoryWidgetBackground()
                    VStack(spacing: 0) {
                        Text("W").font(.caption2)
                        Text(PaiWidgetModel.Bar.unknownLabel).font(.headline)
                    }
                }
            }
        case .accessoryInline:
            Text("\(model.asksCount) asks · W \(model.bar.weeklyLabel) · 5h \(model.bar.sessionLabel)")
        default:
            VStack(alignment: .leading, spacing: 1) {
                Text("\(model.asksCount) \(model.asksCount == 1 ? "ask" : "asks")").font(.headline)
                if let ask = model.oldestAsk {
                    Text("\(ask.from): \(ask.question)").lineLimit(1)
                }
                Text("Week \(model.bar.weeklyLabel) · 5h \(model.bar.sessionLabel)").foregroundColor(.secondary)
            }
            .font(.caption)
        }
    }
}

@available(iOS 14.0, *)
private extension View {
    @ViewBuilder
    func paiWidgetBackground() -> some View {
        if #available(iOS 17.0, *) {
            containerBackground(for: .widget) { Color(UIColor.systemBackground) }
        } else {
            background(Color(UIColor.systemBackground))
        }
    }

    @ViewBuilder
    func monospacedDigitIfAvailable() -> some View {
        if #available(iOS 15.0, *) {
            monospacedDigit()
        } else {
            self
        }
    }
}

#endif
