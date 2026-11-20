import Foundation

/// What the draft card above an agent's composer shows (`PaiDraftsPanelComponent` in TelegramUI): the agent's
/// pending drafts and, per draft, which thread messages the user opened. Mirrors pai web's `DraftCard.svelte`.
public enum PaiDraftCard {
    /// The open topic's pending drafts: its agent's, and for pai's main topic also the ones no agent wrote.
    @available(iOS 16.0, *)
    @MainActor
    public static func drafts(thread: Int64?) -> [PaiDraft] {
        let slug = PaiChat.agent(thread: thread)?.slug ?? PaiChat.paiSlug
        return PaiHost.store.drafts.filter { $0.agent == slug || (slug == PaiChat.paiSlug && $0.agent == nil) }
    }

    /// The thread messages always shown: the last two.
    public static let shownTail = 2

    /// Per draft: whether the earlier messages show, and which messages (index in the thread) are open.
    public struct Fold: Equatable {
        public var earlier = false
        public var open: Set<Int> = []
    }

    private static var folds: [Int: Fold] = [:]

    public static func fold(_ draft: Int) -> Fold { folds[draft] ?? Fold() }

    public static func toggleEarlier(_ draft: Int) {
        folds[draft, default: Fold()].earlier.toggle()
    }

    public static func toggle(message index: Int, of draft: Int) {
        var fold = folds[draft] ?? Fold()
        if fold.open.contains(index) { fold.open.remove(index) } else { fold.open.insert(index) }
        folds[draft] = fold
    }

    /// Indices of the thread messages to draw, oldest first.
    public static func shown(_ thread: [PaiDraft.ThreadMessage], fold: Fold) -> Range<Int> {
        fold.earlier ? 0 ..< thread.count : max(0, thread.count - shownTail) ..< thread.count
    }

    /// "3 earlier messages" / "Hide earlier messages"; nil when every message already shows.
    public static func earlierLabel(_ thread: [PaiDraft.ThreadMessage], fold: Fold) -> String? {
        let hidden = thread.count - shownTail
        guard hidden > 0 else { return nil }
        return fold.earlier ? "Hide earlier messages" : "\(hidden) earlier message\(hidden > 1 ? "s" : "")"
    }

    /// A sender as a person reads it: the display name of `"Name" <addr>`, else the address.
    public static func senderName(_ from: String) -> String {
        if let lt = from.firstIndex(of: "<") {
            let name = from[..<lt].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return from.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces)
    }

    /// The first ~140 characters of a message, whitespace collapsed to single spaces.
    public static func gist(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(collapsed.prefix(140))
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// How long ago a message (`at`, ms since 1970) was sent: "3 hr. ago".
    public static func ago(_ at: Double, now: Date = Date()) -> String {
        relative.localizedString(for: Date(timeIntervalSince1970: at / 1000.0), relativeTo: now)
    }

    /// The SF Symbol for a draft's channel.
    public static func symbol(channel: String) -> String {
        switch channel {
        case "email": return "envelope.fill"
        case "telegram": return "paperplane.fill"
        case "whatsapp": return "message.fill"
        case "linkedin": return "person.crop.square.fill"
        case "post": return "megaphone.fill"
        default: return "square.and.pencil"
        }
    }
}
