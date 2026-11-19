import AVFoundation
import Foundation
import XCTest
@testable import PaiCallRecording

/// Records every request and answers a scripted status (or a network error) per call.
private final class MockTransport: CallRecordingTransport, @unchecked Sendable {
    enum Reply {
        case status(Int)
        case networkError
    }

    struct Sent {
        let request: URLRequest
        let body: Data
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var sentRequests: [Sent] = []

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    var sent: [Sent] {
        lock.lock()
        defer { lock.unlock() }
        return sentRequests
    }

    func send(_ request: URLRequest, bodyFile: URL) async throws -> Int {
        let body = try Data(contentsOf: bodyFile)
        lock.lock()
        sentRequests.append(Sent(request: request, body: body))
        let reply = replies.isEmpty ? .status(500) : replies.removeFirst()
        lock.unlock()
        switch reply {
        case let .status(status):
            return status
        case .networkError:
            throw URLError(.notConnectedToInternet)
        }
    }
}

/// One multipart part: its headers and raw body.
private struct Part {
    let headers: [String: String]
    let body: Data

    var disposition: String { headers["content-disposition"] ?? "" }
}

private func parseMultipart(_ body: Data, boundary: String) -> [Part] {
    let delimiter = Data("--\(boundary)".utf8)
    let crlf = Data("\r\n".utf8)
    let headerEnd = Data("\r\n\r\n".utf8)
    var parts: [Part] = []
    var cursor = body.range(of: delimiter)?.upperBound ?? body.endIndex
    while cursor < body.endIndex {
        // "--" right after the delimiter closes the body.
        if body[cursor...].starts(with: Data("--".utf8)) { break }
        cursor += crlf.count
        guard let next = body.range(of: delimiter, in: cursor..<body.endIndex), let headersEnd = body.range(of: headerEnd, in: cursor..<next.lowerBound) else { break }
        let headerText = String(decoding: body[cursor..<headersEnd.lowerBound], as: UTF8.self)
        var headers: [String: String] = [:]
        for line in headerText.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let content = body[headersEnd.upperBound..<(next.lowerBound - crlf.count)]
        parts.append(Part(headers: headers, body: Data(content)))
        cursor = next.upperBound
    }
    return parts
}

final class CallRecordingTests: XCTestCase {
    private var root: URL!
    private var store: CallRecordingStore!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PaiCallRecordingTests-\(UUID().uuidString)", isDirectory: true)
        store = CallRecordingStore(root: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeMeta(peer: CallRecordingPeer = CallRecordingPeer(name: "Anna", number: "+15550100", telegramId: "777"), ended: Bool = true) -> CallRecordingMeta {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        return CallRecordingMeta(callId: UUID().uuidString, startedAt: start, endedAt: ended ? start.addingTimeInterval(65) : nil, direction: .outgoing, peer: peer)
    }

    /// A finished recording on disk with stand-in track bytes.
    @discardableResult
    private func makeRecording(_ meta: CallRecordingMeta? = nil) throws -> CallRecordingMeta {
        let meta = meta ?? makeMeta()
        try store.create(meta)
        try Data("MIC-BYTES".utf8).write(to: store.micURL(meta.callId))
        try Data("REMOTE-BYTES".utf8).write(to: store.remoteURL(meta.callId))
        return meta
    }

    private func exists(_ callId: String) -> Bool {
        return FileManager.default.fileExists(atPath: store.directory(callId).path)
    }

    private func makeUploader(_ transport: MockTransport, onUnauthorized: (@Sendable () -> Void)? = nil) -> CallRecordingUploader {
        let uploader = CallRecordingUploader(store: store, transport: transport)
        uploader.configure(baseURL: "https://pai.example", token: "pd_test", onUnauthorized: onUnauthorized)
        return uploader
    }

    // MARK: - Request building

    func testRequestTargetsCallsRecordingWithBearerAndBoundary() {
        let request = CallRecordingMultipart.request(baseURL: URL(string: "https://pai.example")!, token: "pd_test", boundary: "B")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://pai.example/calls/recording")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer pd_test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "multipart/form-data; boundary=B")
    }

    func testBodyHasMetaMicRemoteParts() throws {
        let meta = try makeRecording()
        let boundary = CallRecordingMultipart.makeBoundary()
        let bodyFile = root.appendingPathComponent("body.multipart")
        try CallRecordingMultipart.writeBody(meta: try meta.encoded(), mic: store.micURL(meta.callId), remote: store.remoteURL(meta.callId), boundary: boundary, to: bodyFile)
        let body = try Data(contentsOf: bodyFile)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).hasSuffix("--\(boundary)--\r\n"))

