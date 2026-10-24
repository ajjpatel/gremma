// Test-only inference seam. Production coordinator and classifier code are compiled unchanged.
// Never include this file in the iPhone app target.
import Foundation
enum LocalModelError: Error { case invalidStructuredResponse }
@MainActor final class LocalModelService {
    var json = ""
    var jsonCalls = 0
    var plainReplies = ["fallback"]
    var lastSystem = ""
    func generateJSON(prompt: String, system: String, schema: String, maxOutputTokens: Int, history: [ConversationTurn]) async throws -> String {
        jsonCalls += 1; lastSystem = system; return json
    }
    func generate(prompt: String, system: String, imageURL: URL? = nil, history: [ConversationTurn] = []) async throws -> String {
        plainReplies.isEmpty ? "fallback" : plainReplies.removeFirst()
    }
}
