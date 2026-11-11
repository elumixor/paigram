import SwiftUI
import WidgetKit

/// Usage complications: the window that runs out first as a gauge, with today's spend and what waits on the
/// user in the larger families. Reads what the watch app last stored (`PaiVault`) and, when that is stale and
/// the box is known, asks the box itself.
@main
struct PaiComplications: Widget {
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
            if case let .success(glance) = result {
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

private struct PaiCompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 1) {
            configuration.icon
            configuration.title
        }
    }
}
