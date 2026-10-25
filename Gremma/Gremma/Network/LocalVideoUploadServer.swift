import Foundation
import Combine
import Network
import Security
import Darwin

/// Explicitly enabled foreground-only receiver for a trusted private Wi-Fi network.
/// The bearer token protects uploads, but HTTP does not encrypt video or credentials.
@MainActor
final class LocalVideoUploadServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var status = "Video receiver is off."
    @Published private(set) var port = 0
    @Published private(set) var token = ""
    @Published private(set) var address = ""
    var onVideo: (@MainActor (URL, Date, String) async throws -> String)?
    private var runtime: LocalUploadRuntime?
    private var generation: UUID?
    private let advertiseService: Bool

    /// Tests may inject an ephemeral token and disable Bonjour without writing Keychain.
    /// The app's default initializer always loads its per-install Keychain token.
    init(tokenProvider: (() throws -> String)? = nil, advertiseService: Bool = true) {
        self.advertiseService = advertiseService
        do { token = try tokenProvider?() ?? LocalUploadToken.loadOrCreate() }
        catch { status = "The upload token could not be loaded from Keychain. Reopen Gremma to try again." }
    }

    func start() {
        guard runtime == nil else { return }
        guard !token.isEmpty, onVideo != nil else {
            status = "Video storage or the upload token is unavailable."
            return
        }
        let id = UUID()
        generation = id
        status = "Starting the private Wi-Fi video receiver…"
        do {
            let instance = try LocalUploadRuntime(token: token, advertiseService: advertiseService, onState: { [weak self] readyPort, failure in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == id else { return }
                    if let readyPort {
                        self.port = readyPort
                        let host = LocalUploadAddress.privateIPv4()
                        self.address = host.map { "http://\($0):\(readyPort)" } ?? ""
                        self.isRunning = true
                        self.status = host == nil
                            ? "Receiver is on. Connect this iPhone to a private Wi-Fi network with IPv4 to show its address."
                            : "Ready on private Wi-Fi. Keep Gremma open while uploading."
                    } else if let failure {
                        self.stop()
                        self.status = failure
                    }
                }
            }, onVideo: { [weak self] url, date, room in
                guard let self else {
                    throw LocalUploadHTTPError(code: 503, message: "The receiver has stopped.")
                }
                return try await self.receiveVideo(url, recordedAt: date, room: room, generation: id)
            })
            runtime = instance
            instance.start()
        } catch {
            generation = nil
            status = "The video receiver could not start. Check Local Network access and Wi-Fi, then try again."
        }
    }

    func stop() {
        generation = nil
        runtime?.stop()
        runtime = nil
        isRunning = false
        port = 0
        address = ""
        status = "Video receiver is off."
    }

    private func receiveVideo(_ url: URL, recordedAt: Date, room: String, generation: UUID) async throws -> String {
        guard self.generation == generation, isRunning else {
            throw LocalUploadHTTPError(code: 503, message: "The receiver has stopped.")
        }
        guard let onVideo else { throw LocalUploadHTTPError(code: 503, message: "Video storage is unavailable.") }
        try Task.checkCancellation()
        return try await onVideo(url, recordedAt, room)
    }
}

private enum LocalUploadToken {
    static func loadOrCreate() throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "com.gremma.local-video-upload",
                                   kSecAttrAccount as String: "upload-token"]
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let read = SecItemCopyMatching(lookup as CFDictionary, &result)
        if read == errSecSuccess, let data = result as? Data,
           let token = String(data: data, encoding: .utf8), token.count >= 40 { return token }
        guard read == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(read)) }
        var bytes = [UInt8](repeating: 0, count: 32)
        let random = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard random == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(random)) }
        let token = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let saved = SecItemAdd(item as CFDictionary, nil)
        guard saved == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(saved)) }
        return token
    }
}

private enum LocalUploadAddress {
    static func privateIPv4() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }
        var pointer = interfaces
        var candidates: [(String, String)] = []
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: current.pointee.ifa_name)
            guard name.hasPrefix("en"), current.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let value = String(cString: host)
                if LocalVideoUploadRequest.isPrivateAddress(value) { candidates.append((name, value)) }
            }
        }
        return candidates.sorted { $0.0 < $1.0 }.first?.1
    }
}

