import XCTest
@testable import OngoingCallVersionPolicy

final class OngoingCallVersionPolicyTests: XCTestCase {
    // The versions the 26 Nov 2026 failing call advertised; the server answered with [14.0.0] while
    // the peer ran 8.0.0, and no signaling crossed.
    private let registered = ["10.0.0", "11.0.0", "12.0.0", "13.0.0", "14.0.0", "2.7.7", "5.0.0", "7.0.0", "8.0.0", "9.0.0"]

    func testDoesNotAdvertise14() {
        XCTAssertFalse(OngoingCallVersionPolicy.advertisedVersions(registered).contains("14.0.0"))
    }

    func testKeepsInteroperableVersionsInOrder() {
        XCTAssertEqual(
            OngoingCallVersionPolicy.advertisedVersions(registered),
            ["10.0.0", "11.0.0", "12.0.0", "13.0.0", "2.7.7", "5.0.0", "7.0.0", "8.0.0", "9.0.0"]
        )
    }
}
