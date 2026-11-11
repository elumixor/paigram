import Foundation

/// The glance and the box's credentials on disk, in a directory every surface of one device reads: the app
/// group on the phone (app, widget, notification extension), the app's own container on the watch.
public struct PaiGlanceStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The phone's app group, `group.<app bundle id>`, from the app or any of its extensions.
    public static func appGroup(bundleId: String? = Bundle.main.bundleIdentifier) -> PaiGlanceStore? {
        guard var id = bundleId else { return nil }
        if Bundle.main.bundleURL.pathExtension == "appex", let dot = id.lastIndex(of: ".") {
            id = String(id[..<dot])
        }
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.\(id)") else { return nil }
        return PaiGlanceStore(directory: url)
    }

    /// The watch's own store.
    public static var local: PaiGlanceStore {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("pai", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return PaiGlanceStore(directory: url)
    }

    private var configURL: URL { directory.appendingPathComponent("pai.json") }
    private var glanceURL: URL { directory.appendingPathComponent("pai-glance.json") }
    private var alertsURL: URL { directory.appendingPathComponent("pai-usage-alerts.json") }

    /// `pai.json`, which the app writes (and removes on sign-out).
    public var config: PaiGlanceConfig? {
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        return try? JSONDecoder().decode(PaiGlanceConfig.self, from: data)
    }

    /// Only for the watch, whose config comes from the phone. On the phone the app owns `pai.json`.
    public func saveConfig(_ config: PaiGlanceConfig?) {
        guard let config else {
            try? FileManager.default.removeItem(at: configURL)
            return
        }
        write(config, to: configURL)
    }

    /// The last glance any surface fetched.
    public var glance: PaiGlance? {
        guard let data = try? Data(contentsOf: glanceURL) else { return nil }
        return try? Self.decoder.decode(PaiGlance.self, from: data)
    }

    public func saveGlance(_ glance: PaiGlance) {
        write(glance, to: glanceURL)
    }

    public var source: PaiGlanceSource? {
        config.map { PaiGlanceLiveSource(config: $0) }
    }

    // MARK: - Usage alerts

    /// The levels a usage window alerts at.
    public static let thresholds: [Double] = [50, 80, 100]

    public struct Crossing: Equatable {
        public let window: String
        public let threshold: Int
        public let percent: Double
        public let resetsAt: Date?

        public var title: String {
            threshold >= 100 ? "\(window) limit reached" : "\(window) usage at \(threshold)%"
        }

        public var body: String {
            var text = "\(Int(percent.rounded()))% of the \(window.lowercased()) window used"
            if let resetsAt {
                let window = PaiGlance.Window(name: window, percent: percent, resetsAt: resetsAt)
                if let left = window.resetsIn() { text += ", resets in \(left)" }
            }
            return text + "."
        }

        /// One alert per window, level and reset: the notification identifier dedupes it with the box's push too.
        public var identifier: String {
            "pai.usage.\(window).\(threshold).\(Int(resetsAt?.timeIntervalSince1970 ?? 0) / 600)"
        }
    }

    /// The highest level each window newly crossed since the last call, remembered so it alerts once per window
    /// reset. A first call only records where usage is, so installing or signing in does not alert.
    public func crossings(in glance: PaiGlance) -> [Crossing] {
        var seen = (try? Data(contentsOf: alertsURL)).flatMap { try? JSONDecoder().decode([String: Mark].self, from: $0) }
        let firstRun = seen == nil
        var marks = seen ?? [:]
        var result: [Crossing] = []
        for window in glance.windows where window.name == "Session" || window.name == "Weekly" {
            let reset = Int(window.resetsAt?.timeIntervalSince1970 ?? 0) / 600
            let level = Self.thresholds.last { window.percent >= $0 }.map(Int.init) ?? 0
            let previous = marks[window.name].flatMap { $0.reset == reset ? $0.level : nil } ?? 0
            if level > previous {
                marks[window.name] = Mark(reset: reset, level: level)
                if !firstRun {
                    result.append(Crossing(window: window.name, threshold: level, percent: window.percent, resetsAt: window.resetsAt))
                }
            } else if marks[window.name]?.reset != reset {
                marks[window.name] = Mark(reset: reset, level: level)
            }
        }
        seen = marks
        write(seen, to: alertsURL)
        return result
    }

    private struct Mark: Codable {
        let reset: Int
        let level: Int
    }

    // MARK: -

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    public static func encode(_ glance: PaiGlance) -> Data? {
        try? encoder.encode(glance)
    }

    public static func decode(_ data: Data) -> PaiGlance? {
        try? decoder.decode(PaiGlance.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? Self.encoder.encode(value) else { return }
        #if os(iOS)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: url, options: .atomic)
        #endif
    }
}
