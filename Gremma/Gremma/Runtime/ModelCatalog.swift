import Foundation
import LiteRTLM

enum LocalModelKind: String, Sendable {
    case chat
    case embedding
}

struct LocalModelRecord: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let kind: LocalModelKind
    let byteCount: Int64
    let supportsVision: Bool
    let maximumContextTokens: Int
    let dynamicContext: Bool
    let visionTokenBudget: Int32?

    var displayName: String { url.deletingPathExtension().lastPathComponent }
}

enum LocalModelError: LocalizedError {
    case busy
    case noChatModel
    case noEmbeddingModel
    case invalidFile(String)
    case insufficientSpace
    case visionUnavailable
    case emptyPrompt
    case emptyResponse
    case invalidEmbedding
    case invalidJSONSchema
    case invalidOutputLimit
    case invalidStructuredResponse

    var errorDescription: String? {
        switch self {
        case .busy: return "The local model is busy. Wait for the current operation, or stop it first."
        case .noChatModel: return "Import and select a Gemma .litertlm chat model first. An embedding model cannot answer questions."
        case .noEmbeddingModel: return "Import an EmbeddingGemma .litertlm model to use semantic search."
        case .invalidFile(let message): return message
        case .insufficientSpace: return "There is not enough free space to copy this model into Gremma."
        case .visionUnavailable: return "The selected model does not support images. Select a Gemma model with vision."
        case .emptyPrompt: return "Enter a question before starting inference."
        case .emptyResponse: return "The model finished without a text answer. Try a shorter question or a clearer image."
        case .invalidEmbedding: return "The embedding model returned an empty or invalid vector."
        case .invalidJSONSchema: return "The response schema must be a JSON object no larger than 64 KB."
        case .invalidOutputLimit: return "The response token limit must be between 1 and 1024."
        case .invalidStructuredResponse: return "The model returned incomplete or invalid JSON. Try a shorter observation request."
        }
    }
}

/// File and metadata work runs outside the main actor. ModelInfo opens the container;
/// it does not initialize an inference engine or prove that a model fits device memory.
enum ModelCatalog {
    static func modelDirectory() throws -> URL {
        let documents = try FileManager.default.url(for: .documentDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        var directory = documents.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return directory
    }

    static func cacheDirectory() throws -> URL {
        let caches = try FileManager.default.url(for: .cachesDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = caches.appendingPathComponent("LiteRTLM", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func inspect(_ url: URL) throws -> LocalModelRecord {
        guard url.isFileURL, url.pathExtension.lowercased() == "litertlm" else {
            throw LocalModelError.invalidFile("Choose a .litertlm model file, not a folder, archive, GGUF, or .task file.")
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let bytes = values.fileSize, bytes > 0 else {
            throw LocalModelError.invalidFile("This model file is empty or is not a regular file.")
        }
        let info = try ModelInfo(throwingModelPath: url.path)
        let kind: LocalModelKind
        if info.isEmbeddingModel() {
            kind = .embedding
        } else if info.isLlmModel() {
            kind = .chat
        } else {
            throw LocalModelError.invalidFile("LiteRT-LM cannot identify this file as a chat or embedding model.")
        }
        if let minimum = info.minRuntimeVersion,
           minimum.compare("0.18.1", options: .numeric) == .orderedDescending {
            throw LocalModelError.invalidFile("This model requires LiteRT-LM \(minimum). Gremma currently includes 0.18.1.")
        }
        let budgets = (info.visionSignatureSelection() ?? []).filter { $0 > 0 }.sorted()
        let selectedBudget = budgets.last(where: { $0 <= 256 }) ?? budgets.first
        return LocalModelRecord(url: url, kind: kind, byteCount: Int64(bytes),
            supportsVision: info.inputModalities.vision,
            maximumContextTokens: info.maxContextTokens(), dynamicContext: info.isDynamicContext(),
            visionTokenBudget: selectedBudget.flatMap(Int32.init(exactly:)))
    }

    static func scan() throws -> (records: [LocalModelRecord], rejected: [String]) {
        let directory = try modelDirectory()
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        var records: [LocalModelRecord] = []
        var rejected: [String] = []
        for url in files where url.pathExtension.lowercased() == "litertlm" {
            do { records.append(try inspect(url)) }
            catch { rejected.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        return (records.sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }, rejected)
    }

    static func importFile(_ source: URL) throws -> LocalModelRecord {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let sourceRecord = try inspect(source)
        let directory = try modelDirectory()
        if source.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL {
            return sourceRecord
        }
        let capacity = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = capacity.volumeAvailableCapacityForImportantUsage,
           available < sourceRecord.byteCount + 64 * 1024 * 1024 {
            throw LocalModelError.insufficientSpace
        }
        var destination = directory.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent(
                "\(source.deletingPathExtension().lastPathComponent)-\(UUID().uuidString.prefix(8)).litertlm")
        }
        let staging = directory.appendingPathComponent(".\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging)
        let copiedBytes = try staging.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard copiedBytes.map(Int64.init) == sourceRecord.byteCount else {
            throw LocalModelError.invalidFile("The model copy was incomplete. Please import it again.")
        }
        var backupValues = URLResourceValues()
        backupValues.isExcludedFromBackup = true
        var stagedURL = staging
        try stagedURL.setResourceValues(backupValues)
        try FileManager.default.moveItem(at: staging, to: destination)
        do {
            return try inspect(destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
