import Foundation
import Postbox
import SwiftSignalKit

public extension TelegramEngine {
    /// pai's agents on this device: each a local user peer for its profile (portrait, name, role); its chat is its forum
    /// topic of the pai bot, whose history from before the topic comes from pai's log (`PaiTopicHistory.swift`).
    final class PaiAgents {
        private let account: Account

        init(account: Account) {
            self.account = account
        }

        /// The agents the app read from pai (`/agents`) and the pai bot's peer, once known.
        public func update(agents: [PaiAgentInfo], botPeerId: EnginePeer.Id?) -> Signal<Never, NoError> {
            return updatePaiAgents(postbox: self.account.postbox, agents: agents, botPeerId: botPeerId) |> ignoreValues
        }

        public func peerId(slug: String) -> EnginePeer.Id {
            return paiAgentPeerId(slug: slug)
        }
    }
}
