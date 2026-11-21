import XCTest
import LocalAudioTranscription

final class VoiceSegmentSweepTests: XCTestCase {
    func testDeletesOnlyStaleVoiceSegments() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("voice-sweep-\(UUID().uuidString)")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }
        let now = Date()
        func make(_ name: String, age: TimeInterval) -> URL {
            let url = directory.appendingPathComponent(name)
            fileManager.createFile(atPath: url.path, contents: Data([0]))
            try? fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
            return url
        }
        let stale = make(voiceSegmentFilePrefix + "1.caf", age: 2 * 3600.0)
        let fresh = make(voiceSegmentFilePrefix + "2.caf", age: 60.0)
        let other = make("audio.caf", age: 2 * 3600.0)

        sweepStaleVoiceSegments(in: directory, maxAge: 3600.0, now: now)

        XCTAssertFalse(fileManager.fileExists(atPath: stale.path))
        XCTAssertTrue(fileManager.fileExists(atPath: fresh.path))
        XCTAssertTrue(fileManager.fileExists(atPath: other.path))
    }
}
