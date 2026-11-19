import Foundation
import os
import UIKit

/// Sends a prepared request with a body file; answers the HTTP status or throws on a network failure.
public protocol CallRecordingTransport: Sendable {
    func send(_ request: URLRequest, bodyFile: URL) async throws -> Int
}

public struct URLSessionCallRecordingTransport: CallRecordingTransport {
    public init() {}

    public func send(_ request: URLRequest, bodyFile: URL) async throws -> Int {
        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.uploadTask(with: request, fromFile: bodyFile) { _, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let response = response as? HTTPURLResponse {
                    continuation.resume(returning: response.statusCode)
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }
            task.resume()
        }
    }
}

/// Uploads finished recordings to pai and deletes each local copy only once pai answers 202 (stored durably).
/// 5xx and network failures keep the files for a retry with the same `callId` (pai dedupes it); 413 and other 4xx
/// drop them; 401 keeps them and reports the token as rejected.
public final class CallRecordingUploader: @unchecked Sendable {
    public enum Decision: Equatable, Sendable {
        /// Stored by pai: delete the local copy.
        case delete
        /// Refused for good (413 too big, other 4xx malformed): delete and log.
        case drop
        /// Try again later with the same callId.
        case keep
        /// The token was refused: keep the files, sign out.
        case unauthorized
    }

    public static func decide(status: Int) -> Decision {
        switch status {
        case 200..<300: return .delete
        case 401: return .unauthorized
        case 400..<500: return .drop
        default: return .keep
        }
    }

    public static let shared = CallRecordingUploader(store: .shared, transport: URLSessionCallRecordingTransport())

    private static let log = OSLog(subsystem: "org.paigram", category: "call-recording")
    private static let abandonedAge: TimeInterval = 24 * 60 * 60

    public let store: CallRecordingStore
    private let transport: CallRecordingTransport
    private let lock = NSLock()
    private var baseURL: URL?
    private var token: String?
    private var onUnauthorized: (@Sendable () -> Void)?
    private var isRunning = false
    private var runAgain = false
    private var observer: NSObjectProtocol?

    public init(store: CallRecordingStore, transport: CallRecordingTransport) {
        self.store = store
        self.transport = transport
    }

    /// Called whenever the pai sign-in changes; a nil token pauses uploads (recordings stay on disk).
    public func configure(baseURL: String, token: String?, onUnauthorized: (@Sendable () -> Void)?) {
        lock.lock()
        self.baseURL = URL(string: baseURL)
        self.token = token
        self.onUnauthorized = onUnauthorized
        let needsObserver = observer == nil
        lock.unlock()
        if needsObserver {
            let observer = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
                self?.retryPending()
            }
            lock.lock()
            self.observer = observer
            lock.unlock()
        }
    }

    /// Fire-and-forget upload of everything pending, inside a background task so a call that just ended still goes out.
    public func retryPending() {
        DispatchQueue.main.async {
            let application = UIApplication.shared
            var taskId = UIBackgroundTaskIdentifier.invalid
            taskId = application.beginBackgroundTask(withName: "PaiCallRecordingUpload") {
                application.endBackgroundTask(taskId)
                taskId = .invalid
            }
            Task {
                await self.uploadPending()
                DispatchQueue.main.async {
                    if taskId != .invalid {
                        application.endBackgroundTask(taskId)
                        taskId = .invalid
                    }
                }
            }
        }
    }

    /// Uploads pending recordings one by one until none is left or one has to wait (network, server, auth).
    /// Single-flight: a call while running makes the running pass go round once more.
    public func uploadPending() async {
        lock.lock()
        if isRunning {
            runAgain = true
            lock.unlock()
            return
        }
        isRunning = true
        lock.unlock()

        while true {
            for callId in store.abandoned(olderThan: CallRecordingUploader.abandonedAge) {
                os_log("dropping unfinished recording %{public}@", log: CallRecordingUploader.log, type: .error, callId)
                store.delete(callId)
            }
            for meta in store.pending() {
                let decision = await upload(meta)
                if decision == .keep || decision == .unauthorized {
                    break
                }
            }
            lock.lock()
            if runAgain {
                runAgain = false
                lock.unlock()
                continue
            }
            isRunning = false
            lock.unlock()
            return
        }
    }

    /// Uploads one recording and applies the decision to its files. Nil credentials keep it.
    @discardableResult
    public func upload(_ meta: CallRecordingMeta) async -> Decision {
        lock.lock()
        let baseURL = self.baseURL
        let token = self.token
        let onUnauthorized = self.onUnauthorized
        lock.unlock()
        guard let baseURL, let token else { return .keep }

        let callId = meta.callId
        let mic = store.micURL(callId)
        let remote = store.remoteURL(callId)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: mic.path), fileManager.fileExists(atPath: remote.path), let metaData = try? meta.encoded() else {
            os_log("dropping recording %{public}@: tracks missing", log: CallRecordingUploader.log, type: .error, callId)
            store.delete(callId)
            return .drop
        }

        let boundary = CallRecordingMultipart.makeBoundary()
        let bodyFile = fileManager.temporaryDirectory.appendingPathComponent("call-recording-\(callId).multipart")
        defer { try? fileManager.removeItem(at: bodyFile) }
        do {
            try CallRecordingMultipart.writeBody(meta: metaData, mic: mic, remote: remote, boundary: boundary, to: bodyFile)
        } catch {
            os_log("recording %{public}@: body not written: %{public}@", log: CallRecordingUploader.log, type: .error, callId, String(describing: error))
            return .keep
        }

        let request = CallRecordingMultipart.request(baseURL: baseURL, token: token, boundary: boundary)
        let decision: Decision
        do {
            let status = try await transport.send(request, bodyFile: bodyFile)
            decision = CallRecordingUploader.decide(status: status)
            if decision == .drop {
                os_log("dropping recording %{public}@: pai answered %d", log: CallRecordingUploader.log, type: .error, callId, status)
            }
        } catch {
            os_log("recording %{public}@: upload failed, will retry: %{public}@", log: CallRecordingUploader.log, type: .info, callId, String(describing: error))
            decision = .keep
        }

        switch decision {
        case .delete, .drop:
            store.delete(callId)
        case .unauthorized:
            onUnauthorized?()
        case .keep:
            break
        }
        return decision
    }
}