private final class LocalUploadRuntime: @unchecked Sendable {
    typealias Import = @Sendable (URL, Date, String) async throws -> String
    private let queue = DispatchQueue(label: "com.gremma.video-upload", qos: .utility)
    private let listener: NWListener
    private let token: String
    private let onState: @Sendable (Int?, String?) -> Void
    private let onVideo: Import
    private var clients: [UUID: LocalUploadConnection] = [:]
    private var stopped = false

    init(token: String, advertiseService: Bool, onState: @escaping @Sendable (Int?, String?) -> Void, onVideo: @escaping Import) throws {
        self.token = token
        self.onState = onState
        self.onVideo = onVideo
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular]
        parameters.includePeerToPeer = false
        listener = try NWListener(using: parameters, on: .any)
        if advertiseService { listener.service = NWListener.Service(name: "Gremma", type: "_gremma-video._tcp") }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, !self.stopped else { return }
            switch state {
            case .ready:
                if let port = self.listener.port { self.onState(Int(port.rawValue), nil) }
            case .failed:
                self.onState(nil, "The receiver stopped. Check Local Network access and Wi-Fi, then try again.")
                self.stop()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    }

    func start() { listener.start(queue: queue) }
    func stop() {
        queue.async {
            self.stopped = true
            self.listener.cancel()
            let connections = Array(self.clients.values)
            self.clients.removeAll()
            connections.forEach { $0.close() }
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped else { connection.cancel(); return }
        guard case let .hostPort(host, _) = connection.endpoint,
              LocalVideoUploadRequest.isPrivateAddress(String(describing: host)) else {
            reject(connection, error: LocalUploadHTTPError(code: 403, message: "Use a private local network."))
            return
        }
        guard clients.count < 2 else {
            reject(connection, error: LocalUploadHTTPError(code: 429, message: "Two uploads are already active. Try again shortly."))
            return
        }
        let id = UUID()
        let client = LocalUploadConnection(connection: connection, queue: queue, token: token, onVideo: onVideo) { [weak self] in
            self?.clients[id] = nil
        }
        clients[id] = client
        client.start()
    }

    private func reject(_ connection: NWConnection, error: LocalUploadHTTPError) {
        connection.start(queue: queue)
        connection.send(content: LocalUploadConnection.response(code: error.code, reason: error.reason,
                        object: ["error": error.message]), completion: .contentProcessed { _ in connection.cancel() })
    }
}

private final class LocalUploadConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let token: String
    private let onVideo: LocalUploadRuntime.Import
    private let onClose: @Sendable () -> Void
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var lastProgress = ProcessInfo.processInfo.systemUptime
    private var header = Data()
    private var request: LocalVideoUploadRequest?
    private var bodyBytes = 0
    private var directory: URL?
    private var destination: URL?
    private var file: FileHandle?
    private var timer: DispatchSourceTimer?
    private var importTask: Task<Void, Never>?
    private var processing = false
    private var responded = false
    private var closed = false

