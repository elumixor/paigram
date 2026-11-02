import Foundation
import TelegramCore
import ChatPresentationInterfaceState
import ChatTitleView
import PaiUI

/// A box chat's title says who it is with: an email correspondent's address, a WhatsApp person's number, where a
/// user's "last seen" would be.
func boxTitleContent(_ interfaceState: ChatPresentationInterfaceState, base: ChatTitleContent) -> ChatTitleContent? {
    guard case let .peer(peerView, customTitle, _, onlineMemberCount, isScheduledMessages, isMuted, customMessageCount, hidePeerStatus, isEnabled) = base, let subtitle = EmailChats.subtitle(peerId: peerView.peerId) ?? WhatsAppChats.subtitle(peerId: peerView.peerId) else {
        return nil
    }
    return .peer(peerView: peerView, customTitle: customTitle, customSubtitle: subtitle, onlineMemberCount: onlineMemberCount, isScheduledMessages: isScheduledMessages, isMuted: isMuted, customMessageCount: customMessageCount, hidePeerStatus: hidePeerStatus, isEnabled: isEnabled)
}
