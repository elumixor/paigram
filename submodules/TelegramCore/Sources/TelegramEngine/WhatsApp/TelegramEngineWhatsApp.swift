import Foundation
import Postbox
import SwiftSignalKit

public extension TelegramEngine {
    /// Paigram's WhatsApp chats: the box's people and groups as peers in the `WhatsApp` and `WhatsAppGroup` namespaces.
    final class WhatsApp {
        private let account: Account
        
        init(account: Account) {
            self.account = account
        }
        
        /// Reads the box's changes now (a push arrived, the app came to the front).
        public func syncNow() {
            requestWhatsAppSync()
        }
        
        public func state() -> Signal<WhatsAppState, NoError> {
            return self.account.postbox.preferencesView(keys: [PreferencesKeys.whatsAppState])
            |> map { view -> WhatsAppState in
                return view.values[PreferencesKeys.whatsAppState]?.get(WhatsAppState.self) ?? .empty
            }
            |> distinctUntilChanged
        }
    }
}
