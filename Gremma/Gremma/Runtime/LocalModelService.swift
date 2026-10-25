import Combine
import Foundation
import LiteRTLM

@MainActor
final class LocalModelService: ObservableObject {
    @Published private(set) var status = "Import a Gemma .litertlm model to begin."
    @Published private(set) var isReady = false
    @Published private(set) var isLoading = false
    @Published private(set) var isGenerating = false
    @Published private(set) var isEmbedding = false
    @Published private(set) var modelURLs: [URL] = []
    @Published private(set) var embeddingModelURLs: [URL] = []
    @Published private(set) var selectedModelURL: URL?
    @Published private(set) var selectedEmbeddingModelURL: URL?
    @Published private(set) var response = ""
    @Published private(set) var lastError: String?
    @Published private(set) var metrics: InferenceMetrics?
    @Published private(set) var lastGenerationDiagnostics: InferenceDiagnostics?
    @Published private(set) var lastLoadMemoryDiagnostics: ModelLoadMemoryDiagnostics?
    @Published private(set) var models: [LocalModelRecord] = []
    @Published private(set) var requiresRestart = false
    @Published var useGPU = true

    var isBusy: Bool { isLoading || isGenerating || isEmbedding }
    var hasEmbeddingModel: Bool { selectedEmbeddingModelURL != nil }
    var modelName: String { selectedModelURL?.deletingPathExtension().lastPathComponent ?? "No model selected" }
    var runtimeFailureMessage: String? { requiresRestart ? RuntimeRecoveryError.restartRequired.localizedDescription : nil }

    private var engine: Engine?
    private var loadedModelURL: URL?
    private var loadedWithGPU: Bool?
    private var loadedContextTokenLimit: Int?
    private var generationTask: Task<String, Error>?
    private var generationControl: GenerationControl?
    private var generationID: UUID?
    private var unloadRequested = false
    private var activeWaitCancellation: (() -> Void)?
    // A stuck native operation cannot be killed safely in-process. Keep one failed
    // engine/worker alive until app exit and prohibit allocating a replacement.
    private var quarantinedResources: [Any] = []
    private var retiredResources: [Any] = []
    private var runtimeDiagnostics: RuntimeOperationDiagnostics?
    private var runtimeOperationID: UUID?
    private var lastRuntimeWriteAt: Date?
    private let selectionKey = "Aster.selectedChatModelFilename"
    private let embeddingSelectionKey = "Aster.selectedEmbeddingModelFilename"

    /// Call from the app's initial .task and after copying a model through Files/USB.
    func refreshModels() async {
        guard !isBusy else { return }
        isLoading = true
        defer {
            isLoading = false
            finishPendingUnload()
        }
        do {
            let result = try await Task.detached(priority: .utility) { try ModelCatalog.scan() }.value
            applyCatalog(result.records)
            if !result.rejected.isEmpty {
                lastError = result.rejected.joined(separator: "\n")
            }
            if !isReady && !requiresRestart {
                status = selectedModelURL == nil ? "Import a Gemma .litertlm model to begin." : "Model available. Load it to begin."
            }
        } catch { record(error) }
    }

    func importModel(from url: URL) async throws {
        guard !requiresRestart else { throw RuntimeRecoveryError.restartRequired }
        guard !isBusy else { throw LocalModelError.busy }
        isLoading = true
        status = "Copying and checking model…"
        lastError = nil
        defer {
            isLoading = false
            finishPendingUnload()
        }
        do {
            let imported = try await Task.detached(priority: .userInitiated) {
                try ModelCatalog.importFile(url)
            }.value
            models.removeAll { $0.url == imported.url }
            models.append(imported)
            applyCatalog(models)
            if imported.kind == .chat {
                retireEngineReference()
                loadedModelURL = nil
                isReady = false
                selectedModelURL = imported.url
                UserDefaults.standard.set(imported.url.lastPathComponent, forKey: selectionKey)
                status = "Chat model imported. Load it to begin."
            } else {
                selectedEmbeddingModelURL = imported.url
                UserDefaults.standard.set(imported.url.lastPathComponent, forKey: embeddingSelectionKey)
                status = "Embedding model imported for semantic search."
            }
        } catch {
            record(error)
            throw error
        }
    }

