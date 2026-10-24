import Foundation
import UIKit

/// Explicit developer probe. Run one mode per fresh app launch to isolate native
/// constraints from prompting without a fallback overwriting the original result.
@MainActor
enum StructuredGenerationDiagnostics {
    @discardableResult
    static func run(model: LocalModelService, mode: String) async -> [String: Any] {
        let runID = UUID().uuidString.lowercased()
        let schema = #"{"type":"object","properties":{"action":{"type":"string","enum":["chat"]},"reply":{"type":"string","maxLength":40}},"required":["action","reply"],"additionalProperties":false}"#
        let system = "Return one JSON object only, with no Markdown, reasoning, or extra text. Follow this JSON schema: " + schema
        let prompt = "Greet me with the word Hello. Set action to chat."
        var value: [String: Any] = [
            "schemaVersion": 1, "runID": runID, "status": "starting",
            "startedAt": timestamp(), "mode": mode,
            "modelFilename": model.selectedModelURL?.lastPathComponent ?? "none",
            "requestedBackend": model.useGPU ? "GPU" : "CPU",
            "deviceOS": UIDevice.current.systemVersion,
            "system": system, "prompt": prompt, "schema": schema,
            "maximumOutputTokens": 512, "historyTurnCount": 0,
            "scope": "One actual-model request with fixed synthetic text. No camera, microphone, saved memories, or action handlers. Native and prompt modes use identical messages and output limits; only native response-format constraints differ.",
            "interpretation": "Execution status and response quality are separate. A report left running identifies an interrupted step, not its cause. No fallback or retry is performed."
        ]
        var directory: URL?
        var generated = false
        var generationStarted: TimeInterval?
        let oldIdleTimer = UIApplication.shared.isIdleTimerDisabled
        defer { UIApplication.shared.isIdleTimerDisabled = oldIdleTimer }
        do {
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            var location = documents.appendingPathComponent("Diagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
            var resources = URLResourceValues()
            resources.isExcludedFromBackup = true
            try location.setResourceValues(resources)
            directory = location
            try persist(value, directory: location, runID: runID)
            guard mode == "native" || mode == "prompt" else { throw ProbeError.invalidMode }
            guard !model.isBusy else { throw ProbeError.modelBusy }
            UIApplication.shared.isIdleTimerDisabled = true
            value["status"] = "running"
            value["activeStep"] = "model_load"
            try persist(value, directory: location, runID: runID)
            let loadStarted = ProcessInfo.processInfo.systemUptime
            try await model.loadModel()
            try Task.checkCancellation()
            value["loadElapsedSeconds"] = ProcessInfo.processInfo.systemUptime - loadStarted
            value["activeStep"] = "generation"
            value["generationStartedAt"] = timestamp()
            try persist(value, directory: location, runID: runID)
            generationStarted = ProcessInfo.processInfo.systemUptime
            generated = true
            let result: String
            if mode == "native" {
                result = try await model.generateJSON(prompt: prompt, system: system, schema: schema, maxOutputTokens: 512)
            } else {
                result = try await model.generate(prompt: prompt, system: system)
            }
            value["returnedText"] = result
            try Task.checkCancellation()
            value["status"] = "completed"
        } catch {
            value["status"] = error is CancellationError ? "cancelled" : "failed"
            value["error"] = error.localizedDescription
            value["errorType"] = String(reflecting: type(of: error))
        }
        if generated {
            // Snapshot this exact request before any other generation can replace it.
            value["lastRuntimeResponse"] = model.response
            value["runtime"] = runtimeDetails(model)
            value["qualityChecks"] = qualityChecks(model.response)
            value["modelReadyAfterGeneration"] = model.isReady
        }
        if let generationStarted {
            value["generationElapsedSeconds"] = ProcessInfo.processInfo.systemUptime - generationStarted
        }
        value["finishedAt"] = timestamp()
        if let directory {
            do { try persist(value, directory: directory, runID: runID) }
            catch { value["reportWriteError"] = error.localizedDescription }
        }
        return value
    }

    private static func qualityChecks(_ raw: String) -> [String: Any] {
        let parsed = raw.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        let object = parsed as? [String: Any]
        return [
            "validJSON": parsed != nil,
            "isObject": object != nil,
            "hasOnlyExpectedKeys": object.map { Set($0.keys) == Set(["action", "reply"]) } ?? false,
            "actionIsChat": object?["action"] as? String == "chat",
            "replyIsHello": object?["reply"] as? String == "Hello",
            "replyWithinSchemaLength": (object?["reply"] as? String).map { $0.count <= 40 } ?? false,
            "matchesExpectedObject": object.map {
                Set($0.keys) == Set(["action", "reply"]) && $0["action"] as? String == "chat" && $0["reply"] as? String == "Hello"
            } ?? false
        ]
    }

    private static func runtimeDetails(_ model: LocalModelService) -> [String: Any] {
        var result: [String: Any] = [:]
        if let diagnostics = model.lastGenerationDiagnostics,
           let data = try? JSONEncoder().encode(diagnostics),
           let object = try? JSONSerialization.jsonObject(with: data) {
            result["lastGenerationDiagnostics"] = object
        }
        if let metrics = model.metrics {
            var timing: [String: Any] = ["elapsedSeconds": metrics.elapsedSeconds,
                                       "characterCount": metrics.characterCount, "cancelled": metrics.cancelled]
            if let first = metrics.firstTextSeconds { timing["firstTextSeconds"] = first }
            result["lastGenerationMetrics"] = timing
        }
        return result
    }

    private static func persist(_ value: [String: Any], directory: URL, runID: String) throws {
        var value = value
        value["updatedAt"] = timestamp()
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        try data.write(to: directory.appendingPathComponent("structured-\(runID).json"), options: options)
        try data.write(to: directory.appendingPathComponent("structured-latest.json"), options: options)
    }

    private static func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }

    private enum ProbeError: LocalizedError {
        case invalidMode, modelBusy
        var errorDescription: String? {
            switch self {
            case .invalidMode: return "JSON probe mode must be native or prompt."
            case .modelBusy: return "Another model operation is running; JSON probe did not start."
            }
        }
    }
}
