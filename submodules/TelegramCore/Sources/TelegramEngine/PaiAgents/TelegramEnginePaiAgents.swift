import Foundation
import Postbox
import SwiftSignalKit

public extension TelegramEngine {
    /// Paigram's agent chats: pai's agents as local user peers under the pai row, each chat pai's message log.
    final class PaiAgents {
        private let account: Account

        init(account: Account) {
            self.account = account
        }

        /// The agents the app read from pai (`/agents`): their peers made or updated, chats of new ones started.
        public func update(agents: [PaiAgentInfo]) -> Signal<Never, NoError> {
            return updatePaiAgents(postbox: self.account.postbox, agents: agents) |> ignoreValues
        }

        /// Reads the message log now (the app came to the front).
        public func syncNow() {
            PaiAgentsSync.request()
        }

        public func peerId(slug: String) -> EnginePeer.Id {
            return paiAgentPeerId(slug: slug)
        }

        public func state() -> Signal<PaiAgentsState, NoError> {
            return self.account.postbox.preferencesView(keys: [PreferencesKeys.paiAgentsState])
            |> map { view -> PaiAgentsState in
                return view.values[PreferencesKeys.paiAgentsState]?.get(PaiAgentsState.self) ?? .empty
            }
            |> distinctUntilChanged
        }

        public func agent(peerId: EnginePeer.Id) -> Signal<PaiAgentInfo?, NoError> {
            return self.state() |> map { $0.agent(peerId: peerId) } |> distinctUntilChanged
        }
    }
}
