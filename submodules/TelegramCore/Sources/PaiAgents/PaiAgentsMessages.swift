import Foundation
import Postbox

/// One row of pai's message log (`GET /messages`): every word between the user, pai, its agents, routines and watchers.
struct PaiLogRow {
    let id: Int32
    /// "user", "pai", an agent's slug, "routine:<id>", "watcher:<source>".
    let from: String
    let to: String
    /// chat, delegate, report, request, response, ask, answer, notice, event.
    let kind: String
    let body: String
    let meta: [String: Any]
    /// Milliseconds.
    let createdAt: Double

    init?(json: Any) {
        guard let dict = json as? [String: Any], let id = (dict["id"] as? NSNumber)?.int32Value, let from = dict["from"] as? String, let to = dict["to"] as? String, let kind = dict["kind"] as? String else {
            return nil
        }
        self.id = id
        self.from = from
        self.to = to
        self.kind = kind
        self.body = dict["body"] as? String ?? ""
        self.meta = dict["meta"] as? [String: Any] ?? [:]
        self.createdAt = (dict["createdAt"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000
    }

    static func list(_ data: Data) -> [PaiLogRow]? {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            return nil
        }
        return array.compactMap(PaiLogRow.init(json:))
    }

    var agentMeta: String? {
        return self.meta["agent"] as? String
    }

    /// The agent chats the row shows in, the way `/messages?agent=` filters it.
    func chats(known: Set<String>) -> [String] {
        var result: [String] = []
        for slug in [self.from, self.to, self.agentMeta].compactMap({ $0 }) where known.contains(slug) && !result.contains(slug) {
            result.append(slug)
        }
        if known.contains("pai"), !result.contains("pai"), self.kind == "ask" || self.kind == "answer", self.from == "user" || self.to == "user" {
            result.append("pai")
        }
        return result
    }
}

/// The light markdown agents write, as message entities: **bold**, *italic*/_italic_, `code`, ```blocks``` and [links](url).
func paiMarkdown(_ source: String) -> (String, [MessageTextEntity]) {
    var output = ""
    var entities: [MessageTextEntity] = []
    let chars = Array(source)
    var i = 0
    var length = 0
    func append(_ s: String) {
        output += s
        length += (s as NSString).length
    }
    func find(_ marker: String, from start: Int) -> Int? {
        let m = Array(marker)
        var j = start
        while j + m.count <= chars.count {
            if Array(chars[j ..< j + m.count]) == m {
                return j
            }
            if m != ["`"], m != ["`", "`", "`"], chars[j] == "\n", m.count <= 2 {
                return nil
            }
            j += 1
        }
        return nil
    }
    while i < chars.count {
        let c = chars[i]
        if c == "`", i + 2 < chars.count, chars[i + 1] == "`", chars[i + 2] == "`", let end = find("```", from: i + 3) {
            var inner = String(chars[i + 3 ..< end])
            var language: String?
            if let newline = inner.firstIndex(of: "\n") {
                let first = String(inner[..<newline])
                if !first.contains(" ") {
                    language = first.isEmpty ? nil : first
                    inner = String(inner[inner.index(after: newline)...])
                }
            }
            if inner.hasSuffix("\n") {
                inner.removeLast()
            }
            let start = length
            append(inner)
            entities.append(MessageTextEntity(range: start ..< length, type: .Pre(language: language)))
            i = end + 3
            continue
        }
        if c == "`", let end = find("`", from: i + 1), end > i + 1 {
            let start = length
            append(String(chars[i + 1 ..< end]))
            entities.append(MessageTextEntity(range: start ..< length, type: .Code))
            i = end + 1
            continue
        }
        if c == "*", i + 1 < chars.count, chars[i + 1] == "*", let end = find("**", from: i + 2), end > i + 2 {
            let (inner, innerEntities) = paiMarkdown(String(chars[i + 2 ..< end]))
            let start = length
            append(inner)
            entities.append(contentsOf: innerEntities.map { MessageTextEntity(range: $0.range.lowerBound + start ..< $0.range.upperBound + start, type: $0.type) })
            entities.append(MessageTextEntity(range: start ..< length, type: .Bold))
            i = end + 2
            continue
        }
        if (c == "*" || c == "_"), i + 1 < chars.count, !chars[i + 1].isWhitespace, (i == 0 || !chars[i - 1].isLetter), let end = find(String(c), from: i + 1), end > i + 1, !chars[end - 1].isWhitespace, end + 1 >= chars.count || !chars[end + 1].isLetter {
            let start = length
            append(String(chars[i + 1 ..< end]))
            entities.append(MessageTextEntity(range: start ..< length, type: .Italic))
            i = end + 1
            continue
        }
        if c == "[", let close = find("](", from: i + 1), let end = find(")", from: close + 2), end > close + 2 {
            let label = String(chars[i + 1 ..< close])
            let url = String(chars[close + 2 ..< end])
            if url.hasPrefix("http://") || url.hasPrefix("https://") {
                let start = length
                append(label)
                entities.append(MessageTextEntity(range: start ..< length, type: .TextUrl(url: url)))
                i = end + 1
                continue
            }
        }
        append(String(c))
        i += 1
    }
    return (output, withBoxLinks(entities, text: output))
}

/// What a row looks like in one agent's chat: its text, whether it came in, who wrote it, and an ask's buttons.
struct PaiRowContent {
    let text: String
    let entities: [MessageTextEntity]
    let incoming: Bool
    let authorSlug: String?
    let markup: ReplyMarkupMessageAttribute?
}

private func base64url(_ data: Data) -> String {
    return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

/// The text with pai's trailer: a `·` linking to the row's metadata, which the app's Pai bubbles read (`PaiTrailer`).
func paiWithTrailer(_ text: String, _ entities: [MessageTextEntity], meta: [String: Any]) -> (String, [MessageTextEntity]) {
    guard let data = try? JSONSerialization.data(withJSONObject: meta) else {
        return (text, entities)
    }
    let start = (text as NSString).length + 1
    return (text + " ·", entities + [MessageTextEntity(range: start ..< start + 1, type: .TextUrl(url: "https://pai.local/m/\(base64url(data))"))])
}

private func firstLine(_ text: String) -> String {
    return text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
}

func paiRowContent(row: PaiLogRow, slug: String, agents: [PaiAgentInfo]) -> PaiRowContent {
    let name = { (slug: String) -> String in agents.first(where: { $0.slug == slug })?.name ?? slug }
    var trailer: [String: Any] = ["v": 1, "session": ""]
    for key in ["agent", "breadcrumb", "event", "icon", "priority", "thread"] {
        if let value = row.meta[key] {
            trailer[key] = value
        }
    }
    let incomingAuthor = row.from == "user" ? nil : row.from
    switch row.kind {
    case "event":
        trailer["kind"] = "event"
        let (text, entities) = paiWithTrailer(row.body, [], meta: trailer)
        return PaiRowContent(text: text, entities: entities, incoming: true, authorSlug: incomingAuthor, markup: nil)
    case "notice":
        let (text, entities) = paiMarkdown("🔔 " + row.body)
        return PaiRowContent(text: text, entities: entities, incoming: true, authorSlug: incomingAuthor, markup: nil)
    case "delegate", "request", "report", "response":
        let isOut = row.kind == "delegate" || row.kind == "request"
        let other = isOut ? row.to : row.from
        if (isOut && row.from == slug) || (!isOut && row.to == slug), other != "user" {
            trailer["kind"] = isOut ? "delegation" : "report"
            trailer["agent"] = other
            trailer["agentName"] = name(other)
            if let status = row.meta["status"] {
                trailer["status"] = status
            }
            let (text, entities) = paiWithTrailer(firstLine(row.body), [], meta: trailer)
            return PaiRowContent(text: text, entities: entities, incoming: true, authorSlug: row.from, markup: nil)
        }
        let (text, entities) = paiMarkdown(row.body)
        return PaiRowContent(text: text, entities: entities, incoming: row.from != "user", authorSlug: incomingAuthor, markup: nil)
    case "ask":
        trailer["kind"] = "ask"
        for key in ["askId", "options", "optionDetails", "multiSelect", "questions", "answer"] {
            if let value = row.meta[key] {
                trailer[key] = value
            }
        }
        let (body, bodyEntities) = paiMarkdown(row.body)
        let (text, entities) = paiWithTrailer(body, bodyEntities, meta: trailer)
        return PaiRowContent(text: text, entities: entities, incoming: true, authorSlug: incomingAuthor, markup: paiAskMarkup(meta: row.meta))
    default:
        let (text, entities) = paiMarkdown(row.body)
        return PaiRowContent(text: text, entities: entities, incoming: row.from != "user", authorSlug: incomingAuthor, markup: nil)
    }
}

/// An open ask's options as inline buttons carrying the callbacks pai's bot sends (`k:` picks, `m:` toggles, `M:` is
/// Done); the app answers them through `/asks/<id>/answer`.
func paiAskMarkup(meta: [String: Any], ticked: Set<Int> = []) -> ReplyMarkupMessageAttribute? {
    guard meta["answer"] == nil || meta["answer"] is NSNull, let askId = (meta["askId"] as? NSNumber)?.intValue, let options = meta["options"] as? [String], !options.isEmpty else {
        return nil
    }
    let multi = (meta["multiSelect"] as? Bool) ?? false
    var rows: [ReplyMarkupRow] = options.enumerated().map { index, option in
        let title = multi ? "\(ticked.contains(index) ? "☑" : "☐") \(option.prefix(55))" : String(option.prefix(60))
        let data = (multi ? "m:\(askId):\(index)" : "k:\(askId):\(index)").data(using: .utf8)!
        return ReplyMarkupRow(buttons: [ReplyMarkupButton(title: title, titleWhenForwarded: nil, action: .callback(requiresPassword: false, data: MemoryBuffer(data: data)))])
    }
    if multi {
        rows.append(ReplyMarkupRow(buttons: [ReplyMarkupButton(title: "✅ Done", titleWhenForwarded: nil, action: .callback(requiresPassword: false, data: MemoryBuffer(data: "M:\(askId)".data(using: .utf8)!)))]))
    }
    return ReplyMarkupMessageAttribute(rows: rows, flags: [.inline], placeholder: nil)
}

/// Stores a row in one agent's chat (or rewrites it there, when pai changed it: an answered ask); its id is the row's.
@discardableResult
func storePaiRow(transaction: Transaction, accountPeerId: PeerId, row: PaiLogRow, slug: String, agents: [PaiAgentInfo]) -> MessageId {
    let peerId = paiAgentPeerId(slug: slug)
    let id = MessageId(peerId: peerId, namespace: Namespaces.Message.Box, id: row.id)
    let content = paiRowContent(row: row, slug: slug, agents: agents)
    let authorId: PeerId
    if !content.incoming {
        authorId = accountPeerId
    } else if let author = content.authorSlug, agents.contains(where: { $0.slug == author }) {
        authorId = paiAgentPeerId(slug: author)
    } else {
        authorId = peerId
    }
    var attributes: [MessageAttribute] = [TextEntitiesMessageAttribute(entities: content.entities)]
    if let markup = content.markup {
        attributes.append(markup)
    }
    // An answer draws as a reply to its ask, which shows it settled.
    let askMessageId = row.kind == "answer" ? ((row.meta["quote"] as? [String: Any])?["messageId"] as? NSNumber).map { MessageId(peerId: peerId, namespace: Namespaces.Message.Box, id: $0.int32Value) } : nil
    if let askMessageId, transaction.getMessage(askMessageId) != nil {
        attributes.append(ReplyMessageAttribute(messageId: askMessageId, threadMessageId: nil, quote: nil, isQuote: false, innerSubject: nil))
    }
    var flags: StoreMessageFlags = []
    if content.incoming {
        flags.insert(.Incoming)
    }
    let (tags, globalTags) = tagsForStoreMessage(incoming: content.incoming, attributes: attributes, media: [], textEntities: content.entities, isPinned: false)
    let message = StoreMessage(id: id, customStableId: nil, globallyUniqueId: nil, groupingKey: nil, threadId: nil, timestamp: Int32(clamping: Int64(row.createdAt / 1000)), flags: flags, tags: tags, globalTags: globalTags, localTags: [], forwardInfo: nil, authorId: authorId, text: content.text, attributes: attributes, media: [])
    if let current = transaction.getMessage(id) {
        // An ask answered here stays answered when its row comes again.
        if row.kind == "ask", paiTrailerMeta(current)?["answer"] != nil {
            return id
        }
        let unchanged = current.text == content.text && current.author?.id == authorId && (current.attributes.first(where: { $0 is ReplyMarkupMessageAttribute }) == nil) == (content.markup == nil)
        if !unchanged {
            transaction.updateMessage(id, update: { _ in .update(message) })
        }
    } else {
        let _ = transaction.addMessages([message], location: .Random)
    }
    if let askMessageId {
        markPaiAskAnswered(transaction: transaction, id: askMessageId, answer: row.body)
    }
    return id
}
