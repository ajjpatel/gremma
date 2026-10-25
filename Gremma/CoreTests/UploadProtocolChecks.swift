import Foundation

@main
struct UploadProtocolChecks {
    static func main() throws {
        var checks = 0
        let token = "test-only-token-never-a-real-credential"
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label)
            checks += 1
        }
        let base = ["POST /v1/videos HTTP/1.1", "Host: gremma.local:1234", "Authorization: Bearer \(token)",
                    "Content-Type: video/mp4", "Content-Length: 123", "X-Recorded-At: 2026-10-24T09:00:00-07:00", "X-Room: Kitchen"]
        func parse(_ lines: [String]) throws -> LocalVideoUploadRequest {
            try LocalVideoUploadRequest.parse(header: Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8), token: token)
        }
        func rejects(_ lines: [String], code: Int, _ label: String) {
            do { _ = try parse(lines); preconditionFailure(label) }
            catch let error as LocalUploadHTTPError { check(error.code == code, label) }
            catch { preconditionFailure("Unexpected error: \(error)") }
        }
        let valid = try parse(base)
        check(valid.contentLength == 123 && valid.room == "Kitchen" && valid.fileExtension == "mp4", "Valid MP4 upload")
        check(valid.recordedAt != nil && !valid.isHealth, "Recording time retained")
        var changed = base; changed[3] = "Content-Type: video/quicktime"
        let quickTime = try parse(changed)
        check(quickTime.fileExtension == "mov", "QuickTime upload")
        changed = base; changed[2] = "Authorization: Bearer incorrect"
        rejects(changed, code: 401, "Invalid bearer token")
        rejects(base.filter { !$0.hasPrefix("Authorization:") }, code: 401, "Missing token")
        rejects(base + ["authorization: Bearer \(token)"], code: 400, "Duplicate authentication")
        rejects(base + ["Content-Length: 124"], code: 400, "Conflicting framing")
        rejects(base + ["Transfer-Encoding: chunked"], code: 400, "Chunked body rejected")
        rejects(base + ["Expect: 100-continue"], code: 417, "Expect rejected")
        rejects(base.filter { !$0.hasPrefix("Content-Length:") }, code: 411, "Missing length")
        changed = base; changed[4] = "Content-Length: 104857601"
        rejects(changed, code: 413, "Oversized body")
        changed = base; changed[4] = "Content-Length: -1"
        rejects(changed, code: 400, "Negative length")
        changed = base; changed[4] = "Content-Length: 0"
        rejects(changed, code: 400, "Empty body")
        changed = base; changed[3] = "Content-Type: multipart/form-data"
        rejects(changed, code: 415, "Unsupported multipart")
        changed = base; changed[5] = "X-Recorded-At: 2026-10-24T09:00:00"
        rejects(changed, code: 400, "Timezone required")
        changed = base; changed[5] = "X-Recorded-At: 2026-99-24T09:00:00Z"
        rejects(changed, code: 400, "Invalid date")
        changed = base; changed[0] = "POST /../../private HTTP/1.1"
        rejects(changed, code: 404, "Unknown path")
        changed = base; changed[0] = "GET /v1/videos HTTP/1.1"
        rejects(changed, code: 405, "Wrong method")
        changed = base; changed[6] = " X-Room: Kitchen"
        rejects(changed, code: 400, "Folded header")
        changed = base; changed[6] = "X-Room: Kitchen\nInjected"
        rejects(changed, code: 400, "Header newline")
        changed = base; changed[6] = "X-Room: " + String(repeating: "A", count: 20_000)
        rejects(changed, code: 431, "Header memory bound")
        let health = try parse(["GET /health HTTP/1.1", "Host: gremma.local", "Authorization: Bearer \(token)"])
        check(health.isHealth && health.contentLength == 0, "Authenticated health")
        check(LocalVideoUploadRequest.parseRecordedAt("2026-10-24T09:00:00.125Z") != nil, "Fractional time")
        check(LocalVideoUploadRequest.isPrivateAddress("192.168.2.4"), "Private IPv4")
        check(LocalVideoUploadRequest.isPrivateAddress("fe80::1234%en0"), "Link-local IPv6")
        check(LocalVideoUploadRequest.isPrivateAddress("::ffff:10.1.2.3"), "Mapped private IPv4")
        check(!LocalVideoUploadRequest.isPrivateAddress("8.8.8.8"), "Public IPv4 denied")
        check(!LocalVideoUploadRequest.isPrivateAddress("2001:4860:4860::8888"), "Public IPv6 denied")
        check(!LocalVideoUploadRequest.isPrivateAddress("192.168.1.999"), "Malformed IP denied")
        print("\(checks) upload protocol checks passed")
    }
}
