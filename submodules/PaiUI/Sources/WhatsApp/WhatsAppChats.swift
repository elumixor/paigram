import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore

/// The app's half of the WhatsApp chats (TelegramCore holds the rest): the people's numbers at hand for titles, and
/// a sync whenever the app comes back or a WhatsApp push arrives.
public enum WhatsAppChats {
    private static let state = Atomic<WhatsAppState>(value: .empty)
    private static var engine: TelegramEngine?
    private static let stateDisposable = MetaDisposable()
    private static var activeObserver: NSObjectProtocol?
    
    /// The account whose chats sync now: its state is followed, and each return to the app syncs.
    public static func attach(engine: TelegramEngine?) {
        self.engine = engine
        self.stateDisposable.set(engine?.whatsApp.state().start(next: { value in
            let _ = self.state.swap(value)
        }))
        if self.activeObserver == nil {
            self.activeObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main, using: { _ in
                self.syncNow()
            })
        }
    }
    
    public static func syncNow() {
        self.engine?.whatsApp.syncNow()
    }
    
    /// Under a WhatsApp DM's title: the person's number; a group shows its member count as any group does.
    public static func subtitle(peerId: EnginePeer.Id) -> String? {
        guard peerId.isWhatsApp, !peerId.isWhatsAppGroup else {
            return nil
        }
        return self.state.with { $0.phone(person: peerId.id._internalGetInt64Value()) }.map { "+\($0) · WhatsApp" } ?? "WhatsApp"
    }
    
    /// Whether a notification is one of the box's WhatsApp pushes.
    public static func isWhatsAppPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        return userInfo["whatsapp"] != nil
    }
}
