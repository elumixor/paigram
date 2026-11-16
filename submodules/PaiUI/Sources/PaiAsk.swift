import Foundation
import Postbox
import TelegramCore

/// An ask card whose options carry details (a picture, a line, a page): its option buttons drawn as rich rows instead.
/// The rows come from the message's own inline keyboard (`askKeyboard` in `pai/src/clients/telegram.ts`), so a tap
/// sends the very callback the button would; the details come from the trailer, aligned to the options.
public enum PaiAsk {
    public struct Row {
        public let label: String
        public let detail: PaiOptionDetail?
        /// The button's callback data (`k:<askId>:<i>` picks, `m:<askId>:<i>` toggles).
        public let data: MemoryBuffer
        public let isMulti: Bool
        public let ticked: Bool
    }

    private static let optionData = try! NSRegularExpression(pattern: "^([km]):(\\d+):(\\d+)$")
    private static let askData = try! NSRegularExpression(pattern: "^[kmM]:(\\d+)(:\\d+)?$")

    /// Whether a keyboard button belongs to the ask: an option, Done or Skip (`k:`, `m:`, `M:`), not a link.
    public static func isAskButton(_ button: ReplyMarkupButton, askId: Int) -> Bool {
        guard case let .callback(_, data) = button.action, let string = String(data: data.makeData(), encoding: .utf8) else { return false }
        let ns = string as NSString
        guard let match = askData.firstMatch(in: string, range: NSRange(location: 0, length: ns.length)) else { return false }
        return Int(ns.substring(with: match.range(at: 1))) == askId
    }

    private static func option(_ button: ReplyMarkupButton) -> (multi: Bool, askId: Int, index: Int, data: MemoryBuffer)? {
        guard case let .callback(_, data) = button.action, let string = String(data: data.makeData(), encoding: .utf8) else { return nil }
        let ns = string as NSString
        guard let match = optionData.firstMatch(in: string, range: NSRange(location: 0, length: ns.length)),
              let askId = Int(ns.substring(with: match.range(at: 2))), let index = Int(ns.substring(with: match.range(at: 3))) else { return nil }
        return (ns.substring(with: match.range(at: 1)) == "m", askId, index, data)
    }

    /// Whether a keyboard button is one of the ask's options (drawn as a row), not Done, Skip or a link.
    public static func isOptionButton(_ button: ReplyMarkupButton, askId: Int) -> Bool {
        option(button)?.askId == askId
    }

    /// The rich rows for an ask message, nil when it is not an open ask or none of its options has details
    /// (the plain buttons stay then).
    public static func rows(_ message: Message) -> [Row]? {
        guard let meta = PaiTrailer.find(message)?.meta, meta.kind == "ask", let askId = meta.askId,
              let markup = message.attributes.first(where: { $0 is ReplyMarkupMessageAttribute }) as? ReplyMarkupMessageAttribute,
              markup.flags.contains(.inline) else { return nil }
        var buttons: [(button: ReplyMarkupButton, multi: Bool, index: Int, data: MemoryBuffer)] = []
        for row in markup.rows {
            for button in row.buttons {
                if let option = option(button), option.askId == askId {
                    buttons.append((button, option.multi, option.index, option.data))
                }
            }
        }
        guard !buttons.isEmpty else { return nil }
        let titles = buttons.map { title($0.button.title).label }

        // A card with several questions shows one at a time: the details are those of the question whose options
        // these buttons are.
        var options = meta.options ?? []
        var details = meta.optionDetails
        if let questions = meta.questions, questions.count > 1 {
            guard let question = questions.first(where: { matches(options: $0.options, titles: titles) }) else { return nil }
            options = question.options
            details = question.details
        }
        guard let aligned = PaiOptionDetail.aligned(details, count: options.count) else { return nil }

        return buttons.map { item in
            let (label, ticked) = title(item.button.title)
            let index = item.index
            return Row(
                label: index < options.count ? options[index] : label,
                detail: index < aligned.count ? aligned[index] : nil,
                data: item.data,
                isMulti: item.multi,
                ticked: ticked
            )
        }
    }

    // MARK: A card with several questions

    /// An open ask holding several questions, drawn whole: every question with its options, answered together.
    public struct Card {
        public let askId: Int
        public let questions: [PaiCardQuestion]
    }

    /// The card for an ask message with several questions, nil when it has one, is answered (pai edits the message and
    /// drops its buttons) or the phone is not signed in to pai (the bot's step-by-step buttons stay then).
    public static func card(_ message: Message) -> Card? {
        guard let meta = PaiTrailer.find(message)?.meta, meta.kind == "ask", meta.answer == nil, let askId = meta.askId,
              let questions = meta.questions, questions.count > 1, questions.allSatisfy({ !$0.question.isEmpty }),
              let markup = message.attributes.first(where: { $0 is ReplyMarkupMessageAttribute }) as? ReplyMarkupMessageAttribute,
              markup.flags.contains(.inline),
              markup.rows.contains(where: { $0.buttons.contains(where: { isAskButton($0, askId: askId) }) }),
              PaiAuth.isSignedIn else { return nil }
        return Card(askId: askId, questions: questions)
    }