    init(connection: NWConnection, queue: DispatchQueue, token: String,
         onVideo: @escaping LocalUploadRuntime.Import, onClose: @escaping @Sendable () -> Void) {
        self.connection = connection; self.queue = queue; self.token = token
        self.onVideo = onVideo; self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled: self.close()
            default: break
            }
        }
        connection.start(queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, !self.closed else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if now - self.startedAt > 300 || (!self.processing && now - self.lastProgress > 30) {
                self.fail(LocalUploadHTTPError(code: 408, message: "Upload timed out. No video was acknowledged."))
            }
        }
        self.timer = timer
        timer.resume()
        receive()
    }

    private func receive() {
        guard !closed, !responded, !processing else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, !self.closed, !self.responded else { return }
            if let data, !data.isEmpty {
                self.lastProgress = ProcessInfo.processInfo.systemUptime
                do { try self.consume(data) }
                catch let error as LocalUploadHTTPError { self.fail(error); return }
                catch { self.fail(LocalUploadHTTPError(code: 500, message: "The upload could not be saved.")); return }
            }
            guard !self.responded, !self.processing else { return }
            if error != nil || complete {
                self.fail(LocalUploadHTTPError(code: 400, message: "The upload ended before all bytes arrived."))
            } else { self.receive() }
        }
    }

    private func consume(_ data: Data) throws {
        if request == nil {
            header.append(data)
            guard let delimiter = header.range(of: Data([13, 10, 13, 10])) else {
                if header.count > LocalVideoUploadRequest.maximumHeaderBytes {
                    throw LocalUploadHTTPError(code: 431, message: "Request headers are too large.")
                }
                return
            }
            let parsed = try LocalVideoUploadRequest.parse(header: Data(header[..<delimiter.upperBound]), token: token)
            let remainder = Data(header[delimiter.upperBound...])
            header = Data()
            request = parsed
            if parsed.isHealth {
                guard remainder.isEmpty else { throw LocalUploadHTTPError(code: 400, message: "Health requests cannot include a body.") }
                send(code: 200, reason: "OK", object: ["status": "ready", "api": "v1"])
                return
            }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gremma-upload-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            directory = folder
            let target = folder.appendingPathComponent("video.\(parsed.fileExtension)")
            guard FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw LocalUploadHTTPError(code: 500, message: "Storage is unavailable.")
            }
            destination = target
            file = try FileHandle(forWritingTo: target)
            try appendBody(remainder)
        } else { try appendBody(data) }
    }

    private func appendBody(_ data: Data) throws {
        guard let request, !request.isHealth, let file else { throw LocalUploadHTTPError(code: 400, message: "Unexpected body.") }
        guard data.count <= request.contentLength - bodyBytes else {
            throw LocalUploadHTTPError(code: 400, message: "The body exceeds Content-Length.")
        }
        try file.write(contentsOf: data)
        bodyBytes += data.count
        if bodyBytes == request.contentLength {
            try file.synchronize()
            try file.close()
            self.file = nil
            beginImport(request)
        }
    }

    private func beginImport(_ request: LocalVideoUploadRequest) {
        guard let destination, let recordedAt = request.recordedAt else {
            fail(LocalUploadHTTPError(code: 400, message: "Recording metadata is missing.")); return
        }
        processing = true
        importTask = Task { [self] in
            do {
                try Task.checkCancellation()
                let videoID = try await onVideo(destination, recordedAt, request.room)
                queue.async {
                    self.processing = false
                    self.importTask = nil
                    self.removeTemporaryFile()
                    guard !self.closed, !self.responded else { return }
                    self.send(code: 202, reason: "Accepted", object: ["status": "queued", "video_id": videoID])
                }
            } catch {
                queue.async {
                    self.processing = false
                    self.importTask = nil
                    self.removeTemporaryFile()
                    guard !self.closed, !self.responded else { return }
                    // Do not expose private paths, model output or caller diagnostics.
                    self.fail(LocalUploadHTTPError(code: 422, message: "The video could not be imported. Check its format and duration, then try again."))
                }
            }
        }
    }

    private func fail(_ error: LocalUploadHTTPError) {
        guard !closed, !responded else { return }
        send(code: error.code, reason: error.reason, object: ["error": error.message])
    }

    private func send(code: Int, reason: String, object: [String: String]) {
        guard !closed, !responded else { return }
        responded = true
        timer?.cancel(); timer = nil
        connection.send(content: Self.response(code: code, reason: reason, object: object), completion: .contentProcessed { [self] _ in close() })
        // Even a peer that stops receiving the response must release its slot.
        queue.asyncAfter(deadline: .now() + 5) { [self] in close() }
    }

    func close() {
        guard !closed else { return }
        closed = true
        timer?.cancel(); timer = nil
        importTask?.cancel()
        try? file?.close(); file = nil
        // A running import may still be copying the source. Its completion owns cleanup.
        if !processing { removeTemporaryFile() }
        connection.cancel()
        onClose()
    }

    private func removeTemporaryFile() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil; destination = nil
    }

    static func response(code: Int, reason: String, object: [String: String]) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        let headers = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        return Data(headers.utf8) + body
    }
}
