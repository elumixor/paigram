import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore

/// An agent's topic shows what is addressed to the user: his own messages, each turn's final text, asks and cards.
/// Everything a run did on the way (progress notes, interim texts, idle status records, events) folds into one
/// service row, "6 steps", that the history builder adds after the run; a tap opens the run in place.
public enum PaiRunFold {
    public struct Row: Equatable {
        /// The run's first hidden message: what stays expanded across history updates.
        public let runKey: MessageId
        public let count: Int
        public let expanded: Bool

        public init(runKey: MessageId, count: Int, expanded: Bool) {
            self.runKey = runKey
            self.count = count
            self.expanded = expanded
        }
    }

    public enum Role {
        case shown
        case folded
        /// A chunk of a split message without its own trailer: it is whatever the next bot message is.
        case continuation
    }

    private static let lock = NSLock()
    private static var rows: [UInt32: Row] = [:]
    private static var expandedRuns = Set<MessageId>()

    /// Bumped on every toggle so the history rebuilds and the list animates the run in or out.
    public static let version = ValuePromise<Int>(0, ignoreRepeated: false)
    private static var counter = 0

    public static func role(_ message: Message) -> Role {
        if message.isPaiEcho || !message.flags.contains(.Incoming) {
            return .shown
        }
        let text = message.text
        guard let meta = PaiTrailer.find(message)?.meta else {
            return text.hasPrefix("🔴") ? .shown : .continuation
        }
        switch meta.kind {
        case "turn", "result":
            if meta.durationMs != nil || meta.logId != nil || message.id.namespace == Namespaces.Message.Box || text.hasPrefix("🔴") {
                return .shown
            }
            return .folded
        case "status":
            return meta.isBusy || meta.isWaiting ? .shown : .folded
        case "event", "events":
            return .folded
        default:
            return .shown
        }
    }

    public static func isExpanded(_ runKey: MessageId) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return expandedRuns.contains(runKey)
    }

    /// The rows the history builder made, keyed by their synthetic message's stable id.
    public static func register(stableId: UInt32, row: Row) {
        lock.lock()
        defer { lock.unlock() }
        rows[stableId] = row
    }

    public static func row(_ message: Message) -> Row? {
        guard message.flags.contains(.Incoming) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let row = rows[message.stableId], row.count == Int(message.stableVersion >> 1) else { return nil }
        return Row(runKey: row.runKey, count: row.count, expanded: message.stableVersion & 1 == 1)
    }

    public static func toggle(_ runKey: MessageId) {
        lock.lock()
        if expandedRuns.contains(runKey) { expandedRuns.remove(runKey) } else { expandedRuns.insert(runKey) }
        counter += 1
        let value = counter
        lock.unlock()
        version.set(value)
    }

    public static func label(_ count: Int) -> String {
        count == 1 ? "1 step" : "\(count) steps"
    }
}
