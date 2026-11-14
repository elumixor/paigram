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

/// A row of pai's log in an agent's topic, drawn the way the bot draws its own messages there (`telegram.ts`): the
/// text with a trailer naming the agent and the kind, so the user's words read as his (`user`, `Message.isPaiEcho`),
/// an agent's answer as a reply (`result`), and events, cards, asks and notices as they do in the chat.
func paiHistoryContent(row: PaiLogRow, slug: String, thread: Int64, agents: [PaiAgentInfo]) -> (String, [MessageTextEntity]) {
    let name = { (slug: String) -> String in agents.first(where: { $0.slug == slug })?.name ?? slug }
    var trailer: [String: Any] = ["v": 1, "session": slug, "agent": slug, "agentName": name(slug), "thread": thread, "author": row.from, "authorName": name(row.from)]
    for key in ["breadcrumb", "event", "icon", "priority"] {
        if let value = row.meta[key] {
            trailer[key] = value
        }
    }
    let said = { (kind: String) -> (String, [MessageTextEntity]) in
        trailer["kind"] = kind
        let (body, entities) = paiMarkdown(row.body)
        return paiWithTrailer(body, entities, meta: trailer)
    }
    switch row.kind {
    case "event":
        trailer["kind"] = "event"
        return paiWithTrailer(row.body, [], meta: trailer)
    case "notice":
        trailer["kind"] = "notice"
        let (body, entities) = paiMarkdown("🔔 " + row.body)
        return paiWithTrailer(body, entities, meta: trailer)
    case "delegate", "request", "report", "response":
        let isOut = row.kind == "delegate" || row.kind == "request"
        let other = isOut ? row.to : row.from
        if other != "user", (isOut && row.from == slug) || (!isOut && row.to == slug) {
            trailer["kind"] = isOut ? "delegation" : "report"
            trailer["agent"] = other
            trailer["agentName"] = name(other)
            if let status = row.meta["status"] {
                trailer["status"] = status
            }
            return paiWithTrailer(firstLine(row.body), [], meta: trailer)
        }
        return said(row.from == "user" ? "user" : "result")
    case "ask":
        for key in ["askId", "options", "optionDetails", "multiSelect", "questions", "answer"] {
            if let value = row.meta[key] {
                trailer[key] = value
            }
        }
        return said("ask")
    default:
        return said(row.from == "user" ? "user" : "result")
    }
}

/// A topic's history rows are `Box` messages of the bot's peer, one id space for every topic: a row's id times 32
/// plus a slot per topic, so a row two agents share (a hand-off) can be in both topics and ids still follow the log.
private let paiHistorySlots: Int32 = 32

func paiHistorySlot(thread: Int64) -> Int32 {
    return Int32(UInt64(bitPattern: thread) % UInt64(paiHistorySlots - 1)) + 1
}

func paiHistoryMessageId(peerId: PeerId, thread: Int64, row: Int32) -> MessageId {
    return MessageId(peerId: peerId, namespace: Namespaces.Message.Box, id: row * paiHistorySlots + paiHistorySlot(thread: thread))
}

/// The row of pai's log a topic's history message is (`POST /telegram/materialize` takes it).
public func paiLogRowId(historyMessageId id: MessageId) -> Int32? {
    guard id.namespace == Namespaces.Message.Box else {
        return nil
    }
    return id.id / paiHistorySlots
}

/// The newest log row before a history message id (exclusive bound for `/messages?before=`).
func paiLogRowBound(historyMessageId id: Int32) -> Int32 {
    return id / paiHistorySlots
}

/// Stores a row of pai's log in an agent's topic as the bot's message, dated when it was written.
@discardableResult
func storePaiHistoryRow(transaction: Transaction, botPeerId: PeerId, thread: Int64, row: PaiLogRow, slug: String, agents: [PaiAgentInfo]) -> MessageId {
    let id = paiHistoryMessageId(peerId: botPeerId, thread: thread, row: row.id)
    if transaction.getMessage(id) != nil {
        return id
    }
    let (text, entities) = paiHistoryContent(row: row, slug: slug, thread: thread, agents: agents)
    let attributes: [MessageAttribute] = [TextEntitiesMessageAttribute(entities: entities)]
    let (tags, globalTags) = tagsForStoreMessage(incoming: true, attributes: attributes, media: [], textEntities: entities, isPinned: false)
    let message = StoreMessage(id: id, customStableId: nil, globallyUniqueId: nil, groupingKey: nil, threadId: thread, timestamp: Int32(clamping: Int64(row.createdAt / 1000)), flags: [.Incoming], tags: tags, globalTags: globalTags, localTags: [], forwardInfo: nil, authorId: botPeerId, text: text, attributes: attributes, media: [])
    let _ = transaction.addMessages([message], location: .Random)
    return id
}
