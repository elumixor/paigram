import Foundation
import Postbox

private let linkDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

/// The addresses in a box message's plain text, made tappable: web links, and mail addresses as such.
func boxLinkEntities(in text: String) -> [MessageTextEntity] {
    let range = NSRange(location: 0, length: (text as NSString).length)
    return linkDetector.matches(in: text, range: range).compactMap { match in
        guard let url = match.url else {
            return nil
        }
        let type: MessageTextEntityType = url.scheme == "mailto" ? .Email : .Url
        return MessageTextEntity(range: match.range.location ..< match.range.location + match.range.length, type: type)
    }
}

private func isLink(_ entity: MessageTextEntity) -> Bool {
    switch entity.type {
    case .Url, .TextUrl, .Email:
        return true
    default:
        return false
    }
}

/// Spans the box drew, plus the links it left as plain text; a found link never overlaps one already drawn.
func withBoxLinks(_ drawn: [MessageTextEntity], text: String) -> [MessageTextEntity] {
    let linked = drawn.filter(isLink).map(\.range)
    return drawn + boxLinkEntities(in: text).filter { found in
        !linked.contains(where: { $0.overlaps(found.range) })
    }
}
