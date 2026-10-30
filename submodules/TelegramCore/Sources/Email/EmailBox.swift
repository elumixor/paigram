import Foundation
import SwiftSignalKit

/// Paigram's mail comes from the pai box's email connector (`/gmail/…`): every correspondent of the user's
/// mailboxes is an email chat, and the box is where their history, search, sends and read marks go.
public enum EmailBox {
    private static let lock = NSLock()
    private static var configured: (baseURL: URL, token: String)?
    
    /// Set once at launch by the main app; until then (and in extensions) email chats neither sync nor send.
    public static func configure(baseURL: String, token: String) {
        guard let url = URL(string: baseURL), !token.isEmpty else {
            return
        }
        self.lock.lock()
        self.configured = (url, token)
        self.lock.unlock()
    }
    
    static var configuration: (baseURL: URL, token: String)? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.configured
    }
    
    /// Where an attachment downloads from: a plain GET with the token in the query, as media fetching sends no headers.
    static func attachmentURL(account: String, message: String, part: String) -> String? {
        return self.url(path: "/gmail/attachment", query: ["account": account, "message": message, "part": part], includingToken: true)?.absoluteString
    }
    
    static func url(path: String, query: [String: String], includingToken: Bool) -> URL? {
        guard let (baseURL, token) = self.configuration, var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            return nil
        }
        var items = query.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        if includingToken {
            items.append(URLQueryItem(name: "token", value: token))
        }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }
}

public enum EmailBoxError: Error, CustomStringConvertible {
    case notConfigured
    case http(status: Int, body: String)
    case transport(String)
    case decoding(String)
    
    public var description: String {
        switch self {
        case .notConfigured:
            return "email: the box is not configured"
        case let .http(status, body):
            return "email: \(status) \(body.prefix(200))"
        case let .transport(message):
            return "email: \(message)"
        case let .decoding(message):
            return "email: unreadable answer (\(message))"
        }
    }
}

/// The box's routes, as signals.
enum EmailClient {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60.0
        return URLSession(configuration: configuration)
    }()
    
    private static let decoder = JSONDecoder()
    
    private static func perform<T: Decodable>(_ request: URLRequest) -> Signal<T, EmailBoxError> {
        return Signal { subscriber in
            let task = self.session.dataTask(with: request, completionHandler: { data, response, error in
                if let error {
                    subscriber.putError(.transport(error.localizedDescription))
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let data = data ?? Data()
                guard (200 ..< 300).contains(status) else {
                    subscriber.putError(.http(status: status, body: String(decoding: data, as: UTF8.self)))
                    return
                }
                do {
                    subscriber.putNext(try self.decoder.decode(T.self, from: data))
                    subscriber.putCompletion()
                } catch {
                    subscriber.putError(.decoding(String(describing: error)))
                }
            })
            task.resume()
            return ActionDisposable {
                task.cancel()
            }
        }
    }
    
    private static func request(method: String, path: String, query: [String: String] = [:], body: Data? = nil) -> URLRequest? {
        guard let (_, token) = EmailBox.configuration, let url = EmailBox.url(path: path, query: query, includingToken: false) else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
    
    static func get<T: Decodable>(_ path: String, query: [String: String] = [:]) -> Signal<T, EmailBoxError> {
        guard let request = self.request(method: "GET", path: path, query: query) else {
            return .fail(.notConfigured)
        }
        return self.perform(request)
    }
    
    static func post<T: Decodable, B: Encodable>(_ path: String, body: B) -> Signal<T, EmailBoxError> {
        guard let data = try? JSONEncoder().encode(body), let request = self.request(method: "POST", path: path, body: data) else {
            return .fail(.notConfigured)
        }
        return self.perform(request)
    }
}

// MARK: - What the box sends

public struct EmailAddress: Codable, Equatable {
    public let name: String
    public let address: String
    
    public var displayName: String {
        return self.name.isEmpty ? self.address : self.name
    }
}

public struct EmailAttachmentData: Codable, Equatable {
    public let part: String
    public let name: String
    public let mimeType: String
    public let size: Int64
}

public struct EmailMessageData: Codable, Equatable {
    public let account: String
    public let id: String
    public let threadId: String
    /// Milliseconds since 1970.
    public let date: Int64
    public let from: EmailAddress
    public let to: [EmailAddress]
    public let cc: [EmailAddress]
    public let subject: String
    public let snippet: String
    public let unread: Bool
    public let outgoing: Bool
    /// The message's own words; absent in a summary (the contact list's latest message).
    public let text: String?
    public let attachments: [EmailAttachmentData]?
}

public struct EmailContactData: Codable, Equatable {
    public let id: Int64
    public let address: String
    public let name: String
    public let included: Bool
    public let muted: Bool
    public let lastDate: Int64
    public let unread: Int32
    public let oldestUnread: Int64?
    public let last: EmailMessageData?
}

public struct EmailAccountData: Codable, Equatable {
    public let label: String
    public let email: String
    public let title: String
    public let color: String
}

struct EmailContactsResponse: Decodable {
    let seq: Int64
    let accounts: [EmailAccountData]
    let contacts: [EmailContactData]
}

struct EmailChange: Decodable {
    struct Payload: Decodable {
        let contact: EmailContactData?
        let message: EmailMessageData?
        let account: String?
        let id: String?
    }
    
    let seq: Int64
    let kind: String
    let payload: Payload
}

struct EmailChangesResponse: Decodable {
    let reset: Bool
    let seq: Int64
    let changes: [EmailChange]
    let more: Bool?
}

struct EmailConversationResponse: Decodable {
    let contact: EmailContactData
    let messages: [EmailMessageData]
    let more: Bool
}

struct EmailSearchResponse: Decodable {
    struct Result: Decodable {
        let contact: EmailContactData?
        let message: EmailMessageData
    }
    
    let results: [Result]
}

struct EmailMessageResponse: Decodable {
    let contact: EmailContactData
    let message: EmailMessageData
}

struct EmailReadResponse: Decodable {
    let contact: EmailContactData
}
