import Foundation

/// Builds the `POST {pai}/calls/recording` upload: parts `meta` (JSON), `mic` and `remote` (m4a). The body goes to a
/// file so a long call never sits in memory and `URLSession` can upload it from disk.
public enum CallRecordingMultipart {
    public static func request(baseURL: URL, token: String, boundary: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("calls/recording"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        return request
    }

    public static func makeBoundary() -> String {
        return "PaiCallRecording-\(UUID().uuidString)"
    }

    /// Writes the multipart body to `destination`, replacing it.
    public static func writeBody(meta: Data, mic: URL, remote: URL, boundary: String, to destination: URL) throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destination)
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        func write(_ string: String) {
            output.write(Data(string.utf8))
        }

        write("--\(boundary)\r\n")
        write("Content-Disposition: form-data; name=\"meta\"\r\n")
        write("Content-Type: application/json\r\n\r\n")
        output.write(meta)
        write("\r\n")

        for (name, file) in [("mic", mic), ("remote", remote)] {
            write("--\(boundary)\r\n")
            write("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(name).m4a\"\r\n")
            write("Content-Type: audio/mp4\r\n\r\n")
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            while true {
                let chunk = input.readData(ofLength: 1 << 20)
                if chunk.isEmpty { break }
                output.write(chunk)
            }
            write("\r\n")
        }
        write("--\(boundary)--\r\n")
    }
}