    func selectModel(_ url: URL) {
        guard !requiresRestart, !isBusy, Self.isE4B(url), models.contains(where: { $0.url == url && $0.kind == .chat }) else { return }
        guard selectedModelURL != url else { return }
        retireEngineReference()
        loadedModelURL = nil
        isReady = false
        selectedModelURL = url
        UserDefaults.standard.set(url.lastPathComponent, forKey: selectionKey)
        status = "Model selected. Load it to begin."
    }

    func selectEmbeddingModel(_ url: URL) {
        guard !isBusy, models.contains(where: { $0.url == url && $0.kind == .embedding }) else { return }
        selectedEmbeddingModelURL = url
        UserDefaults.standard.set(url.lastPathComponent, forKey: embeddingSelectionKey)
    }

    func loadModel() async throws {
        guard !requiresRestart else { throw RuntimeRecoveryError.restartRequired }
        guard !isBusy else { throw LocalModelError.busy }
        guard let url = selectedModelURL,
              let model = models.first(where: { $0.url == url && $0.kind == .chat }) else {
            throw LocalModelError.noChatModel
        }
        guard Self.isE4B(url) else { throw LocalModelError.invalidFile("Gremma uses Gemma E4B. Import or select the E4B model.") }
        if engine != nil, loadedModelURL == url, loadedWithGPU == useGPU, isReady { return }
        isLoading = true
        isReady = false
        status = "Loading \(model.displayName)…"
        lastError = nil
        retireEngineReference()
        loadedModelURL = nil
        let loadStartedAt = Date()
        let operationID = beginRuntimeOperation(kind: "load", phase: "initializing_engine")
        lastLoadMemoryDiagnostics = ModelLoadMemoryDiagnostics(startedAt: loadStartedAt,
            availableBeforeBytes: RuntimeMemory.availableBytes)
        defer {
            isLoading = false
            activeWaitCancellation = nil
            if unloadRequested {
                releaseEngine()
                unloadRequested = false
            }
            lastLoadMemoryDiagnostics?.availableAfterBytes = RuntimeMemory.availableBytes
            lastLoadMemoryDiagnostics?.elapsedSeconds = Date().timeIntervalSince(loadStartedAt)
            finishRuntimeOperation(id: operationID)
        }
        do {
            try await disposeRetiredResources(operationID: operationID)
            try Task.checkCancellation()
            if unloadRequested { throw CancellationError() }
            updateRuntimeOperation(id: operationID, phase: "initializing_engine")
            let cache = try ModelCatalog.cacheDirectory()
            let gpu = useGPU
            let contextLimit = model.dynamicContext
                ? (model.maximumContextTokens > 0 ? min(2048, model.maximumContextTokens) : 2048) : nil
            let config = try EngineConfig(modelPath: url.path,
                backend: gpu ? .gpu : .cpu(threadCount: 4),
                visionBackend: model.supportsVision ? .cpu(threadCount: 2) : nil,
                maxNumTokens: contextLimit, cacheDir: cache.path)
            ExperimentalFlags.optIntoExperimentalAPIs()
            ExperimentalFlags.enableBenchmark = true
            let candidate = Engine(engineConfig: config)
            let worker = Task.detached(priority: .userInitiated) { try await candidate.initialize() }
            let gate = RuntimeDeadlineGate<Void>(maximumDuration: 90, cancellationGrace: 4)
            activeWaitCancellation = { gate.requestCancellation() }
            do {
                try await gate.wait(for: worker)
            } catch let deadline as RuntimeDeadlineError where deadline.nativeStillRunning {
                quarantine(candidate, worker: worker, operationID: operationID, reason: deadline.reason)
                throw RuntimeRecoveryError.restartRequired
            } catch {
                // Initialization may have completed during cancellation. Defer any
                // native destruction to the bounded disposal worker below.
                retiredResources.append(candidate)
                throw error
            }
            // Retain even if caller cancellation wins immediately after the wait.
            retiredResources.append(candidate)
            try Task.checkCancellation()
            if unloadRequested { throw CancellationError() }
            engine = candidate
            retiredResources.removeAll { ($0 as? Engine) === candidate }
            loadedModelURL = url
            loadedWithGPU = gpu
            loadedContextTokenLimit = contextLimit ?? (model.maximumContextTokens > 0 ? model.maximumContextTokens : nil)
            isReady = true
            status = "Ready · \(gpu ? "GPU" : "CPU")\(model.supportsVision ? " + CPU vision" : "")"
            updateRuntimeOperation(id: operationID, phase: "completed")
        } catch {
            recordRuntimeFailure(error, id: operationID)
            record(error)
            throw error
        }
    }

