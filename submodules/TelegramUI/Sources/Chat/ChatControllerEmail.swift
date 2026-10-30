import Foundation
import TelegramCore
import ChatPresentationInterfaceState
import ChatTitleView
import PaiUI

/// An email chat's title says who it is with: the correspondent's address where a user's "last seen" would be.
func emailTitleContent(_ interfaceState: ChatPresentationInterfaceState, base: ChatTitleContent) -> ChatTitleContent? {
    guard case let .peer(peerView, customTitle, _, onlineMemberCount, isScheduledMessages, isMuted, customMessageCount, hidePeerStatus, isEnabled) = base, let subtitle = EmailChats.subtitle(peerId: peerView.peerId) else {
        return nil
    }
    return .peer(peerView: peerView, customTitle: customTitle, customSubtitle: subtitle, onlineMemberCount: onlineMemberCount, isScheduledMessages: isScheduledMessages, isMuted: isMuted, customMessageCount: customMessageCount, hidePeerStatus: hidePeerStatus, isEnabled: isEnabled)
}
