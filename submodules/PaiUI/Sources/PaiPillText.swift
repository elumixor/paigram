import Foundation
import SwiftSignalKit
import UIKit
import Display
import TelegramCore

/// Pills in a chat bubble: the text holds each one as `nbsp title · meta nbsp` with the record's link, kerned so the
/// spaces leave room for the mark and status; the bubble draws the capsule, mark and status under those ranges.
extension PaiPill {
    /// Carried by a pill's characters: what to draw under them.
    public final class Drawn: NSObject {
        public let look: Look
        public let faded: Bool
        let titleLength: Int
        let metaLength: Int

        init(look: Look, faded: Bool, titleLength: Int, metaLength: Int) {
            self.look = look
            self.faded = faded
            self.titleLength = titleLength
            self.metaLength = metaLength
        }

        var struck: Bool { look.done || look.status?.shape == .cancelled }
    }

    public struct Placed {
        public let range: NSRange
        public let drawn: Drawn
    }

    public static let attribute = NSAttributedString.Key("PaiPill")

    private static let space = "\u{00A0}"
    private static let separator = " · "

    /// A message's text with every reference as its pill's text and link; the other entities shift with it, and the
    /// ones around a reference (a code span) are dropped.
    public static func rewrite(text: String, entities: [MessageTextEntity]) -> (String, [MessageTextEntity], [Placed]) {
        let found = matches(text: text, entities: entities)
        guard !found.isEmpty else { return (text, entities, []) }
        let result = NSMutableString(string: text)
        var entities = entities
        var placed: [Placed] = []
        for match in found.reversed() {
            guard let (look, faded) = display(match) else { continue }
            let title = look.title.replacingOccurrences(of: "\n", with: " ")
            let meta = look.meta?.paiNonEmpty
            let body = space + title + (meta.map { separator + $0 } ?? "") + space
            let length = (body as NSString).length
            let delta = length - match.range.length
            let start = match.range.location
            let end = match.range.upperBound
            result.replaceCharacters(in: match.range, with: body)
            entities = entities.compactMap { entity in
                let range = entity.range
                if range.upperBound <= start { return entity }
                if range.lowerBound >= end { return MessageTextEntity(range: (range.lowerBound + delta)..<(range.upperBound + delta), type: entity.type) }
                if range.lowerBound <= start && range.upperBound >= end {
                    switch entity.type {
                    case .Code, .TextUrl, .Underline, .Strikethrough: return nil
                    default: return MessageTextEntity(range: range.lowerBound..<(range.upperBound + delta), type: entity.type)
                    }
                }
                return nil
            }
            if let href = look.href {
                entities.append(MessageTextEntity(range: start..<(start + length), type: .TextUrl(url: href)))
            }
            placed = placed.map { Placed(range: NSRange(location: $0.range.location + delta, length: $0.range.length), drawn: $0.drawn) }
            placed.append(Placed(range: NSRange(location: start, length: length),
                                 drawn: Drawn(look: look, faded: faded, titleLength: (title as NSString).length, metaLength: meta.map { (separator + $0 as NSString).length } ?? 0)))
        }
        entities.sort { $0.range.lowerBound < $1.range.lowerBound }
        return (result as String, entities, placed.sorted { $0.range.location < $1.range.location })
    }

    struct Metrics {
        let em: CGFloat
        var padLeft: CGFloat { em * 0.45 }
        var padRight: CGFloat { em * 0.6 }
        var gap: CGFloat { em * 0.4 }
        var mark: CGFloat { em * 1.15 }
        var status: CGFloat { em * 0.9 }
    }