        let parts = parseMultipart(body, boundary: boundary)
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0].disposition, "form-data; name=\"meta\"")
        XCTAssertEqual(parts[0].headers["content-type"], "application/json")
        XCTAssertEqual(parts[1].disposition, "form-data; name=\"mic\"; filename=\"mic.m4a\"")
        XCTAssertEqual(parts[1].headers["content-type"], "audio/mp4")
        XCTAssertEqual(parts[1].body, Data("MIC-BYTES".utf8))
        XCTAssertEqual(parts[2].disposition, "form-data; name=\"remote\"; filename=\"remote.m4a\"")
        XCTAssertEqual(parts[2].headers["content-type"], "audio/mp4")
        XCTAssertEqual(parts[2].body, Data("REMOTE-BYTES".utf8))

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: parts[0].body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["callId", "startedAt", "endedAt", "direction", "peer", "app"])
        XCTAssertEqual(json["callId"] as? String, meta.callId)
        XCTAssertEqual(json["startedAt"] as? String, "2027-01-15T08:00:00.000Z")
        XCTAssertEqual(json["endedAt"] as? String, "2027-01-15T08:01:05.000Z")
        XCTAssertEqual(json["direction"] as? String, "out")
        XCTAssertEqual(json["app"] as? String, "telegram")
        XCTAssertEqual(json["peer"] as? [String: String], ["name": "Anna", "number": "+15550100", "telegramId": "777"])
    }

    func testMetaOmitsMissingPeerFieldsAndEncodesIncoming() throws {
        var meta = makeMeta(peer: CallRecordingPeer(telegramId: "42"))
        meta.direction = .incoming
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try meta.encoded()) as? [String: Any])
        XCTAssertEqual(json["peer"] as? [String: String], ["telegramId": "42"])
        XCTAssertEqual(json["direction"] as? String, "in")
    }

    // MARK: - Status decisions

    func testDecide() {
        XCTAssertEqual(CallRecordingUploader.decide(status: 202), .delete)
        XCTAssertEqual(CallRecordingUploader.decide(status: 413), .drop)
        XCTAssertEqual(CallRecordingUploader.decide(status: 400), .drop)
        XCTAssertEqual(CallRecordingUploader.decide(status: 401), .unauthorized)
        XCTAssertEqual(CallRecordingUploader.decide(status: 500), .keep)
        XCTAssertEqual(CallRecordingUploader.decide(status: 503), .keep)
    }

    // MARK: - Retry / delete state machine

    func testAcceptedDeletesLocalFiles() async throws {
        let meta = try makeRecording()
        let transport = MockTransport([.status(202)])
        let decision = await makeUploader(transport).upload(meta)
        XCTAssertEqual(decision, .delete)
        XCTAssertFalse(exists(meta.callId))
        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertEqual(transport.sent[0].request.url?.path, "/calls/recording")
    }

    func testServerErrorKeepsFiles() async throws {
        let meta = try makeRecording()
        let decision = await makeUploader(MockTransport([.status(500)])).upload(meta)
        XCTAssertEqual(decision, .keep)
        XCTAssertTrue(exists(meta.callId))
        XCTAssertEqual(store.pending().map(\.callId), [meta.callId])
    }

    func testNetworkErrorKeepsFiles() async throws {
        let meta = try makeRecording()
        let decision = await makeUploader(MockTransport([.networkError])).upload(meta)
        XCTAssertEqual(decision, .keep)
        XCTAssertTrue(exists(meta.callId))
    }

    func testTooLargeDropsFiles() async throws {
        let meta = try makeRecording()
        let decision = await makeUploader(MockTransport([.status(413)])).upload(meta)
        XCTAssertEqual(decision, .drop)
        XCTAssertFalse(exists(meta.callId))
    }

    func testOtherClientErrorDropsFiles() async throws {
        let meta = try makeRecording()
        let decision = await makeUploader(MockTransport([.status(400)])).upload(meta)
        XCTAssertEqual(decision, .drop)
        XCTAssertFalse(exists(meta.callId))
    }

    func testUnauthorizedKeepsFilesAndReports() async throws {
        let meta = try makeRecording()
        let reported = expectation(description: "onUnauthorized")
        let decision = await makeUploader(MockTransport([.status(401)]), onUnauthorized: { reported.fulfill() }).upload(meta)
        XCTAssertEqual(decision, .unauthorized)
        XCTAssertTrue(exists(meta.callId))
        await fulfillment(of: [reported], timeout: 1)
    }

    func testNoTokenKeepsFilesWithoutSending() async throws {
        let meta = try makeRecording()
        let transport = MockTransport([.status(202)])
        let uploader = CallRecordingUploader(store: store, transport: transport)
        uploader.configure(baseURL: "https://pai.example", token: nil, onUnauthorized: nil)
        let decision = await uploader.upload(meta)
        XCTAssertEqual(decision, .keep)
        XCTAssertTrue(exists(meta.callId))
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testRetryAfterServerErrorReusesCallIdThenDeletes() async throws {
        let meta = try makeRecording()
        let transport = MockTransport([.status(503), .status(202)])
        let uploader = makeUploader(transport)

        await uploader.uploadPending()
        XCTAssertTrue(exists(meta.callId))
        await uploader.uploadPending()
        XCTAssertFalse(exists(meta.callId))

        let callIds = try transport.sent.map { sent -> String in
            let boundary = try XCTUnwrap(sent.request.value(forHTTPHeaderField: "Content-Type")?.components(separatedBy: "boundary=").last)
            let metaPart = try XCTUnwrap(parseMultipart(sent.body, boundary: boundary).first)
            return try JSONDecoder().decode(CallRecordingMeta.self, from: metaPart.body).callId
        }
        XCTAssertEqual(callIds, [meta.callId, meta.callId])
    }

    func testPendingSkipsUnfinishedRecordings() async throws {
        let unfinished = try makeRecording(makeMeta(ended: false))
        let transport = MockTransport([.status(202)])
        await makeUploader(transport).uploadPending()
        XCTAssertTrue(transport.sent.isEmpty)
        XCTAssertTrue(exists(unfinished.callId))
    }

    func testServerErrorStopsPassAndKeepsLaterRecordings() async throws {
        let first = try makeRecording()
        var laterMeta = makeMeta()
        laterMeta.startedAt = CallRecordingMeta.isoString(Date(timeIntervalSince1970: 1_800_000_500))
        let later = try makeRecording(laterMeta)
        let transport = MockTransport([.status(500)])
        await makeUploader(transport).uploadPending()
        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertTrue(exists(first.callId))
        XCTAssertTrue(exists(later.callId))
    }

    // MARK: - Recorder

    func testRecorderWritesBothTracksAndFinishesMeta() throws {
        let meta = makeMeta(ended: false)
        let recorder = try CallRecorder(store: store, meta: meta)
        XCTAssertTrue(store.pending().isEmpty)

        // 1 s of a 440 Hz tone at 48 kHz on the mic, nothing on the remote side.
        var samples = [Int16](repeating: 0, count: 48000)
        for index in samples.indices {
            samples[index] = Int16(sin(Double(index) * 2 * .pi * 440 / 48000) * 8000)
        }
        let chunk = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        recorder.append(mic: chunk, micRate: 48000, remote: Data(), remoteRate: 48000)

        let done = expectation(description: "finish")
        recorder.finish(endedAt: Date(timeIntervalSince1970: 1_800_000_065)) { callId in
            XCTAssertEqual(callId, meta.callId)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)

        XCTAssertEqual(store.pending().map(\.callId), [meta.callId])
        for url in [store.micURL(meta.callId), store.remoteURL(meta.callId)] {
            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(file.fileFormat.sampleRate, 16000)
            XCTAssertEqual(file.fileFormat.channelCount, 1)
            XCTAssertGreaterThan(file.length, 8000)
        }
    }
}
