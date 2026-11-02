import Foundation
import SwiftSignalKit

/// The pai box: where Paigram's email and WhatsApp chats come from and go to (`/gmail/…`, `/whatsapp/…`), with the
/// token baked into the app.
public enum PaiBox {
    private static let lock = NSLock()
    private static var configured: (baseURL: URL, token: String)?

    /// Set once at launch by the main app; until then (and in extensions) box chats neither sync nor send.
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

    /// A box address; media fetching sends no headers, so what it downloads carries the token in the query.
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

public enum BoxError: Error, CustomStringConvertible {
    case notConfigured
    case http(status: Int, body: String)
    case transport(String)
    case decoding(String)

    public var description: String {
        switch self {
        case .notConfigured:
            return "box: not configured"
        case let .http(status, body):
            return "box: \(status) \(body.prefix(200))"
        case let .transport(message):
            return "box: \(message)"
        case let .decoding(message):
            return "box: unreadable answer (\(message))"
        }
    }
}

/// A file a box route takes as multipart form data.
struct BoxUpload {
    let field: String
    let fileName: String
    let mimeType: String
    let data: Data
}

/// The box's routes, as signals.
enum BoxClient {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60.0
        return URLSession(configuration: configuration)
    }()

    private static let decoder = JSONDecoder()

    private static func perform<T: Decodable>(_ request: URLRequest) -> Signal<T, BoxError> {
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

    private static func request(method: String, path: String, query: [String: String] = [:], body: Data? = nil, contentType: String = "application/json") -> URLRequest? {
        guard let (_, token) = PaiBox.configuration, let url = PaiBox.url(path: path, query: query, includingToken: false) else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    static func get<T: Decodable>(_ path: String, query: [String: String] = [:]) -> Signal<T, BoxError> {
        guard let request = self.request(method: "GET", path: path, query: query) else {
            return .fail(.notConfigured)
        }
        return self.perform(request)
    }

    static func post<T: Decodable, B: Encodable>(_ path: String, body: B) -> Signal<T, BoxError> {
        guard let data = try? JSONEncoder().encode(body), let request = self.request(method: "POST", path: path, body: data) else {
            return .fail(.notConfigured)
        }
        return self.perform(request)
    }

    /// Text fields and one file, as a form: how a photo or a voice message goes to the box without a base64 detour.
    static func postMultipart<T: Decodable>(_ path: String, fields: [String: String], file: BoxUpload) -> Signal<T, BoxError> {
        let boundary = "paigram-\(UUID().uuidString)"
        var body = Data()
        let line = { (text: String) in body.append(text.data(using: .utf8)!) }
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            line("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        line("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(file.field)\"; filename=\"\(file.fileName.replacingOccurrences(of: "\"", with: "'"))\"\r\nContent-Type: \(file.mimeType)\r\n\r\n")
        body.append(file.data)
        line("\r\n--\(boundary)--\r\n")
        guard let request = self.request(method: "POST", path: path, body: body, contentType: "multipart/form-data; boundary=\(boundary)") else {
            return .fail(.notConfigured)
        }
        return self.perform(request)
    }
}
