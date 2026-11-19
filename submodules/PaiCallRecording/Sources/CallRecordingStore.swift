import Foundation

/// One directory per recorded call, `<root>/<callId>/` holding `meta.json`, `mic.m4a` and `remote.m4a`. It outlives the
/// app process: a finished recording stays here until pai confirms it is stored (or refuses it for good).
public final class CallRecordingStore: @unchecked Sendable {
    public static let metaFileName = "meta.json"
    public static let micFileName = "mic.m4a"
    public static let remoteFileName = "remote.m4a"

    public static let shared: CallRecordingStore = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return CallRecordingStore(root: base.appendingPathComponent("PaiCallRecordings", isDirectory: true))
    }()

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func directory(_ callId: String) -> URL {
        return root.appendingPathComponent(callId, isDirectory: true)
    }

    public func micURL(_ callId: String) -> URL {
        return directory(callId).appendingPathComponent(CallRecordingStore.micFileName)
    }

    public func remoteURL(_ callId: String) -> URL {
        return directory(callId).appendingPathComponent(CallRecordingStore.remoteFileName)
    }

    public func create(_ meta: CallRecordingMeta) throws {
        let directory = self.directory(meta.callId)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try writeMeta(meta)
    }

    public func writeMeta(_ meta: CallRecordingMeta) throws {
        try meta.encoded().write(to: directory(meta.callId).appendingPathComponent(CallRecordingStore.metaFileName), options: .atomic)
    }

    public func meta(_ callId: String) -> CallRecordingMeta? {
        guard let data = try? Data(contentsOf: directory(callId).appendingPathComponent(CallRecordingStore.metaFileName)) else { return nil }
        return try? JSONDecoder().decode(CallRecordingMeta.self, from: data)
    }

    /// Finished recordings waiting for upload, oldest first.
    public func pending() -> [CallRecordingMeta] {
        return all().filter { $0.endedAt != nil }.sorted { $0.startedAt < $1.startedAt }
    }

    /// Recordings that never finished (the app died mid-call) and are older than `age`: their m4a was never closed.
    public func abandoned(olderThan age: TimeInterval, now: Date = Date()) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.filter { name in
            if let meta = meta(name), meta.endedAt != nil { return false }
            let attributes = try? FileManager.default.attributesOfItem(atPath: directory(name).path)
            let modified = attributes?[.modificationDate] as? Date ?? .distantPast
            return now.timeIntervalSince(modified) > age
        }
    }

    public func delete(_ callId: String) {
        try? FileManager.default.removeItem(at: directory(callId))
    }

    private func all() -> [CallRecordingMeta] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.compactMap { meta($0) }
    }
}