    /// Weight, colours and room for a pill's mark and status, laid over what the entities made of its text.
    public static func style(_ string: NSMutableAttributedString, pills: [Placed], textColor: UIColor) {
        for pill in pills {
            let range = pill.range
            guard range.length >= 2, range.upperBound <= string.length else { continue }
            let font = (string.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont) ?? UIFont.systemFont(ofSize: 17)
            let size = font.pointSize
            let metrics = Metrics(em: size)
            let drawn = pill.drawn
            let ink = textColor.withAlphaComponent(drawn.faded || drawn.struck ? 0.6 : 1)
            string.removeAttribute(.underlineStyle, range: range)
            string.removeAttribute(.strikethroughStyle, range: range)
            string.addAttributes([.foregroundColor: ink, .font: UIFont.systemFont(ofSize: size, weight: .medium), attribute: drawn], range: range)
            let spaceWidth = (space as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: size, weight: .medium)]).width
            let title = NSRange(location: range.location + 1, length: drawn.titleLength)
            if drawn.struck, title.length > 0 {
                string.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: title)
            }
            if drawn.metaLength > 0 {
                let meta = NSRange(location: title.upperBound, length: drawn.metaLength)
                if meta.upperBound <= string.length {
                    string.addAttributes([.foregroundColor: textColor.withAlphaComponent(0.6), .font: UIFont.systemFont(ofSize: size, weight: .regular)], range: meta)
                }
            }
            let lead = metrics.padLeft + metrics.mark + metrics.gap - spaceWidth
            let trail = (drawn.look.status != nil ? metrics.gap + metrics.status : 0) + metrics.padRight - spaceWidth
            string.addAttribute(.kern, value: lead, range: NSRange(location: range.location, length: 1))
            string.addAttribute(.kern, value: max(0, trail), range: NSRange(location: range.upperBound - 1, length: 1))
        }
    }

    // MARK: Drawing

    /// The capsule, mark and status of every pill in a laid-out text, as layers in the text's coordinates.
    /// `rects` gives a range's per-line rects.
    public static func layers(in string: NSAttributedString, textColor: UIColor, rects: (NSRange) -> [CGRect]) -> [CALayer] {
        var result: [CALayer] = []
        string.enumerateAttribute(attribute, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            guard let drawn = value as? Drawn else { return }
            let font = (string.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont) ?? UIFont.systemFont(ofSize: 17)
            let metrics = Metrics(em: font.pointSize)
            let lines = rects(range).filter { $0.width > 0.5 && $0.height > 0.5 }
            guard let first = lines.first, let last = lines.last else { return }
            let alpha: Float = drawn.faded || drawn.struck ? 0.6 : 1
            for line in lines {
                let height = min(line.height, font.lineHeight + metrics.em * 0.1)
                let frame = CGRect(x: line.minX, y: line.midY - height / 2, width: line.width, height: height)
                let capsule = CALayer()
                capsule.frame = frame
                capsule.cornerRadius = height / 2
                capsule.backgroundColor = textColor.withAlphaComponent(0.07).cgColor
                result.append(capsule)
            }
            let markFrame = CGRect(x: first.minX + metrics.padLeft, y: first.midY - metrics.mark / 2, width: metrics.mark, height: metrics.mark)
            let mark = CALayer()
            mark.frame = markFrame
            mark.contentsScale = UIScreen.main.scale
            mark.contents = markImage(drawn.look, size: metrics.mark, textColor: textColor)?.cgImage
            mark.opacity = alpha
            result.append(mark)
            if let status = drawn.look.status {
                let statusFrame = CGRect(x: last.maxX - metrics.padRight - metrics.status, y: last.midY - metrics.status / 2, width: metrics.status, height: metrics.status)
                let circle = CALayer()
                circle.frame = statusFrame
                circle.contentsScale = UIScreen.main.scale
                circle.contents = statusImage(status, size: metrics.status)?.cgImage
                circle.opacity = alpha
                result.append(circle)
            }
        }
        return result
    }

    public static func statusImage(_ status: Status, size: CGFloat) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { context in
            let cg = context.cgContext
            let line = max(1, size * 0.12)
            let rect = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: line / 2, dy: line / 2)
            cg.setStrokeColor(status.ink.cgColor)
            cg.setFillColor(status.ink.cgColor)
            cg.setLineWidth(line)
            switch status.shape {
            case .todo:
                cg.strokeEllipse(in: rect)
            case .doing:
                cg.strokeEllipse(in: rect)
                cg.move(to: CGPoint(x: rect.midX, y: rect.midY))
                cg.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
                cg.closePath()
                cg.fillPath()
            case .done, .cancelled:
                cg.fillEllipse(in: rect.insetBy(dx: -line / 2, dy: -line / 2))
            }
        }
    }

    private static var loadingAvatars: Set<String> = []
    private static let avatarLock = NSLock()

    /// A face from the shared portrait cache; fetched once, the pills redraw when it lands.
    private static func avatar(_ url: String) -> UIImage? {
        if let image = PaiAvatars.cached(url) { return image }
        avatarLock.lock()
        let start = !loadingAvatars.contains(url)
        loadingAvatars.insert(url)
        avatarLock.unlock()
        if start {
            let _ = (PaiAvatars.image(url) |> deliverOnMainQueue).startStandalone(next: { image in
                if image != nil {
                    NotificationCenter.default.post(name: resolved, object: nil)
                }
            })
        }
        return nil
    }

    /// A pill's mark: its picture tinted by the look's colour, with the ↗ of an external record in the corner.
    public static func markImage(_ look: Look, size: CGFloat, textColor: UIColor) -> UIImage? {
        let tint = look.color ?? textColor
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { context in
            let cg = context.cgContext
            let box = CGRect(x: 0, y: 0, width: size, height: size)
            switch look.mark {
            case let .avatar(url):
                if let image = avatar(url) {
                    cg.saveGState()
                    UIBezierPath(ovalIn: box).addClip()
                    let side = min(image.size.width, image.size.height)
                    let scale = size / max(side, 1)
                    image.draw(in: CGRect(x: (size - image.size.width * scale) / 2, y: (size - image.size.height * scale) / 2,
                                          width: image.size.width * scale, height: image.size.height * scale))
                    cg.restoreGState()
                } else {
                    drawSymbol("person.crop.circle", in: box, tint: tint)
                }
            case let .symbol(name):
                drawSymbol(name, in: box, tint: tint)
            case .calendar:
                drawStroked(calendarPath, viewBox: 24, in: box, tint: tint, cg: cg, width: 2)
            case .commit:
                drawStroked(commitPath, viewBox: 24, in: box, tint: tint, cg: cg, width: 2)
            case .keep:
                drawStroked(keepStroke, viewBox: 128, in: box.insetBy(dx: -size * 0.04, dy: -size * 0.04), tint: tint, cg: cg, width: 9)
                cg.saveGState()
                let fill = scaled(keepFill, viewBox: 128, in: box.insetBy(dx: -size * 0.04, dy: -size * 0.04))
                cg.addPath(fill)
                cg.setFillColor(tint.cgColor)
                cg.fillPath()
                cg.restoreGState()
            case .dot:
                let dot = size * 0.6 / 1.15
                cg.setFillColor(tint.cgColor)
                cg.fillEllipse(in: CGRect(x: (size - dot) / 2, y: (size - dot) / 2, width: dot, height: dot))
            }
            if look.external {
                let side = size * 0.48
                let corner = CGRect(x: size - side, y: 0, width: side, height: side)
                let arrow = CGMutablePath()
                arrow.move(to: CGPoint(x: corner.minX + side * 0.2, y: corner.maxY - side * 0.2))
                arrow.addLine(to: CGPoint(x: corner.maxX - side * 0.2, y: corner.minY + side * 0.2))
                arrow.move(to: CGPoint(x: corner.minX + side * 0.38, y: corner.minY + side * 0.2))
                arrow.addLine(to: CGPoint(x: corner.maxX - side * 0.2, y: corner.minY + side * 0.2))
                arrow.addLine(to: CGPoint(x: corner.maxX - side * 0.2, y: corner.maxY - side * 0.38))
                cg.setLineCap(.round)
                cg.setLineJoin(.round)
                // The halo cuts the mark around the arrow so it reads over any picture.
                cg.saveGState()
                cg.setBlendMode(.clear)
                cg.setLineWidth(side * 0.42)
                cg.addPath(arrow)
                cg.strokePath()
                cg.restoreGState()
                cg.setStrokeColor(textColor.cgColor)
                cg.setLineWidth(max(1, side * 0.16))
                cg.addPath(arrow)
                cg.strokePath()
            }
        }
    }

    private static func drawSymbol(_ name: String, in box: CGRect, tint: UIColor) {
        let configuration = UIImage.SymbolConfiguration(pointSize: box.height * 0.82, weight: .medium)
        guard let image = UIImage(systemName: name, withConfiguration: configuration)?.withTintColor(tint, renderingMode: .alwaysOriginal) else { return }
        let scale = min(box.width / image.size.width, box.height / image.size.height, 1)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height))
    }

    private static func scaled(_ path: CGPath, viewBox: CGFloat, in box: CGRect) -> CGPath {
        var transform = CGAffineTransform(translationX: box.minX, y: box.minY).scaledBy(x: box.width / viewBox, y: box.height / viewBox)
        return path.copy(using: &transform) ?? path
    }

    private static func drawStroked(_ path: CGPath, viewBox: CGFloat, in box: CGRect, tint: UIColor, cg: CGContext, width: CGFloat) {
        cg.saveGState()
        cg.addPath(scaled(path, viewBox: viewBox, in: box))
        cg.setStrokeColor(tint.cgColor)
        cg.setLineWidth(width * box.width / viewBox)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.strokePath()
        cg.restoreGState()
    }

    private static let calendarPath: CGPath = {
        let path = CGMutablePath()
        path.addPath(svgPath("M8 2V6M16 2V6M3 10H21"))
        path.addRoundedRect(in: CGRect(x: 3, y: 4, width: 18, height: 18), cornerWidth: 2, cornerHeight: 2)
        return path
    }()

    private static let commitPath: CGPath = {
        let path = CGMutablePath()
        path.addEllipse(in: CGRect(x: 8, y: 8, width: 8, height: 8))
        path.addPath(svgPath("M1.5 12H8M16 12H22.5"))
        return path
    }()

    /// The Keep logo, bundled so a pill never waits on it.
    private static let keepStroke: CGPath = svgPath(
        "M70.7356 60.1528V87.9371C70.7356 90.6986 68.497 92.9371 65.7356 92.9371H9.20258C6.44116 92.9371 4.20258 90.6986 4.20258 87.9371V22.2076C4.20258 20.8815 4.72937 19.6098 5.66705 18.6721L17.6839 6.6552C18.6216 5.71752 19.8934 5.19073 21.2195 5.19073H65.7356C68.497 5.19073 70.7356 7.42931 70.7356 10.1907V51.9567"
        + "M95.3137 94.6715L81.2938 119.022C79.9159 121.415 76.859 122.238 74.4658 120.86L30.7194 95.6734M99.4423 87.5006L120.505 50.9172C121.883 48.5241 121.06 45.4671 118.667 44.0893L98.4353 32.441"
        + "M90.7005 19.3898L96.4182 20.9601C99.0792 21.6909 100.645 24.4393 99.9168 27.101L78.9723 103.653C78.2436 106.317 75.4936 107.885 72.8301 107.156L20.8592 92.9372M70.7355 13.9158L82.7886 17.1995"
        + "M71.8524 23L90.4646 27.9871M71.5 33.5851L80.4646 35.9871M96.7525 42.5L110.564 50.4739")
    private static let keepFill: CGPath = svgPath("M17.6584 28.84H31.6584V77H17.6584V28.84ZM34.5984 60.13V45.08L45.6584 28.84H60.9184L44.3284 51.52L61.1284 77H45.4484L34.5984 60.13Z")

    /// Absolute SVG path commands (M L H V C Z), all the bundled marks use.
    static func svgPath(_ data: String) -> CGPath {
        let regex = try! NSRegularExpression(pattern: "[MLHVCZ]|-?(?:\\d+\\.?\\d*|\\.\\d+)(?:[eE][-+]?\\d+)?")
        let ns = data as NSString
        let tokens = regex.matches(in: data, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
        let path = CGMutablePath()
        var command = "M"
        var numbers: [CGFloat] = []
        var current = CGPoint.zero
        func flush() {
            var i = 0
            func take(_ n: Int) -> [CGFloat]? {
                guard i + n <= numbers.count else { return nil }
                defer { i += n }
                return Array(numbers[i ..< i + n])
            }
            switch command {
            case "M":
                var first = true
                while let p = take(2) {
                    current = CGPoint(x: p[0], y: p[1])
                    if first { path.move(to: current) } else { path.addLine(to: current) }
                    first = false
                }
            case "L":
                while let p = take(2) { current = CGPoint(x: p[0], y: p[1]); path.addLine(to: current) }
            case "H":
                while let p = take(1) { current = CGPoint(x: p[0], y: current.y); path.addLine(to: current) }
            case "V":
                while let p = take(1) { current = CGPoint(x: current.x, y: p[0]); path.addLine(to: current) }
            case "C":
                while let p = take(6) {
                    current = CGPoint(x: p[4], y: p[5])
                    path.addCurve(to: current, control1: CGPoint(x: p[0], y: p[1]), control2: CGPoint(x: p[2], y: p[3]))
                }
            case "Z":
                path.closeSubpath()
            default:
                break
            }
            numbers = []
        }
        for token in tokens {
            if let first = token.first, first.isLetter, token.count == 1 {
                flush()
                command = token
                if command == "Z" { flush(); command = "" }
            } else if let value = Double(token) {
                numbers.append(CGFloat(value))
            }
        }
        flush()
        return path
    }
}
