import Foundation
@MainActor
final class LocalModelService {
    let modelName = "Gemma-4-E4B-it"
    enum NotUsed: Error { case controlledValidationOnly }
    var jsonResults: [Result<String, Error>] = []
    private(set) var jsonPrompts: [String] = []
    private(set) var visionCalls = 0
    func generate(prompt: String, system: String, imageURLs: [URL], maxOutputTokens: Int) async throws -> String {
        visionCalls += 1
        throw NotUsed.controlledValidationOnly
    }
    func generateJSON(prompt: String, system: String, schema: String, maxOutputTokens: Int) async throws -> String {
        jsonPrompts.append(prompt)
        guard !jsonResults.isEmpty else { throw NotUsed.controlledValidationOnly }
        return try jsonResults.removeFirst().get()
    }
}
