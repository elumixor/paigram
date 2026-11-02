import Foundation
import Postbox

/// Which WhatsApp message a message in a WhatsApp chat is: what a reply names it by.
public final class WhatsAppMessageAttribute: MessageAttribute {
    /// WhatsApp's id of the message; empty while a sent one is on its way.
    public let waId: String

    public let associatedPeerIds: [PeerId] = []

    public init(waId: String) {
        self.waId = waId
    }

    required public init(decoder: PostboxDecoder) {
        self.waId = decoder.decodeStringForKey("w", orElse: "")
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeString(self.waId, forKey: "w")
    }
}