    /// Requests bounded cancellation. The active wait owns eventual cleanup;
    /// never join a potentially stuck native task from the UI's unload action.
    func unloadModel() async {
        guard !requiresRestart else { return }
        unloadRequested = true
        cancel()
        if isBusy {
            status = "Stopping the current model operation…"
            return
        }
        isLoading = true // Reserve the runtime while native destruction runs.
        releaseEngine()
        status = "Unloading the local model…"
        let operationID = beginRuntimeOperation(kind: "unload", phase: "disposing_previous_engine")
        defer {
            isLoading = false
            activeWaitCancellation = nil
            unloadRequested = false
            finishRuntimeOperation(id: operationID)
        }
        do {
            try await disposeRetiredResources(operationID: operationID)
            status = "Model unloaded."
            updateRuntimeOperation(id: operationID, phase: "completed")
        } catch {
            recordRuntimeFailure(error, id: operationID)
            record(error)
        }
    }

    func generate(prompt: String, system: String, imageURL: URL? = nil,
                  history: [ConversationTurn] = []) async throws -> String {
        try await performGeneration(prompt: prompt, system: system, imageURLs: imageURL.map { [$0] } ?? [],
            jsonSchema: nil, maxOutputTokens: 512, history: history)
    }

    /// A bounded chronological sequence for action understanding, using one E4B request.
    func generate(prompt: String, system: String, imageURLs: [URL],
                  maxOutputTokens: Int = 256) async throws -> String {
        guard (1...1024).contains(maxOutputTokens) else { throw LocalModelError.invalidOutputLimit }
        return try await performGeneration(prompt: prompt, system: system, imageURLs: imageURLs,
            jsonSchema: nil, maxOutputTokens: maxOutputTokens, history: [])
    }

    /// Opt-in native LLGuidance JSON-schema constrained decoding. The SDK can still
    /// stop at its output/context limit; an incomplete JSON result throws rather than
    /// being silently repaired. Caller must also validate its domain-specific fields.
    func generateJSON(prompt: String, system: String, imageURL: URL? = nil,
                      schema: String, maxOutputTokens: Int = 768,
                      history: [ConversationTurn] = []) async throws -> String {
        guard let schemaData = schema.data(using: .utf8), schemaData.count <= 65_536,
              (try? JSONSerialization.jsonObject(with: schemaData)) is [String: Any] else {
            throw LocalModelError.invalidJSONSchema
        }
        guard (1...1024).contains(maxOutputTokens) else { throw LocalModelError.invalidOutputLimit }
        return try await performGeneration(prompt: prompt, system: system, imageURLs: imageURL.map { [$0] } ?? [],
            jsonSchema: schema, maxOutputTokens: maxOutputTokens, history: history)
    }

