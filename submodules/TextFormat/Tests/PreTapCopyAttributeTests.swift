import XCTest
import UIKit
import TelegramCore
@testable import TextFormat

final class PreTapCopyAttributeTests: XCTestCase {
    private func render(_ text: String, entities: [MessageTextEntity]) -> NSAttributedString {
        let font = UIFont.systemFont(ofSize: 17.0)
        return stringWithAppliedEntities(text, entities: entities, baseColor: .black, linkColor: .blue, codeBlockTitleColor: .gray, codeBlockAccentColor: .blue, codeBlockBackgroundColor: .lightGray, codeBlockCopyTitle: "Copy", baseFont: font, linkFont: font, boldFont: font, italicFont: font, boldItalicFont: font, fixedFont: font, blockQuoteFont: font, message: nil)
    }

    // Tapping anywhere in a pre block copies its text: the bubble reads TelegramTextAttributes.Pre.
    func testPreEntityCarriesPreAttributeWithBlockText() {
        let text = "see\nlet x = 1\ndone"
        let preRange = (text as NSString).range(of: "let x = 1")
        let result = render(text, entities: [MessageTextEntity(range: preRange.location ..< preRange.location + preRange.length, type: .Pre(language: "swift"))])
        let value = result.attribute(NSAttributedString.Key(rawValue: TelegramTextAttributes.Pre), at: preRange.location + 2, effectiveRange: nil) as? String
        XCTAssertEqual(value, "let x = 1")
        XCTAssertNil(result.attribute(NSAttributedString.Key(rawValue: TelegramTextAttributes.Pre), at: 0, effectiveRange: nil))
    }

    func testPreWithoutLanguageCarriesPreAttribute() {
        let text = "a\nb"
        let result = render(text, entities: [MessageTextEntity(range: 0 ..< 3, type: .Pre(language: nil))])
        XCTAssertEqual(result.attribute(NSAttributedString.Key(rawValue: TelegramTextAttributes.Pre), at: 1, effectiveRange: nil) as? String, "a\nb")
    }
}
