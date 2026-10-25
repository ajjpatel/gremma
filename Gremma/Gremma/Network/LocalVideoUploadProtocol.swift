import Foundation

struct LocalUploadHTTPError: Error, Sendable {
    let code: Int
    let message: String
    var reason: String {
        switch code {
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 411: return "Length Required"
        case 413: return "Content Too Large"
        case 415: return "Unsupported Media Type"
        case 417: return "Expectation Failed"
        case 422: return "Unprocessable Content"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 503: return "Service Unavailable"
        default: return "Internal Server Error"
        }
    }
}

/// Deliberately small HTTP/1.1 subset: one authenticated request per connection.
/// No chunked framing, pipelining, duplicate headers, multipart bodies or redirects.
struct LocalVideoUploadRequest: Sendable {
    static let maximumHeaderBytes = 16_384
    static let maximumVideoBytes = 100 * 1024 * 1024
    let isHealth: Bool
    let contentLength: Int
    let fileExtension: String
    let recordedAt: Date?
    let room: String

    static func parse(header: Data, token: String) throws -> LocalVideoUploadRequest {
        guard header.count <= maximumHeaderBytes else {
            throw LocalUploadHTTPError(code: 431, message: "Request headers are too large.")
        }
        guard let text = String(data: header, encoding: .ascii), text.hasSuffix("\r\n\r\n"),
              !text.contains("\0") else {
            throw LocalUploadHTTPError(code: 400, message: "Invalid HTTP headers.")
        }
        // Remove four bytes, not four Swift Characters (CRLF is one grapheme).
        let lines = String(decoding: header.dropLast(4), as: UTF8.self).components(separatedBy: "\r\n")
        guard let line = lines.first else { throw LocalUploadHTTPError(code: 400, message: "Missing request.") }
        let request = line.split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, request[2] == "HTTP/1.1", lines.count <= 64 else {
            throw LocalUploadHTTPError(code: 400, message: "Use HTTP/1.1 with a single request.")
        }
        var headers: [String: String] = [:]
        let allowedName = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw LocalUploadHTTPError(code: 400, message: "Invalid header.") }
            let originalName = String(line[..<colon])
            let name = originalName.lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, originalName.unicodeScalars.allSatisfy({ allowedName.contains($0) }),
                  value.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 127 }), headers[name] == nil else {
                throw LocalUploadHTTPError(code: 400, message: "Invalid or duplicate header.")
            }
            headers[name] = value
        }
        guard let host = headers["host"], !host.isEmpty else {
            throw LocalUploadHTTPError(code: 400, message: "Host is required.")
        }
        guard !token.isEmpty, let authorization = headers["authorization"],
              constantTimeEqual(authorization, "Bearer " + token) else {
            throw LocalUploadHTTPError(code: 401, message: "A valid upload token is required.")
        }
        guard headers["transfer-encoding"] == nil else {
            throw LocalUploadHTTPError(code: 400, message: "Chunked uploads are not supported. Send Content-Length.")
        }
        guard headers["expect"] == nil else {
            throw LocalUploadHTTPError(code: 417, message: "Send the body without Expect.")
        }
        let method = String(request[0]), path = String(request[1])
        guard path == "/v1/videos" || path == "/health" else {
            throw LocalUploadHTTPError(code: 404, message: "Unknown endpoint.")
        }
        guard (path == "/health" && method == "GET") || (path == "/v1/videos" && method == "POST") else {
            throw LocalUploadHTTPError(code: 405, message: "Use GET /health or POST /v1/videos.")
        }
        if path == "/health" {
            guard headers["content-length"].map({ $0 == "0" }) ?? true else {
                throw LocalUploadHTTPError(code: 400, message: "Health requests cannot include a body.")
            }
            return Self(isHealth: true, contentLength: 0, fileExtension: "", recordedAt: nil, room: "")
        }
        guard let lengthText = headers["content-length"] else {
            throw LocalUploadHTTPError(code: 411, message: "Content-Length is required.")
        }
        guard !lengthText.isEmpty, lengthText.utf8.allSatisfy({ (48...57).contains($0) }),
              let length = Int(lengthText), length > 0 else {
            throw LocalUploadHTTPError(code: 400, message: "Invalid Content-Length.")
        }
        guard length <= maximumVideoBytes else {
            throw LocalUploadHTTPError(code: 413, message: "Videos must be no larger than 100 MiB.")
        }
        let mediaType = headers["content-type"]?.lowercased()
        guard mediaType == "video/mp4" || mediaType == "video/quicktime" else {
            throw LocalUploadHTTPError(code: 415, message: "Use video/mp4 or video/quicktime with a raw video body.")
        }
        guard let recordedText = headers["x-recorded-at"], let recordedAt = parseRecordedAt(recordedText) else {
            throw LocalUploadHTTPError(code: 400, message: "X-Recorded-At must be an RFC3339 recording time with a timezone.")
        }
        let room = headers["x-room"] ?? "Unspecified room"
        guard !room.isEmpty, room.count <= 100 else {
            throw LocalUploadHTTPError(code: 400, message: "X-Room must contain 1 to 100 characters.")
        }
        return Self(isHealth: false, contentLength: length, fileExtension: mediaType == "video/mp4" ? "mp4" : "mov",
                    recordedAt: recordedAt, room: room)
    }

    static func parseRecordedAt(_ text: String) -> Date? {
        guard text.count <= 40,
              text.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }

    static func isPrivateAddress(_ original: String) -> Bool {
        let address = original.lowercased().split(separator: "%", maxSplits: 1).first.map(String.init) ?? original
        if address.hasPrefix("::ffff:") { return isPrivateAddress(String(address.dropFirst(7))) }
        if address == "::1" { return true }
        if address.contains(":") {
            guard let first = address.split(separator: ":").first, let value = UInt16(first, radix: 16) else { return false }
            return value & 0xffc0 == 0xfe80 || value & 0xfe00 == 0xfc00
        }
        let rawParts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard rawParts.count == 4, rawParts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) }) else { return false }
        let parts = rawParts.compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 10 || parts[0] == 127 || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 169 && parts[1] == 254)
    }
}
