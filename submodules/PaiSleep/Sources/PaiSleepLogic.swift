import Foundation

/// One HealthKit sleep analysis sample, reduced to what the nightly merge needs.
public struct PaiSleepSample: Equatable {
    /// `HKCategoryValueSleepAnalysis` raw values, so this file needs neither HealthKit nor iOS 16.
    public enum Stage: Int {
        case inBed = 0
        case unspecified = 1
        case awake = 2
        case core = 3
        case deep = 4
        case rem = 5

        var isAsleep: Bool { self == .unspecified || self == .core || self == .deep || self == .rem }
    }

    public let start: Date
    public let end: Date
    public let stage: Stage
    /// The app or device that wrote it ("Apple Watch", "AutoSleep").
    public let source: String

    public init(start: Date, end: Date, stage: Stage, source: String) {
        self.start = start
        self.end = end
        self.stage = stage
        self.source = source
    }

    var minutes: Double { max(0, end.timeIntervalSince(start)) / 60 }
}

/// One night as pai's `POST /activity/sleep` takes it.
public struct PaiSleepSession: Equatable {
    public let start: Date
    public let end: Date
    public let deep: Int
    public let rem: Int
    public let core: Int
    public let unspecified: Int
    public let awake: Int
    public let source: String

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    public var body: [String: Any] {
        [
            "start": PaiSleepNights.iso(start),
            "end": PaiSleepNights.iso(end),
            "raw": [
                "stages": ["deep": deep, "rem": rem, "core": core, "unspecified": unspecified, "awake": awake],
                "source": source,
            ] as [String: Any],
        ]
    }
}

public enum PaiSleepNights {
    /// Asleep samples less than this apart belong to one night.
    public static let joinGap: TimeInterval = 60 * 60
    /// Shorter sessions are naps: never sent, so a nap can't replace the night the box keys by the same start date.
    public static let minimumSession: TimeInterval = 2 * 60 * 60
    public static let backfill: TimeInterval = 14 * 24 * 60 * 60
    /// Every session sharing a start date with one that ends after the anchor ends within this of it.
    public static let lookback: TimeInterval = 36 * 60 * 60

    /// Nights from raw samples. Asleep stages (core, deep, REM, unspecified) make a night; in-bed time counts only
    /// where nothing asleep was recorded (a phone with no watch). Overlapping sources (a watch and a sleep app) are not
    /// added up: each night takes the source with the most asleep minutes in it.
    public static func sessions(_ samples: [PaiSleepSample]) -> [PaiSleepSession] {
        let asleep = samples.filter { $0.stage.isAsleep }
        var clusters = cluster(asleep)
        let inBedOnly = cluster(samples.filter { $0.stage == .inBed }).filter { group in
            !clusters.contains { overlaps(span(group), span($0)) }
        }
        clusters += inBedOnly
        return clusters.compactMap { session(from: $0, all: samples) }.sorted { $0.start < $1.start }
    }

    /// The nights to post: per local start date (the box's idempotency key) only the longest, only ones ending after
    /// `anchor` and settled (no asleep sample could still join them), oldest first.
    public static func toUpload(_ sessions: [PaiSleepSession], anchor: Date, now: Date, calendar: Calendar = .current) -> [PaiSleepSession] {
        var longest: [DateComponents: PaiSleepSession] = [:]
        for session in sessions where session.duration >= minimumSession {
            let day = calendar.dateComponents([.year, .month, .day], from: session.start)
            if let have = longest[day], have.duration >= session.duration { continue }
            longest[day] = session
        }
        return longest.values
            .filter { $0.end > anchor && $0.end <= now.addingTimeInterval(-joinGap) }
            .sorted { $0.start < $1.start }
    }

    /// Where the HealthKit query starts for a given anchor (the end of the last night sent, nil before the first run).
    public static func queryStart(anchor: Date?, now: Date) -> (anchor: Date, from: Date) {
        let anchor = anchor ?? now.addingTimeInterval(-backfill)
        return (anchor, anchor.addingTimeInterval(-lookback))
    }

    static func cluster(_ samples: [PaiSleepSample]) -> [[PaiSleepSample]] {
        var groups: [[PaiSleepSample]] = []
        var end = Date.distantPast
        for sample in samples.sorted(by: { $0.start < $1.start }) {
            if !groups.isEmpty, sample.start.timeIntervalSince(end) < joinGap {
                groups[groups.count - 1].append(sample)
                end = max(end, sample.end)
            } else {
                groups.append([sample])
                end = sample.end
            }
        }
        return groups
    }

    static func session(from group: [PaiSleepSample], all: [PaiSleepSample]) -> PaiSleepSession? {
        var bySource: [String: Double] = [:]
        for sample in group { bySource[sample.source, default: 0] += sample.minutes }
        guard let source = bySource.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value })?.key else { return nil }
        let own = group.filter { $0.source == source }
        guard let start = own.map(\.start).min(), let end = own.map(\.end).max(), end > start else { return nil }
        func total(_ stage: PaiSleepSample.Stage) -> Int { Int(own.filter { $0.stage == stage }.reduce(0) { $0 + $1.minutes }.rounded()) }
        let awake = all.filter { $0.stage == .awake && $0.source == source && $0.start >= start && $0.end <= end }
        return PaiSleepSession(
            start: start,
            end: end,
            deep: total(.deep),
            rem: total(.rem),
            core: total(.core),
            unspecified: total(.unspecified),
            awake: Int(awake.reduce(0) { $0 + $1.minutes }.rounded()),
            source: source
        )
    }

    static func span(_ group: [PaiSleepSample]) -> (Date, Date) {
        (group.map(\.start).min() ?? .distantPast, group.map(\.end).max() ?? .distantPast)
    }

    static func overlaps(_ a: (Date, Date), _ b: (Date, Date)) -> Bool { a.0 < b.1 && b.0 < a.1 }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}