    private func performGeneration(prompt: String, system: String, imageURLs: [URL],
                                   jsonSchema: String?, maxOutputTokens: Int,
                                   history: [ConversationTurn]) async throws -> String {
        guard !requiresRestart else { throw RuntimeRecoveryError.restartRequired }
        guard !isBusy else { throw LocalModelError.busy }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalModelError.emptyPrompt
        }
        if !isReady { try await loadModel() }
        guard !isBusy, let engine,
              let model = models.first(where: { $0.url == loadedModelURL }) else {
            throw LocalModelError.noChatModel
        }
        guard imageURLs.count <= 6 else { throw LocalModelError.invalidFile("Use at most six ordered video frames per request.") }
        for imageURL in imageURLs {
            guard model.supportsVision else { throw LocalModelError.visionUnavailable }
            guard imageURL.isFileURL, FileManager.default.isReadableFile(atPath: imageURL.path) else {
                throw LocalModelError.invalidFile("The captured image is no longer available. Please capture it again.")
            }
        }
        let id = UUID()
        let control = GenerationControl()
        let gate = RuntimeDeadlineGate<String>(maximumDuration: 90, noProgressDuration: 45, cancellationGrace: 4)
        let start = Date()
        let startedUptime = ProcessInfo.processInfo.systemUptime
        generationID = id
        generationControl = control
        activeWaitCancellation = { gate.requestCancellation() }
        isGenerating = true
        response = ""
        metrics = nil
        lastError = nil
        lastGenerationDiagnostics = InferenceDiagnostics(requestID: id, startedAt: start,
            constrainedJSON: jsonSchema != nil, promptCharacterCount: prompt.count,
            systemCharacterCount: system.count, includesImage: !imageURLs.isEmpty,
            historyTurnCount: history.count, historyCharacterCount: history.reduce(0) { $0 + $1.text.count },
            schemaByteCount: jsonSchema?.utf8.count ?? 0, contextTokenLimit: loadedContextTokenLimit,
            maximumOutputTokens: maxOutputTokens)
        status = imageURLs.isEmpty ? "Thinking locally…" : "Looking at the image locally…"
        _ = beginRuntimeOperation(kind: imageURLs.isEmpty ? "text_generation" : "vision_generation",
                                  phase: "creating_conversation", id: id)
        // This copy belongs to the uncancelled worker, not the caller's withImage
        // scope, which may end after a deadline while native prefill is still alive.
        var copiedImages: [URL] = []
        do {
            for (index, imageURL) in imageURLs.enumerated() {
                let destination = FileManager.default.temporaryDirectory.appendingPathComponent("gremma-runtime-\(id.uuidString)-\(index).jpg")
                try FileManager.default.copyItem(at: imageURL, to: destination)
                copiedImages.append(destination)
            }
        } catch {
            for url in copiedImages { try? FileManager.default.removeItem(at: url) }
            generationID = nil; generationControl = nil; activeWaitCancellation = nil; isGenerating = false
            recordRuntimeFailure(error, id: id); finishRuntimeOperation(id: id)
            record(error)
            throw error
        }
        let retainedImageURLs = copiedImages
        let task = Task.detached(priority: .userInitiated) { [weak self] () throws -> String in
            defer { for url in retainedImageURLs { try? FileManager.default.removeItem(at: url) } }
            let nativeWork: () async throws -> String = {
            let responseFormat = try jsonSchema.map { try ResponseFormat.json(schema: $0) }
            let sampler = try SamplerConfig(topK: 40, topP: 0.9, temperature: 0.2)
            let initialMessages = history.map { turn in
                Message(turn.text, role: turn.role == .user ? .user : .model)
            }
            let configuration = ConversationConfig(
                systemMessage: system.isEmpty ? nil : Message(system, role: .system),
                initialMessages: initialMessages,
                samplerConfig: sampler,
                thinkingConfig: ThinkingConfig(enableThinking: false),
                automaticToolCalling: false,
                enableResponseFormat: responseFormat != nil,
                visualTokenBudget: model.visionTokenBudget)
            let conversation = try await engine.createConversation(with: configuration)
            control.attach(conversation)
            if control.isCancelled { throw CancellationError() }
            gate.noteProgress()
            await self?.setGenerationPhase("streaming", id: id)
            var contents: [Content] = []
            for (index, url) in retainedImageURLs.enumerated() {
                // The caller defines timing and roles. A request may contain a
                // scene-context image followed by chronological detail crops.
                contents.append(.text("Image \(index + 1):"))
                contents.append(.imageFile(url.path))
            }
            contents.append(.text(prompt))
            let stream = conversation.sendMessageStream(Message(contents: contents), maxOutputTokens: maxOutputTokens,
                thinkingConfig: ThinkingConfig(enableThinking: false), responseFormat: responseFormat)
            // Handles a cancellation that raced with starting the native stream.
            if control.isCancelled { control.requestCancellation() }
            var text = ""
            var firstText: TimeInterval?
            var lastText: TimeInterval?
            do {
                for try await chunk in stream {
                    gate.noteProgress()
                    if control.isCancelled { continue }
                    let textParts = chunk.contents.compactMap { content -> String? in
                        if case .text(let part) = content { return part }
                        return nil
                    }
                    await self?.noteStreamChunk(id: id, textParts: textParts.count, includesChannels: !chunk.channels.isEmpty)
                    // SDK toString inserts a space between content items. Preserve exact
                    // generated bytes for constrained JSON, including strings/numbers.
                    let delta = responseFormat == nil ? chunk.toString : textParts.joined()
                    guard !delta.isEmpty else { continue }
                    if firstText == nil { firstText = Date().timeIntervalSince(start) }
                    lastText = Date().timeIntervalSince(start)
                    text += delta
                    await self?.publish(text: text, firstText: firstText, start: start, id: id, startedUptime: startedUptime, lastText: lastText)
                }
            } catch {
                if control.isCancelled { throw CancellationError() }
                throw error
            }
            if control.isCancelled { throw CancellationError() }
            await self?.setGenerationPhase("validating_response", id: id)
            let validJSON = text.data(using: .utf8).map {
                (try? JSONSerialization.jsonObject(with: $0)) != nil
            } ?? false
            await self?.recordGenerationCompletion(id: id, validJSON: validJSON,
                nativeKVTokenCount: try? conversation.getTokenCount(), characterCount: text.count)
            if responseFormat != nil, !validJSON { throw LocalModelError.invalidStructuredResponse }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LocalModelError.emptyResponse
            }
            let benchmark = try? conversation.getBenchmarkInfo()
            await self?.publish(text: text, firstText: firstText, start: start, id: id,
                startedUptime: startedUptime, lastText: lastText,
                outputTokens: benchmark?.lastDecodeTokenCount,
                decodeRate: benchmark?.lastDecodeTokensPerSecond,
                nativeFirstToken: benchmark?.timeToFirstTokenInSecond)
            return text
            }
            do {
                let result = try await nativeWork()
                control.detach()
                await control.waitForCancellationDrain()
                return result
            } catch {
                control.detach()
                await control.waitForCancellationDrain()
                throw error
            }
        }
        generationTask = task
        defer {
            if generationID == id {
                generationTask = nil
                generationControl = nil
                generationID = nil
                activeWaitCancellation = nil
                isGenerating = false
                if unloadRequested {
                    releaseEngine()
                    unloadRequested = false
                }
            }
            finishRuntimeOperation(id: id)
        }
        do {
            let result = try await gate.wait(for: task, onCancellation: { control.requestCancellation() })
            status = "Ready · answered on this iPhone"
            setGenerationPhase("completed", id: id)
            lastGenerationDiagnostics?.availableProcessMemoryAtEndBytes = RuntimeMemory.availableBytes
            return result
        } catch {
            if let deadline = error as? RuntimeDeadlineError, deadline.nativeStillRunning {
                quarantine(engine, worker: task, operationID: id, reason: deadline.reason)
                lastGenerationDiagnostics?.engineInvalidated = true
                lastGenerationDiagnostics?.errorType = String(reflecting: type(of: error))
                lastGenerationDiagnostics?.phase = "quarantined"
                lastGenerationDiagnostics?.elapsedSeconds = Date().timeIntervalSince(start)
                persistRuntimeDiagnostics(force: true)
                throw RuntimeRecoveryError.restartRequired
            }
            recordRuntimeFailure(error, id: id)
            if lastGenerationDiagnostics?.requestID == id {
                lastGenerationDiagnostics?.elapsedSeconds = Date().timeIntervalSince(start)
                lastGenerationDiagnostics?.errorType = String(reflecting: type(of: error))
                lastGenerationDiagnostics?.availableProcessMemoryAtEndBytes = RuntimeMemory.availableBytes
            }
            if error is CancellationError {
                setGenerationPhase("cancelled", id: id)
                metrics = InferenceMetrics(elapsedSeconds: Date().timeIntervalSince(start),
                    firstTextSeconds: metrics?.firstTextSeconds, characterCount: response.count, cancelled: true)
                status = "Stopped"
                throw CancellationError()
            }
            setGenerationPhase("failed", id: id)
            if Self.invalidatesEngine(error) || error is RuntimeDeadlineError {
                // The worker has returned from its stream before reaching this catch.
                // Drop our reference only: the SDK keeps native state alive until any
                // final callback releases its own conversation/engine references.
                // A failed native invocation can leave an arena unusable for later calls.
                releaseEngine()
                lastGenerationDiagnostics?.engineInvalidated = true
            }
            record(error)
            throw error
        }
    }

    private static func invalidatesEngine(_ error: Error) -> Bool {
        guard let native = error as? LiteRTLMError else { return false }
        switch native {
        case .engine(.notInitialized), .engine(.failedToCreateConversation),
             .engine(.failedToCreateSessionConfig), .engine(.failedToCreateConversationConfig),
             .conversation(.notAlive), .conversation(.invalidResponse),
             .conversation(.failedToStartStream):
            return true
        default:
            // Schema, message, and completed-response validation failures do not
            // establish a broken inference engine and must not discard a usable one.
            return false
        }
    }

    func cancel() {
        if requiresRestart { status = RuntimeRecoveryError.restartRequired.localizedDescription; return }
        if let activeWaitCancellation {
            status = "Stopping…"
            if let id = runtimeOperationID { updateRuntimeOperation(id: id, phase: "cancelling") }
            activeWaitCancellation()
            return
        }
        guard let generationControl else {
            if isLoading || isEmbedding {
                unloadRequested = true
                status = "Stopping after the current model operation finishes…"
            }
            return
        }
        status = "Stopping…"
        generationControl.requestCancellation()
    }

    /// Text retrieval embeddings, using the model card's asymmetric query/document
    /// prefixes. Chat and embedding engines are never intentionally resident together.
    /// Native embedding is synchronous on its own actor and cannot be interrupted mid-call.
    func embed(text: String, isQuery: Bool) async throws -> [Float] {
        guard !requiresRestart else { throw RuntimeRecoveryError.restartRequired }
        guard !isBusy else { throw LocalModelError.busy }
        guard let url = selectedEmbeddingModelURL else { throw LocalModelError.noEmbeddingModel }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalModelError.emptyPrompt
        }
        isEmbedding = true
        lastError = nil
        releaseEngine()
        status = "Computing semantic embedding locally…"
        let operationID = beginRuntimeOperation(kind: "embedding", phase: "initializing_embedding")
        defer {
            isEmbedding = false
            activeWaitCancellation = nil
            if unloadRequested {
                releaseEngine()
                unloadRequested = false
            }
            finishRuntimeOperation(id: operationID)
        }
        try await disposeRetiredResources(operationID: operationID)
        try Task.checkCancellation()
        if unloadRequested { throw CancellationError() }
        updateRuntimeOperation(id: operationID, phase: "initializing_embedding")
        let embedding = EmbeddingEngine(config: EmbeddingEngineConfig(modelPath: url.path,
            backend: .cpu(threadCount: 4), cacheDir: try ModelCatalog.cacheDirectory().path))
        let worker = Task.detached(priority: .userInitiated) { () throws -> [Float] in
            do {
                try await embedding.initialize()
                let prefixed = isQuery ? "task: search result | query: \(text)" : "title: none | text: \(text)"
                let result = try await embedding.computeEmbedding(contents: [.text(prefixed)],
                    options: EmbeddingOptions(normalize: true))
                await embedding.close()
                guard !result.embedding.isEmpty, result.embedding.allSatisfy({ $0.isFinite }),
                      result.embedding.contains(where: { $0 != 0 }) else { throw LocalModelError.invalidEmbedding }
                return result.embedding
            } catch {
                await embedding.close()
                throw error
            }
        }
        let gate = RuntimeDeadlineGate<[Float]>(maximumDuration: 90, cancellationGrace: 4)
        activeWaitCancellation = { gate.requestCancellation() }
        do {
            let result = try await gate.wait(for: worker)
            try Task.checkCancellation()
            if unloadRequested { throw CancellationError() }
            status = "Embedding ready. Chat will reload when needed."
            updateRuntimeOperation(id: operationID, phase: "completed")
            return result
        } catch {
            if let deadline = error as? RuntimeDeadlineError, deadline.nativeStillRunning {
                quarantine(embedding, worker: worker, operationID: operationID, reason: deadline.reason)
                throw RuntimeRecoveryError.restartRequired
            }
            recordRuntimeFailure(error, id: operationID)
            record(error)
            throw error
        }
    }

    static func isE4B(_ url: URL) -> Bool { url.lastPathComponent.lowercased().contains("e4b") }

    private func applyCatalog(_ records: [LocalModelRecord]) {
        models = records.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        modelURLs = models.filter { $0.kind == .chat && Self.isE4B($0.url) }.map(\.url)
        embeddingModelURLs = models.filter { $0.kind == .embedding }.map(\.url)
        if let loadedModelURL, !modelURLs.contains(loadedModelURL) {
            releaseEngine()
        }
        if !modelURLs.contains(where: { $0 == selectedModelURL }) {
            let saved = UserDefaults.standard.string(forKey: selectionKey)
            selectedModelURL = modelURLs.first(where: { $0.lastPathComponent == saved }) ?? modelURLs.first
        }
        if !embeddingModelURLs.contains(where: { $0 == selectedEmbeddingModelURL }) {
            let saved = UserDefaults.standard.string(forKey: embeddingSelectionKey)
            selectedEmbeddingModelURL = embeddingModelURLs.first(where: { $0.lastPathComponent == saved }) ?? embeddingModelURLs.first
        }
    }

    private func publish(text: String, firstText: TimeInterval?, start: Date, id: UUID,
                         startedUptime: TimeInterval, lastText: TimeInterval?,
                         outputTokens: Int? = nil, decodeRate: Double? = nil, nativeFirstToken: Double? = nil) {
        guard generationID == id, !requiresRestart, generationControl?.isCancelled != true else { return }
        response = text
        metrics = InferenceMetrics(elapsedSeconds: Date().timeIntervalSince(start),
            firstTextSeconds: firstText, characterCount: text.count, cancelled: false,
            startedUptime: startedUptime, lastTextSeconds: lastText, outputTokenCount: outputTokens,
            decodeTokensPerSecond: decodeRate, nativeFirstTokenSeconds: nativeFirstToken)
        if lastGenerationDiagnostics?.requestID == id {
            lastGenerationDiagnostics?.responseCharacterCount = text.count
            lastGenerationDiagnostics?.elapsedSeconds = Date().timeIntervalSince(start)
        }
    }

    private func setGenerationPhase(_ phase: String, id: UUID) {
        guard generationID == id, !requiresRestart, lastGenerationDiagnostics?.requestID == id else { return }
        lastGenerationDiagnostics?.phase = phase
        updateRuntimeOperation(id: id, phase: phase)
    }

    private func noteStreamChunk(id: UUID, textParts: Int, includesChannels: Bool) {
        guard generationID == id, !requiresRestart, lastGenerationDiagnostics?.requestID == id else { return }
        lastGenerationDiagnostics?.streamChunkCount += 1
        lastGenerationDiagnostics?.textPartCount += textParts
        if textParts > 1 { lastGenerationDiagnostics?.multipleTextPartChunks += 1 }
        if includesChannels { lastGenerationDiagnostics?.channelChunks += 1 }
        persistRuntimeDiagnostics()
    }

    private func recordGenerationCompletion(id: UUID, validJSON: Bool, nativeKVTokenCount: Int?, characterCount: Int) {
        guard generationID == id, !requiresRestart, lastGenerationDiagnostics?.requestID == id else { return }
        lastGenerationDiagnostics?.returnedValidJSON = validJSON
        lastGenerationDiagnostics?.nativeKVTokenCount = nativeKVTokenCount
        lastGenerationDiagnostics?.responseCharacterCount = characterCount
        if let startedAt = lastGenerationDiagnostics?.startedAt {
            lastGenerationDiagnostics?.elapsedSeconds = Date().timeIntervalSince(startedAt)
        }
    }

    private func releaseEngine() {
        retireEngineReference()
        loadedModelURL = nil
        loadedWithGPU = nil
        loadedContextTokenLimit = nil
        isReady = false
        status = requiresRestart ? RuntimeRecoveryError.restartRequired.localizedDescription : "Model unloaded."
    }

    private func retireEngineReference() {
        if let engine { retiredResources.append(engine) }
        engine = nil
    }

    /// Engine.deinit calls native deletion synchronously. Transfer the final strong
    /// reference to a worker and finish disposal before allocating another engine.
    private func disposeRetiredResources(operationID: UUID) async throws {
        guard !retiredResources.isEmpty else { return }
        let disposal = NativeResourceDisposal(resources: retiredResources)
        retiredResources.removeAll()
        updateRuntimeOperation(id: operationID, phase: "disposing_previous_engine")
        let worker = Task.detached(priority: .userInitiated) { () throws -> Void in disposal.dispose() }
        let gate = RuntimeDeadlineGate<Void>(maximumDuration: 30, cancellationGrace: 4)
        activeWaitCancellation = { gate.requestCancellation() }
        do {
            try await gate.wait(for: worker)
        } catch let deadline as RuntimeDeadlineError where deadline.nativeStillRunning {
            quarantine(disposal, worker: worker, operationID: operationID, reason: deadline.reason)
            throw RuntimeRecoveryError.restartRequired
        }
    }

    private func finishPendingUnload() {
        if unloadRequested {
            releaseEngine()
            unloadRequested = false
        }
    }

    private func record(_ error: Error) {
        lastError = error.localizedDescription
        status = requiresRestart ? RuntimeRecoveryError.restartRequired.localizedDescription
            : (error is CancellationError ? "Stopped" : "Model operation failed")
    }

    private func quarantine(_ resource: Any, worker: Any, operationID: UUID, reason: RuntimeDeadlineReason) {
        quarantinedResources.append(resource)
        quarantinedResources.append(worker)
        requiresRestart = true
        releaseEngine()
        lastError = RuntimeRecoveryError.restartRequired.localizedDescription
        if runtimeOperationID == operationID {
            let previousPhase = runtimeDiagnostics?.phase
            runtimeDiagnostics?.requiresRestart = true
            runtimeDiagnostics?.deadlineReason = reason
            if runtimeDiagnostics?.phaseBeforeFailure == nil {
                runtimeDiagnostics?.phaseBeforeFailure = previousPhase
            }
            runtimeDiagnostics?.phase = "quarantined"
            runtimeDiagnostics?.errorType = "RuntimeDeadlineError"
            persistRuntimeDiagnostics(force: true)
        }
    }

    @discardableResult
    private func beginRuntimeOperation(kind: String, phase: String, id: UUID = UUID()) -> UUID {
        let now = Date()
        runtimeOperationID = id
        runtimeDiagnostics = RuntimeOperationDiagnostics(operationID: id, kind: kind,
            startedAt: now, updatedAt: now, phase: phase)
        lastRuntimeWriteAt = nil
        persistRuntimeDiagnostics(force: true)
        return id
    }

    private func updateRuntimeOperation(id: UUID, phase: String) {
        guard runtimeOperationID == id, !requiresRestart else { return }
        runtimeDiagnostics?.phase = phase
        persistRuntimeDiagnostics(force: true)
    }

    private func recordRuntimeFailure(_ error: Error, id: UUID) {
        guard runtimeOperationID == id else { return }
        let previousPhase = runtimeDiagnostics?.phase
        runtimeDiagnostics?.errorType = String(reflecting: type(of: error))
        if runtimeDiagnostics?.phaseBeforeFailure == nil {
            runtimeDiagnostics?.phaseBeforeFailure = previousPhase
        }
        if let deadline = error as? RuntimeDeadlineError { runtimeDiagnostics?.deadlineReason = deadline.reason }
        if !requiresRestart { runtimeDiagnostics?.phase = error is CancellationError ? "cancelled" : "failed" }
        persistRuntimeDiagnostics(force: true)
    }

    private func finishRuntimeOperation(id: UUID) {
        guard runtimeOperationID == id else { return }
        persistRuntimeDiagnostics(force: true)
        runtimeOperationID = nil
    }

    private func persistRuntimeDiagnostics(force: Bool = false) {
        guard runtimeOperationID != nil else { return }
        let now = Date()
        if !force, let lastRuntimeWriteAt, now.timeIntervalSince(lastRuntimeWriteAt) < 1 { return }
        runtimeDiagnostics?.updatedAt = now
        if let start = runtimeDiagnostics?.startedAt { runtimeDiagnostics?.elapsedSeconds = now.timeIntervalSince(start) }
        runtimeDiagnostics?.availableProcessMemoryBytes = RuntimeMemory.availableBytes
        if runtimeDiagnostics?.operationID == lastGenerationDiagnostics?.requestID {
            runtimeDiagnostics?.generation = lastGenerationDiagnostics
        }
        try? runtimeDiagnostics?.persist()
        lastRuntimeWriteAt = now
    }
}