    /// What is picked and typed on a card not sent yet; kept by ask, so it survives the cell being reused.
    public struct Draft {
        public var picked: [Int: Set<Int>] = [:]
        /// Questions answered in words, and the words; typed words win over picks.
        public var typed: [Int: String] = [:]
        public var sending = false
        public var sent = false
        public var error: String?

        /// The answer to question `index`, empty when it has none.
        public func answer(_ question: PaiCardQuestion, _ index: Int) -> String {
            if let words = typed[index]?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty, question.freeText || question.options.isEmpty {
                return words
            }
            let picks = picked[index] ?? []
            return question.options.indices.filter { picks.contains($0) }.map { question.options[$0] }.joined(separator: ", ")
        }

        public func answered(_ card: Card) -> Int {
            card.questions.indices.filter { !answer(card.questions[$0], $0).isEmpty }.count
        }

        /// The card's answer as pai takes it: a JSON object, question → answer; one left blank stays open.
        public func text(_ card: Card) -> String? {
            var answers: [String: String] = [:]
            for (i, question) in card.questions.enumerated() {
                answers[question.question] = answer(question, i)
            }
            guard let data = try? JSONSerialization.data(withJSONObject: answers, options: [.sortedKeys]) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    private static let draftLock = NSLock()
    private static var drafts: [Int: Draft] = [:]

    /// Read from the layout pass, which runs off the main thread.
    public static func draft(_ askId: Int) -> Draft {
        draftLock.lock()
        defer { draftLock.unlock() }
        return drafts[askId] ?? Draft()
    }

    public static func updateDraft(_ askId: Int, _ change: (inout Draft) -> Void) {
        draftLock.lock()
        defer { draftLock.unlock() }
        var draft = drafts[askId] ?? Draft()
        change(&draft)
        drafts[askId] = draft
    }

    /// The first line of a several-question card's text (where it comes from), without the step counter.
    public static func cardHeading(text: String, entities: [MessageTextEntity]) -> (String, [MessageTextEntity]) {
        let ns = text as NSString
        var end = ns.range(of: "\n").location
        if end == NSNotFound { end = ns.length }
        var heading = ns.substring(to: end)
        if let step = heading.range(of: #" · \d+/\d+$"#, options: .regularExpression) {
            heading.removeSubrange(step)
        }
        let length = (heading as NSString).length
        let kept = entities.compactMap { entity -> MessageTextEntity? in
            let upper = min(entity.range.upperBound, length)
            return entity.range.lowerBound < upper ? MessageTextEntity(range: entity.range.lowerBound ..< upper, type: entity.type) : nil
        }
        return (heading, kept)
    }

    /// "☑ Option" → ("Option", ticked).
    private static func title(_ title: String) -> (label: String, ticked: Bool) {
        if title.hasPrefix("☑ ") { return (String(title.dropFirst(2)), true) }
        if title.hasPrefix("☐ ") { return (String(title.dropFirst(2)), false) }
        return (title, false)
    }

    /// Buttons carry the label cut to 55-60 characters.
    private static func matches(options: [String], titles: [String]) -> Bool {
        guard options.count == titles.count else { return false }
        return zip(options, titles).allSatisfy { $0.hasPrefix($1) }
    }

    /// The text without the `• label — subtitle` list pai puts above the buttons for clients that cannot draw rows.
    public static func stripOptionLines(text: String, entities: [MessageTextEntity], options: [String]) -> (String, [MessageTextEntity]) {
        guard let first = options.first else { return (text, entities) }
        let ns = text as NSString
        let start = ns.range(of: "\n\n• " + first)
        guard start.location != NSNotFound else { return (text, entities) }
        // The list is one line per option.
        var end = start.location + 2
        for _ in options {
            guard end < ns.length, ns.substring(with: NSRange(location: end, length: min(2, ns.length - end))) == "• " else { break }
            let newline = ns.range(of: "\n", range: NSRange(location: end, length: ns.length - end))
            end = newline.location == NSNotFound ? ns.length : newline.location + 1
        }
        if end < ns.length || ns.character(at: end - 1) == 0x0A {
            end -= 1
        }
        let cut = NSRange(location: start.location, length: end - start.location)
        guard cut.length > 0 else { return (text, entities) }
        let stripped = ns.replacingCharacters(in: cut, with: "")
        let shifted = entities.compactMap { entity -> MessageTextEntity? in
            let range = entity.range
            if range.upperBound <= cut.location { return entity }
            if range.lowerBound >= cut.upperBound { return MessageTextEntity(range: (range.lowerBound - cut.length) ..< (range.upperBound - cut.length), type: entity.type) }
            if range.lowerBound >= cut.location && range.upperBound <= cut.upperBound { return nil }
            // Spans the list (an italic run around it): keep the part outside.
            let lower = min(range.lowerBound, cut.location)
            let upper = range.upperBound > cut.upperBound ? range.upperBound - cut.length : min(range.upperBound, cut.location)
            return upper > lower ? MessageTextEntity(range: lower ..< upper, type: entity.type) : nil
        }
        return (stripped, shifted)
    }
}
