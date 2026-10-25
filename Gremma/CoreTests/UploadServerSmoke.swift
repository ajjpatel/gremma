import Foundation
import Network

private struct SmokeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

@main
struct UploadServerSmoke {
    @MainActor
    static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SmokeFailure(label) }
            checks += 1
        }
        let token = UUID().uuidString + UUID().uuidString
        let server = LocalVideoUploadServer(tokenProvider: { token }, advertiseService: false)
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("gremma-upload-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        defer { server.stop(); try? FileManager.default.removeItem(at: storage) }
        let saved = storage.appendingPathComponent("persisted.mp4")
        let payload = Data((0..<190_000).map { UInt8($0 % 251) })
        var callbacks = 0
        var importedDate: Date?
        var importedRoom: String?
        var copiedBytes: Data?
        server.onVideo = { url, date, room in
            callbacks += 1
            importedDate = date
            importedRoom = room
            copiedBytes = try Data(contentsOf: url)
            try FileManager.default.copyItem(at: url, to: saved)
            // Make a premature 202 observable: persistence and this callback must finish first.
            try await Task.sleep(for: .milliseconds(50))
            return "smoke-persisted-video"
        }
        server.start()
        try await wait("listener readiness") { server.isRunning && server.port > 0 }
        let port = server.port
        let baseURL = URL(string: "http://127.0.0.1:\(port)")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        func request(token: String, path: String = "/v1/videos") -> URLRequest {
            var request = URLRequest(url: baseURL.appendingPathComponent(String(path.dropFirst())))
            request.httpMethod = path == "/health" ? "GET" : "POST"
            request.timeoutInterval = 5
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            if path != "/health" {
                request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
                request.setValue("2026-10-24T09:00:00-07:00", forHTTPHeaderField: "X-Recorded-At")
                request.setValue("Kitchen", forHTTPHeaderField: "X-Room")
                request.httpBody = payload
            }
            return request
        }
        let before = uploadFolders()
        let (data, response) = try await session.data(for: request(token: token))
        let status = (response as? HTTPURLResponse)?.statusCode
        try check(status == 202, "Expected202 after durable callback; got \(String(describing: status))")
        try check(callbacks == 1 && FileManager.default.fileExists(atPath: saved.path), "202 preceded durable import")
        try check(copiedBytes == payload && (try Data(contentsOf: saved)) == payload, "Streamed bytes changed")
        let result = try JSONSerialization.jsonObject(with: data) as? [String: String]
        try check(result?["video_id"] == "smoke-persisted-video", "Returned video ID differs")
        try check(importedRoom == "Kitchen" && importedDate == LocalVideoUploadRequest.parseRecordedAt("2026-10-24T09:00:00-07:00"), "Metadata was changed")
        try await wait("successful upload cleanup") { uploadFolders().subtracting(before).isEmpty }
        checks += 1

        let (_, rejected) = try await session.data(for: request(token: "incorrect"))
        try check((rejected as? HTTPURLResponse)?.statusCode == 401 && callbacks == 1, "Invalid token reached import")
        let (_, health) = try await session.data(for: request(token: token, path: "/health"))
        try check((health as? HTTPURLResponse)?.statusCode == 200 && callbacks == 1, "Health endpoint failed")

        let partial = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        let queue = DispatchQueue(label: "upload-smoke-client")
        partial.start(queue: queue)
        let bytes = Data("POST /v1/videos HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(token)\r\nContent-Type: video/mp4\r\nContent-Length: 5000\r\nX-Recorded-At: 2026-10-24T09:00:00Z\r\n\r\npartial".utf8)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            partial.send(content: bytes, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
        try await wait("partial upload creates staging") { !uploadFolders().subtracting(before).isEmpty }
        partial.cancel()
        try await wait("partial disconnect cleans staging") { uploadFolders().subtracting(before).isEmpty }
        try check(callbacks == 1, "Partial upload reached durable callback")

        server.stop()
        try check(!server.isRunning && server.port == 0 && server.address.isEmpty, "Stop did not reset state")
        try await Task.sleep(for: .milliseconds(100))
        do {
            _ = try await session.data(for: request(token: token, path: "/health"))
            throw SmokeFailure("Stopped listener still answered")
        } catch is URLError { checks += 1 }
        print("\(checks) local Network listener integration checks passed")
    }

    @MainActor
    static func wait(_ label: String, until predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw SmokeFailure("Timed out: \(label)")
    }

    static func uploadFolders() -> Set<String> {
        let base = FileManager.default.temporaryDirectory
        return Set(((try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("gremma-upload-") && !$0.lastPathComponent.hasPrefix("gremma-upload-smoke-") }
            .map(\.path))
    }
}
