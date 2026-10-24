// Test-only inference seam. Production extraction, decoding and grounding are unchanged.
import Foundation

enum LocalModelError: Error { case invalidStructuredResponse }

@MainActor
final class LocalModelService {
    let description: String
    var replies: [(text: String, nativeInvalid: Bool)]
    var response = ""
    var requests: [String] = []
    var visionRequest = ""

    init(description: String, replies: [String], nativeInvalidFirst: Bool = false) {
        self.description = description
        self.replies = replies.enumerated().map { ($0.element, nativeInvalidFirst && $0.offset == 0) }
    }
    func generate(prompt: String, system: String, imageURL: URL? = nil) async throws -> String {
        visionRequest = prompt
        response = description
        return description
    }
    func generateJSON(prompt: String, system: String, schema: String, maxOutputTokens: Int) async throws -> String {
        requests.append(prompt)
        precondition(!replies.isEmpty, "Extraction exceeded the bounded supplied replies")
        let next = replies.removeFirst()
        response = next.text
        if next.nativeInvalid { throw LocalModelError.invalidStructuredResponse }
        return next.text
    }
}
