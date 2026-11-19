import XCTest
@testable import PaiGlance

final class PaiBlockPushTests: XCTestCase {
    private let hash = "0123456789abcdef0123456789abcdef"

    func testHashesKeepsValidInOrder() {
        let other = String(repeating: "f", count: 32)
        XCTAssertEqual(PaiBlockPush.hashes(["paiBlocks": [hash, other]]), [hash, other])
    }

    func testHashesDropsMalformed() {
        let userInfo: [AnyHashable: Any] = ["paiBlocks": [hash.uppercased(), "abc", 42, hash + "0", hash]]
        XCTAssertEqual(PaiBlockPush.hashes(userInfo), [hash])
    }

    func testHashesMissingOrWrongShape() {
        XCTAssertEqual(PaiBlockPush.hashes([:]), [])
        XCTAssertEqual(PaiBlockPush.hashes(["paiBlocks": hash]), [])
    }

    func testURL() {
        XCTAssertEqual(PaiBlockPush.url(baseURL: "https://box.example.com", hash: hash)?.absoluteString, "https://box.example.com/blocks/\(hash).png")
        XCTAssertEqual(PaiBlockPush.url(baseURL: "https://box.example.com/", hash: hash)?.absoluteString, "https://box.example.com/blocks/\(hash).png")
        XCTAssertEqual(PaiBlockPush.url(baseURL: "https://box.example.com/pai/", hash: hash)?.absoluteString, "https://box.example.com/pai/blocks/\(hash).png")
    }

    func testURLRejectsBadInput() {
        XCTAssertNil(PaiBlockPush.url(baseURL: "https://box.example.com", hash: "../etc"))
        XCTAssertNil(PaiBlockPush.url(baseURL: "", hash: hash))
        XCTAssertNil(PaiBlockPush.url(baseURL: "box.example.com", hash: hash))
    }
}
