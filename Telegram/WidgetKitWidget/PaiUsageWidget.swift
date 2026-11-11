#if arch(arm64) || arch(x86_64)

import Foundation
import SwiftUI
import WidgetKit
import PaiGlance

/// Paigram's glance on the home and lock screens: plan usage, today's spend, running agents and what waits on the user.
@available(iOS 14.0, *)
struct PaiUsageWidget: Widget {
    private let kind = "PaiUsage"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PaiGlanceProvider()) { entry in
            PaiGlanceWidgetView(entry: entry)
        }
        .configurationDisplayName("pai")
        .description("Usage, spend, running agents and questions waiting on you.")
        .supportedFamilies(PaiUsageWidget.families)
    }

    private static var families: [WidgetFamily] {
        if #available(iOS 16.0, *) {
            return [.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline]
        }
        return [.systemSmall, .systemMedium]
    }
}

@available(iOS 14.0, *)
struct PaiGlanceEntry: TimelineEntry {
    let date: Date
    let glance: PaiGlance?
    let signedIn: Bool
}

@available(iOS 14.0, *)
struct PaiGlanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> PaiGlanceEntry {
        PaiGlanceEntry(date: Date(), glance: .sample, signedIn: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (PaiGlanceEntry) -> Void) {
        let store = PaiGlanceStore.appGroup()
        if context.isPreview || store?.config == nil {
            completion(PaiGlanceEntry(date: Date(), glance: store?.glance ?? .sample, signedIn: true))
            return
        }
        completion(PaiGlanceEntry(date: Date(), glance: store?.glance, signedIn: true))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PaiGlanceEntry>) -> Void) {
        let refresh = Date().addingTimeInterval(15 * 60)
        guard let store = PaiGlanceStore.appGroup(), let source = store.source else {
            completion(Timeline(entries: [PaiGlanceEntry(date: Date(), glance: nil, signedIn: false)], policy: .after(refresh)))
            return
        }
        source.glance { result in
            var glance = store.glance
            if case let .success(fresh) = result {
                store.saveGlance(fresh)
                PaiUsageAlerts.post(store.crossings(in: fresh))
                glance = fresh
            }
            completion(Timeline(entries: [PaiGlanceEntry(date: Date(), glance: glance, signedIn: true)], policy: .after(refresh)))
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
        if let agent = entry.glance?.oldestNeed?.agent, family != .systemMedium {
            return PaiGlanceLink.agent(agent)
        }
        return PaiGlanceLink.usage
    }

    @ViewBuilder
    private var content: some View {
        if let glance = entry.glance {
            switch family {
            case .systemMedium:
                PaiMediumView(glance: glance)
            case .systemSmall:
                PaiSmallView(glance: glance)
            default:
                if #available(iOS 16.0, *) {
                    PaiAccessoryView(glance: glance, family: family)
                } else {
                    PaiSmallView(glance: glance)
                }
            }
        } else {
            VStack(spacing: 4) {
                Image(systemName: "sparkles").font(.title3)
                Text(entry.signedIn ? "Loading…" : "Sign in to pai in Paigram")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
            }
            .padding()
        }
    }
}

enum PaiGlanceStyle {
    static func color(_ percent: Double) -> Color {
        if percent >= 90 { return .red }
        if percent >= 70 { return .orange }
        return .green
    }

    static func usd(_ value: Double) -> String {
        value >= 100 ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
    }

    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    static func age(_ date: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 24 * 60 { return "\(minutes / 60)h" }
        return "\(minutes / 1440)d"
    }
}

@available(iOS 14.0, *)
private struct PaiRing: View {
    let percent: Double
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(percent, 100) / 100))
                .stroke(PaiGlanceStyle.color(percent), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

@available(iOS 14.0, *)
private struct PaiBar: View {
    let window: PaiGlance.Window

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(window.name).font(.caption2.weight(.semibold)).foregroundColor(.secondary)
                Spacer(minLength: 0)
                Text(PaiGlanceStyle.percent(window.percent)).font(.caption.weight(.bold)).monospacedDigitIfAvailable()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(PaiGlanceStyle.color(window.percent))
                        .frame(width: proxy.size.width * CGFloat(min(window.percent, 100) / 100))
                }
            }
            .frame(height: 5)
            if let left = window.resetsIn() {
                Text("resets in \(left)").font(.system(size: 9)).foregroundColor(.secondary)
            }
        }
    }
}

