import Foundation
import XCTest
@testable import PaiCallRecording

final class CallKitOwnershipTests: XCTestCase {
    /// An idle app must not hold Pai's provider, or Telegram's outgoing call can land on it and never connect.
    func testNoAgentProviderWhileIdle() {
        XCTAssertFalse(CallKitOwnership.agentProviderNeeded(agentCallActive: false, callKitAvailable: true))
        XCTAssertFalse(CallKitOwnership.agentProviderNeeded(agentCallActive: true, callKitAvailable: false))
        XCTAssertTrue(CallKitOwnership.agentProviderNeeded(agentCallActive: true, callKitAvailable: true))
    }

    /// A Telegram call's start action reaching Pai's provider is not Pai's to fulfill.
    func testTelegramActionIsNotOwnedByAgent() {
        let agentCall = UUID()
        XCTAssertFalse(CallKitOwnership.agentOwnsAction(actionCallUUID: UUID(), agentCallUUID: nil))
        XCTAssertFalse(CallKitOwnership.agentOwnsAction(actionCallUUID: UUID(), agentCallUUID: agentCall))
        XCTAssertTrue(CallKitOwnership.agentOwnsAction(actionCallUUID: agentCall, agentCallUUID: agentCall))
    }
}
