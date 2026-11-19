import Foundation

/// The drawn blocks (tables, charts, code) a box push points at: `paiBlocks` holds their hashes, and the box serves
/// each as `GET /blocks/<hash>.png`. The notification service shows the first one as the push's picture.
public enum PaiBlockPush {
    /// The key in the push's payload.
    public static let key = "paiBlocks"

    /// The block hashes the push carries, in order: only 32 lowercase hex characters each, the rest dropped.
    public static func hashes(_ userInfo: [AnyHashable: Any]) -> [String] {
        guard let list = userInfo[key] as? [Any] else { return [] }
        return list.compactMap { $0 as? String }.filter(isHash)
    }

    /// Where the box serves a block's picture; nil for a malformed hash or base URL.
    public static func url(baseURL: String, hash: String) -> URL? {
        guard isHash(hash) else { return nil }
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty, let url = URL(string: base + "/blocks/" + hash + ".png"), url.scheme != nil else { return nil }
        return url
    }

    static func isHash(_ value: String) -> Bool {
        value.count == 32 && value.allSatisfy { ("0" ... "9").contains($0) || ("a" ... "f").contains($0) }
    }
}