@available(iOS 14.0, *)
private struct PaiNeedsBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: count > 0 ? "questionmark.bubble.fill" : "checkmark.bubble")
            Text("\(count)").monospacedDigitIfAvailable()
        }
        .font(.caption.weight(.semibold))
        .foregroundColor(count > 0 ? .orange : .secondary)
    }
}

@available(iOS 14.0, *)
private struct PaiRunningBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "bolt.fill")
            Text("\(count)").monospacedDigitIfAvailable()
        }
        .font(.caption.weight(.semibold))
        .foregroundColor(count > 0 ? .blue : .secondary)
    }
}

@available(iOS 14.0, *)
private struct PaiSmallView: View {
    let glance: PaiGlance

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                if let window = glance.limiting {
                    ZStack {
                        PaiRing(percent: window.percent, lineWidth: 6)
                        VStack(spacing: 0) {
                            Text(PaiGlanceStyle.percent(window.percent)).font(.system(size: 14, weight: .bold)).monospacedDigitIfAvailable()
                            Text(window.name == "Weekly" ? "week" : "5h").font(.system(size: 8)).foregroundColor(.secondary)
                        }
                    }
                    .frame(width: 54, height: 54)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("today").font(.caption2).foregroundColor(.secondary)
                    Text(PaiGlanceStyle.usd(glance.todayUsd)).font(.system(size: 17, weight: .bold)).monospacedDigitIfAvailable()
                        .minimumScaleFactor(0.6).lineLimit(1)
                }
            }
            HStack(spacing: 10) {
                PaiRunningBadge(count: glance.running)
                PaiNeedsBadge(count: glance.needsCount)
            }
            if let need = glance.oldestNeed {
                Text("\(need.from): \(need.plainQuestion)")
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .foregroundColor(.primary)
            } else if let top = glance.agents.first {
                Text("\(top.name) \(PaiGlanceStyle.usd(top.usd))").font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
    }
}

@available(iOS 14.0, *)
private struct PaiMediumView: View {
    let glance: PaiGlance

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Link(destination: PaiGlanceLink.usage) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(PaiGlanceStyle.usd(glance.todayUsd)).font(.system(size: 20, weight: .bold)).monospacedDigitIfAvailable()
                        Text("today").font(.caption2).foregroundColor(.secondary)
                    }
                    ForEach(glance.windows.filter { $0.name == "Session" || $0.name == "Weekly" }) { window in
                        PaiBar(window: window)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    PaiRunningBadge(count: glance.running)
                    PaiNeedsBadge(count: glance.needsCount)
                }
                if let need = glance.oldestNeed {
                    Link(destination: need.agent.map(PaiGlanceLink.agent) ?? PaiGlanceLink.usage) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(need.from) · \(PaiGlanceStyle.age(need.createdAt))").font(.caption2.weight(.semibold)).foregroundColor(.orange)
                            Text(need.plainQuestion).font(.system(size: 11)).lineLimit(2)
                        }
                    }
                }
                ForEach(glance.agents.prefix(glance.oldestNeed == nil ? 4 : 2)) { agent in
                    Link(destination: PaiGlanceLink.agent(agent.slug)) {
                        HStack(spacing: 4) {
                            Text(agent.name).font(.system(size: 11)).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(PaiGlanceStyle.usd(agent.usd)).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary).monospacedDigitIfAvailable()
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
    }
}

@available(iOS 16.0, *)
private struct PaiAccessoryView: View {
    let glance: PaiGlance
    let family: WidgetFamily

    var body: some View {
        let window = glance.limiting
        switch family {
        case .accessoryCircular:
            Gauge(value: min(window?.percent ?? 0, 100), in: 0 ... 100) {
                Text(window?.name == "Weekly" ? "W" : "5h")
            } currentValueLabel: {
                Text("\(Int((window?.percent ?? 0).rounded()))")
            }
            .gaugeStyle(.accessoryCircular)
        case .accessoryInline:
            Text("\(PaiGlanceStyle.percent(window?.percent ?? 0)) · \(PaiGlanceStyle.usd(glance.todayUsd)) · \(glance.needsCount)?")
        default:
            VStack(alignment: .leading, spacing: 1) {
                Text("pai \(PaiGlanceStyle.usd(glance.todayUsd))").font(.headline)
                Text(glance.windows.prefix(2).map { "\($0.name == "Weekly" ? "W" : "5h") \(PaiGlanceStyle.percent($0.percent))" }.joined(separator: "  "))
                Text("\(glance.running) running · \(glance.needsCount) waiting").foregroundColor(.secondary)
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
