import Foundation

/// JSON snapshots in `Caches/pai`, read and written on one background queue so a big list never stalls launch
/// or a screen's first frame. A value still in UserDefaults under its old key moves to its file on first read.
enum PaiCache {
    private static let queue = DispatchQueue(label: "pai.cache", qos: .userInitiated)

    private static let directory: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("pai", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static func url(_ name: String) -> URL {
        directory.appendingPathComponent((name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name) + ".json")
    }

    /// Only on `queue`, so a read never overtakes a pending write.
    private static func read<T: Decodable>(_ type: T.Type, _ name: String, legacyKey: String?) -> T? {
        let file = url(name)
        if let data = try? Data(contentsOf: file) {
            return try? JSONDecoder().decode(T.self, from: data)
        }
        guard let legacyKey, let data = UserDefaults.standard.data(forKey: legacyKey) else { return nil }
        try? data.write(to: file, options: .atomic)
        UserDefaults.standard.removeObject(forKey: legacyKey)
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Blocks the caller; for values read from any queue that are small or already preloaded. Never call it on `queue`.
    static func readNow<T: Decodable>(_ type: T.Type, _ name: String, legacyKey: String? = nil) -> T? {
        queue.sync { read(type, name, legacyKey: legacyKey) }
    }

    /// Reads off the caller's thread.
    static func load<T: Decodable>(_ type: T.Type, _ name: String, legacyKey: String? = nil) async -> T? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: read(type, name, legacyKey: legacyKey)) }
        }
    }

    /// Encodes and writes in the background.
    static func save<T: Encodable>(_ value: T, _ name: String) {
        queue.async {
            guard let data = try? JSONEncoder().encode(value) else { return }
            try? data.write(to: url(name), options: .atomic)
        }
    }
}

/// One cached value readable from any queue: read from its file the first time it is asked for, kept in memory
/// after that, written back whenever it changes.
final class PaiCachedValue<T: Codable & Equatable> {
    private let lock = NSLock()
    private let name: String
    private let legacyKey: String?
    private let empty: T
    private var value: T?

    init(_ name: String, legacyKey: String? = nil, empty: T) {
        self.name = name
        self.legacyKey = legacyKey
        self.empty = empty
    }

    var current: T {
        lock.lock()
        defer { lock.unlock() }
        if let value { return value }
        let read = PaiCache.readNow(T.self, name, legacyKey: legacyKey) ?? empty
        value = read
        return read
    }

    /// Whether the value changed.
    @discardableResult
    func set(_ newValue: T) -> Bool {
        lock.lock()
        let changed = value != newValue
        value = newValue
        lock.unlock()
        if changed { PaiCache.save(newValue, name) }
        return changed
    }
}
