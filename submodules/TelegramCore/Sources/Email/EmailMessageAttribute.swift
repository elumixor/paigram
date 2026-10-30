import Foundation
import Postbox

/// Which email a message in an email chat is: what a reply, a read mark or a trash names it by.
public final class EmailMessageAttribute: MessageAttribute {
    /// The box's mailbox label (`personal`, `atmagaming`, …).
    public let account: String
    /// Gmail's message id; empty while a sent message is on its way.
    public let gmailId: String
    public let threadId: String
    public let subject: String
    public let from: String
    public let to: [String]
    public let cc: [String]
    /// Only the snippet is known (the contact list's latest message): the chat's first page brings the text.
    public let isPartial: Bool
    
    public let associatedPeerIds: [PeerId] = []
    
    public init(account: String, gmailId: String, threadId: String, subject: String, from: String, to: [String], cc: [String], isPartial: Bool) {
        self.account = account
        self.gmailId = gmailId
        self.threadId = threadId
        self.subject = subject
        self.from = from
        self.to = to
        self.cc = cc
        self.isPartial = isPartial
    }
    
    required public init(decoder: PostboxDecoder) {
        self.account = decoder.decodeStringForKey("a", orElse: "")
        self.gmailId = decoder.decodeStringForKey("g", orElse: "")
        self.threadId = decoder.decodeStringForKey("t", orElse: "")
        self.subject = decoder.decodeStringForKey("s", orElse: "")
        self.from = decoder.decodeStringForKey("f", orElse: "")
        self.to = decoder.decodeStringArrayForKey("to")
        self.cc = decoder.decodeStringArrayForKey("cc")
        self.isPartial = decoder.decodeBoolForKey("p", orElse: false)
    }
    
    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeString(self.account, forKey: "a")
        encoder.encodeString(self.gmailId, forKey: "g")
        encoder.encodeString(self.threadId, forKey: "t")
        encoder.encodeString(self.subject, forKey: "s")
        encoder.encodeString(self.from, forKey: "f")
        encoder.encodeStringArray(self.to, forKey: "to")
        encoder.encodeStringArray(self.cc, forKey: "cc")
        encoder.encodeBool(self.isPartial, forKey: "p")
    }
}
