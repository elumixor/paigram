import XCTest
@testable import TextFormat

final class CodeBlockCopyButtonTests: XCTestCase {
    func testButtonSizeIsIconSpacingAndLabel() {
        let size = CodeBlockCopyButtonLayout.buttonSize(labelSize: CGSize(width: 30.2, height: 16.4))
        XCTAssertEqual(size.width, ceil(14.0 + 3.0 + 30.2))
        XCTAssertEqual(size.height, 17.0)
    }

    func testReservedHeaderWidthAddsTitleSpacing() {
        XCTAssertEqual(CodeBlockCopyButtonLayout.reservedHeaderWidth(buttonSize: CGSize(width: 50.0, height: 16.0)), 58.0)
    }

    func testButtonFrameSitsAtTopTrailingCorner() {
        let block = CGRect(x: 10.0, y: 20.0, width: 200.0, height: 100.0)
        let frame = CodeBlockCopyButtonLayout.buttonFrame(blockFrame: block, buttonSize: CGSize(width: 50.0, height: 16.0))
        XCTAssertEqual(frame, CGRect(x: 156.0, y: 24.0, width: 50.0, height: 16.0))
    }

    func testHitRectIsAtLeast44TallInTallBlock() {
        let block = CGRect(x: 0.0, y: 0.0, width: 200.0, height: 100.0)
        let hit = CodeBlockCopyButtonLayout.hitRect(blockFrame: block, buttonSize: CGSize(width: 50.0, height: 16.0))
        XCTAssertGreaterThanOrEqual(hit.height, 44.0 - 14.0) // top part clipped by block edge
        XCTAssertGreaterThanOrEqual(hit.maxY, 4.0 + 8.0 + 30.0)
        XCTAssertGreaterThanOrEqual(hit.width, 50.0)
    }

    func testHitRectIsClippedToBlock() {
        let block = CGRect(x: 0.0, y: 0.0, width: 60.0, height: 24.0)
        let hit = CodeBlockCopyButtonLayout.hitRect(blockFrame: block, buttonSize: CGSize(width: 50.0, height: 16.0))
        XCTAssertTrue(block.contains(hit))
        XCTAssertEqual(hit, block)
    }

    func testPointOutsideBlockMisses() {
        let block = CGRect(x: 0.0, y: 0.0, width: 200.0, height: 100.0)
        let hit = CodeBlockCopyButtonLayout.hitRect(blockFrame: block, buttonSize: CGSize(width: 50.0, height: 16.0))
        XCTAssertFalse(hit.contains(CGPoint(x: 210.0, y: 10.0)))
        XCTAssertFalse(hit.contains(CGPoint(x: 20.0, y: 80.0)))
        XCTAssertTrue(hit.contains(CGPoint(x: 180.0, y: 12.0)))
    }
}
