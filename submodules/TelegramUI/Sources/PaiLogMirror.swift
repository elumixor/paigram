import Foundation

/// Paigram: copies the recent app and call logs into the app group's `Library/Caches/pai-logs`, the only part of the
/// group container `devicectl device copy from` can read, so a failed call can be diagnosed from the Mac.
enum PaiLogMirror {
    private static let queue = DispatchQueue(label: "org.paigram.log-mirror", qos: .utility)
    private static let maxAge: TimeInterval = 3 * 24 * 60 * 60

    static func mirror(rootPath: String) {
        queue.async {
            let fileManager = FileManager.default
            let rootUrl = URL(fileURLWithPath: rootPath)
            let destination = rootUrl.deletingLastPathComponent().appendingPathComponent("Library/Caches/pai-logs")
            try? fileManager.removeItem(at: destination)
            try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

            var sources: [(URL, String)] = [(rootUrl.appendingPathComponent("logs/app-logs"), "app")]
            if let entries = try? fileManager.contentsOfDirectory(at: rootUrl, includingPropertiesForKeys: nil) {
                for entry in entries where entry.lastPathComponent.hasPrefix("account-") {
                    sources.append((entry.appendingPathComponent("calls"), "calls-\(entry.lastPathComponent)"))
                }
            }
            let cutoff = Date().addingTimeInterval(-maxAge)
            for (directory, name) in sources {
                guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
                    continue
                }
                let target = destination.appendingPathComponent(name)
                try? fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                for file in files {
                    let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    if modified >= cutoff {
                        try? fileManager.copyItem(at: file, to: target.appendingPathComponent(file.lastPathComponent))
                    }
                }
            }
        }
    }
}
