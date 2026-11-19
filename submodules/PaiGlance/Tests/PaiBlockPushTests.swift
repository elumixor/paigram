import XCTest
@testable import PaiGlance

final class PaiBlockPushTests: XCTestCase {
    private let blockHash = "0123456789abcdef0123456789abcdef"

    func testHashesKeepsValidInOrder() {
        let other = String(repeating: "f", count: 32)
        XCTAssertEqual(PaiBlockPush.hashes(["paiBlocks": [blockHash, other]]), [blockHash, other])
    }

    func testHashesDropsMalformed() {
        let userInfo: [AnyHashable: Any] = ["paiBlocks": [blockHash.uppercased(), "abc", 42, blockHash + "0", blockHash]]
        XCTAssertEqual(PaiBlockPush.hashes(userInfo), [blockHash])
    }

    func testHashesMissingOrWrongShape() {
        XCTAssertEqual(PaiBlockPush.hashes([:]), [])
        XCTAssertEqual(PaiBlockPush.hashes(["paiBlocks": blockHash]), [])
    }

    func testURL() {
        XCTAssertEqual(PaiBlockPush.url(baseURL: "https://box.example.com", hash: blockHash)?.absoluteString, "https://box.example.com/blocks/\(blockHash).png")
        XCTAssertEqual(PaiBlockPush.url(baseURL: "https://box.example.com/", hash: blockHash)?.absoluteString, "https://box.example.com/blocks/\(blockHash).png")
        XCTAssertEqual(PaiBlockPush.url(baseURL: "https://box.example.com/pai/", hash: blockHash)?.absoluteString, "https://box.example.com/pai/blocks/\(blockHash).png")
    }

    func testURLRejectsBadInput() {
        XCTAssertNil(PaiBlockPush.url(baseURL: "https://box.example.com", hash: "../etc"))
        XCTAssertNil(PaiBlockPush.url(baseURL: "", hash: blockHash))
        XCTAssertNil(PaiBlockPush.url(baseURL: "box.example.com", hash: blockHash))
    }
}
