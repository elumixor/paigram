import Foundation
import Postbox

public extension PeerId {
    /// A chat that lives on the box rather than on Telegram's servers: email, WhatsApp or a pai agent.
    var isBridged: Bool {
        return self.isEmail || self.isWhatsApp || self.isPaiAgent
    }
}
