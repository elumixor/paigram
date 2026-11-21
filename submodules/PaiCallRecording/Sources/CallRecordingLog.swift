import Foundation
import os

/// Every step of a call recording (start, audio received, finish, upload status) goes here. The app points `sink` at
/// Telegram's `Logger` ("PaiCallRecording"), so a recording that never reached pai shows where it stopped.
public enum CallRecordingLog {
    public static var sink: ((String) -> Void)?

    private static let osLog = OSLog(subsystem: "org.paigram", category: "call-recording")

    public static func log(_ message: String) {
        os_log("%{public}@", log: osLog, type: .default, message)
        sink?(message)
    }
}

/// The "Transcribe calls" switch in pai's settings: on (the default) records every 1:1 call from the moment it connects.
public enum CallRecordingSettings {
    private static let key = "pai.transcribeCalls"

    public static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
