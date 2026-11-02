import Foundation
import Postbox

/// Message ids in a box chat (email, WhatsApp) follow the date: minutes since 2000, with 64 slots a minute (all an
/// Int32 holds for the next decades). History holes are id ranges, so this is what lets a hole stand for "messages
/// before this date". A minute already full spills into the following ones: the order of messages is their
/// timestamp's, so only a hole's edge moves by a minute.
enum BoxMessageIds {
    private static let epoch: Int64 = 946_684_800
    private static let slots: Int64 = 64
    /// How far a busy minute may spill: eight minutes of a group's burst.
    private static let spill: Int32 = 512

    static func base(date: Int64) -> Int32 {
        let minutes = max(1, (date / 1000 - self.epoch) / 60)
        return Int32(clamping: minutes * self.slots)
    }

    /// The first date after every message an id up to `id` can have; nil for the top of the range (no limit).
    static func dateAfter(id: Int32) -> Int64? {
        if id >= Int32.max - 1 {
            return nil
        }
        return ((Int64(id) / self.slots + 1) * 60 + self.epoch) * 1000
    }

    /// A stable 64-bit id for a message's key on the box (FNV-1a): every copy of it is found by this.
    static func globallyUniqueId(key: String) -> Int64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int64(bitPattern: hash)
    }

    /// A free id for a message of `date`, or the one it already has.
    static func id(transaction: Transaction, peerId: PeerId, date: Int64, globallyUniqueId: Int64) -> MessageId {
        if let existing = transaction.messageIdForGloballyUniqueMessageId(peerId: peerId, id: globallyUniqueId) {
            return existing
        }
        let base = self.base(date: date)
        for offset in 0 ..< self.spill {
            let id = MessageId(peerId: peerId, namespace: Namespaces.Message.Box, id: base &+ offset)
            if transaction.getMessage(id) == nil {
                return id
            }
        }
        Logger.shared.log("Box", "no free id near \(date) in \(peerId)")
        return MessageId(peerId: peerId, namespace: Namespaces.Message.Box, id: base &+ self.spill - 1)
    }
}
