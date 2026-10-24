import Foundation
import UIKit
import Darwin

/// Explicit developer smoke test. The caller must opt in (for example with --gremma-diagnostics).
/// Uses only bundled facts and generated images; never reads or writes saved user observations.
@MainActor
enum DeviceDiagnostics {
    @discardableResult
    static func run(model: LocalModelService) async -> [String: Any] {
        let runID = UUID().uuidString.lowercased()
        var report: DiagnosticReport?
        do {
            let recorder = try DiagnosticReport(runID: runID)
            report = recorder
            try recorder.persist()
            let previousIdleTimerSetting = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimerSetting }

            guard !model.isBusy else {
                throw DiagnosticError.modelBusy
            }

            _ = try await recorder.step("model_catalog") {
                await model.refreshModels()
                try Task.checkCancellation()
                var details: [String: Any] = [
                    "availableChatModels": model.modelURLs.map(\.lastPathComponent),
                    "availableEmbeddingModels": model.embeddingModelURLs.map(\.lastPathComponent),
                    "selectedModel": modelDetails(model)
                ]
                if let warning = model.lastError { details["catalogWarning"] = warning }
                return details
            }
            recorder.value["model"] = modelDetails(model)

            let shapeURL = recorder.directory.appendingPathComponent("synthetic-shapes-\(runID).png")
            let expiryURL = recorder.directory.appendingPathComponent("synthetic-expiry-\(runID).png")
            let fixturesReady = try await recorder.step("generate_synthetic_fixtures") {
                try shapesImage().write(to: shapeURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                try expiryImage().write(to: expiryURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                return [
                    "synthetic": true,
                    "shapesImageFilename": shapeURL.lastPathComponent,
                    "expiryImageFilename": expiryURL.lastPathComponent,
                    "shapesGroundTruth": "A red square on the left and a blue circle on the right, on white.",
                    "expiryGroundTruth": "DIAGNOSTIC LABEL\nEXP 2027-04-30",
                    "imagePixels": ["width": 768, "height": 512]
                ]
            }

            // Run OCR before loading a large model so it remains measurable if model loading terminates the app.
            if fixturesReady {
                _ = try await recorder.step("apple_vision_ocr") {
                    let imageData = try Data(contentsOf: expiryURL)
                    let result = try await ReadingService().recognize(imageData: imageData)
                    try Task.checkCancellation()
                    let interpretation = ReadingInterpreter.describe(result, mode: .expiry)
                    return [
                        "engineCompleted": true,
                        "engine": "Apple Vision VNRecognizeTextRequest, accurate, en-US, language correction disabled",
                        "synthetic": true,
                        "rawText": result.rawText,
                        "lines": result.lines.map { line -> [String: Any] in
                            ["text": line.text, "confidence": line.confidence,
                             "bounds": ["x": line.bounds.x, "y": line.bounds.y,
                                        "width": line.bounds.width, "height": line.bounds.height]]
                        },
                        "interpretation": interpretation.spokenText,
                        "needsRetake": interpretation.needsRetake,
                        "extractedFields": interpretation.fields.map { ["label": $0.label, "value": $0.value] },
                        "qualityChecks": [
                            "kind": "literal synthetic-fixture checks, not real-world OCR validation",
                            "rawContainsExactExpectedDate": result.rawText.contains("2027-04-30"),
                            "extractionContainsExactExpectedDate": interpretation.fields.contains { $0.value.contains("2027-04-30") },
                            "extractionDidNotRequestRetake": !interpretation.needsRetake
                        ]
                    ]
                }
            } else {
                try recorder.skip("apple_vision_ocr", reason: "Synthetic image generation failed.")
            }

            let loaded = try await recorder.step("model_load") {
                try Task.checkCancellation()
                let alreadyLoaded = model.isReady
                try await model.loadModel()
                try Task.checkCancellation()
                return ["engineCompleted": true, "modelReady": model.isReady,
                        "alreadyLoadedBeforeStep": alreadyLoaded, "selectedModel": modelDetails(model)]
            }

            if loaded {
                _ = try await recorder.step("grounded_taj_text_inference") {
                    let prompt = "In which city is the Taj Mahal? Answer in one short sentence using only the provided verified facts."
                    let text = try await model.generate(prompt: prompt, system: LandmarkFacts.tajMahal.promptContext)
                    try Task.checkCancellation()
                    return [
                        "engineCompleted": true,
                        "prompt": prompt,
                        "systemContext": LandmarkFacts.tajMahal.promptContext,
                        "sourceURL": LandmarkFacts.tajMahal.sourceURL,
                        "sourceVerifiedOn": LandmarkFacts.tajMahal.verifiedOn,
                        "returnedText": text,
                        "runtimeMetrics": metrics(model),
                        "qualityChecks": [
                            "kind": "keyword heuristic; human review of the full answer is still required",
                            "containsExpectedCityAgra": containsWord("agra", in: text),
                            "nonemptyText": !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ]
                    ]
                }

                if fixturesReady {
                    _ = try await recorder.step("synthetic_shape_vision_inference") {
                        let prompt = "Describe the shapes, their colors, and their left or right positions in this image. Use one short sentence."
                        let system = "You are performing a synthetic-image diagnostic. Describe only what is visible in the supplied image. Do not guess hidden content."
                        let text = try await model.generate(prompt: prompt, system: system, imageURL: shapeURL)
                        try Task.checkCancellation()
                        return [
                            "engineCompleted": true,
                            "synthetic": true,
                            "imageFilename": shapeURL.lastPathComponent,
                            "prompt": prompt,
                            "systemContext": system,
                            "returnedText": text,
                            "runtimeMetrics": metrics(model),
                            "qualityChecks": [
                                "kind": "word-presence heuristics; these do not verify color-shape binding, position, or factual correctness",
                                "mentionsRed": containsWord("red", in: text),
                                "mentionsSquare": containsWord("square", in: text),
                                "mentionsBlue": containsWord("blue", in: text),
                                "mentionsCircle": containsWord("circle", in: text),
                                "mentionsLeft": containsWord("left", in: text),
                                "mentionsRight": containsWord("right", in: text)
                            ]
                        ]
                    }
                } else {
                    try recorder.skip("synthetic_shape_vision_inference", reason: "Synthetic image generation failed.")
                }
            } else {
                try recorder.skip("grounded_taj_text_inference", reason: "Model loading failed.")
                try recorder.skip("synthetic_shape_vision_inference", reason: "Model loading failed.")
            }
            try recorder.finish()
            return recorder.value
        } catch {
            let failure: [String: Any] = ["type": String(reflecting: type(of: error)), "message": error.localizedDescription]
            guard let report else {
                return ["schemaVersion": 1, "runID": runID, "status": "report_storage_unavailable", "error": failure]
            }
            report.value["status"] = error is CancellationError ? "cancelled" : "aborted"
            report.value["finishedAt"] = DiagnosticReport.timestamp()
            report.value["error"] = failure
            do { try report.persist() }
            catch { report.value["reportWriteError"] = error.localizedDescription }
            return report.value
        }
    }

    private static func modelDetails(_ model: LocalModelService) -> [String: Any] {
        let selected = model.models.first { $0.url == model.selectedModelURL }
        var result: [String: Any] = [
            "filename": model.selectedModelURL?.lastPathComponent ?? NSNull() as Any,
            "requestedBackend": model.useGPU ? "GPU" : "CPU, 4 threads",
            "visionBackend": "CPU, 2 threads when supported",
            "isReady": model.isReady
        ]
        if let selected {
            result["byteCount"] = selected.byteCount
            result["supportsVision"] = selected.supportsVision
            result["maximumContextTokens"] = selected.maximumContextTokens
            result["dynamicContext"] = selected.dynamicContext
            if let budget = selected.visionTokenBudget { result["visionTokenBudget"] = budget }
        }
        return result
    }

    private static func metrics(_ model: LocalModelService) -> [String: Any] {
        guard let metrics = model.metrics else { return ["available": false] }
        var result: [String: Any] = ["available": true, "elapsedSeconds": metrics.elapsedSeconds,
                                    "characterCount": metrics.characterCount, "cancelled": metrics.cancelled]
        if let first = metrics.firstTextSeconds { result["firstTextSeconds"] = first }
        return result
    }

    private static func containsWord(_ word: String, in text: String) -> Bool {
        text.range(of: "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b",
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func renderer() -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 768, height: 512), format: format)
    }

    private static func shapesImage() -> Data {
        renderer().pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 768, height: 512))
            UIColor(red: 1, green: 0, blue: 0, alpha: 1).setFill()
            context.fill(CGRect(x: 100, y: 160, width: 192, height: 192))
            UIColor(red: 0, green: 0, blue: 1, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 476, y: 160, width: 192, height: 192))
        }
    }

    private static func expiryImage() -> Data {
        renderer().pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 768, height: 512))
            let titleAttributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 34, weight: .medium), .foregroundColor: UIColor.black]
            let expiryAttributes: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedSystemFont(ofSize: 48, weight: .semibold), .foregroundColor: UIColor.black]
            ("DIAGNOSTIC LABEL" as NSString).draw(at: CGPoint(x: 80, y: 135), withAttributes: titleAttributes)
            ("EXP 2027-04-30" as NSString).draw(at: CGPoint(x: 80, y: 245), withAttributes: expiryAttributes)
        }
    }

    private enum DiagnosticError: LocalizedError {
        case modelBusy
        var errorDescription: String? { "Diagnostics did not start because another model operation is running." }
    }
}

@MainActor
private final class DiagnosticReport {
    let directory: URL
    let runID: String
    var value: [String: Any]
    private var steps: [[String: Any]] = []
    private let startedUptime = ProcessInfo.processInfo.systemUptime

    init(runID: String) throws {
        self.runID = runID
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var location = documents.appendingPathComponent("Diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try location.setResourceValues(resources)
        directory = location
        var system = utsname()
        uname(&system)
        let machineSize = MemoryLayout.size(ofValue: system.machine)
        let hardware = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: machineSize) { String(cString: $0) }
        }
        value = [
            "schemaVersion": 1,
            "runID": runID,
            "startedAt": Self.timestamp(),
            "status": "running",
            "activeStep": "starting",
            "scope": "Explicit synthetic smoke test. No camera, microphone, photo library, or saved user memories are accessed.",
            "interpretation": "A completed engine step only means the API returned. Quality checks are limited fixture heuristics, not a semantic pass or a real-world reliability claim. A report left running indicates interruption or termination; it does not identify a crash cause.",
            "app": ["version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                    "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"],
            "device": ["model": UIDevice.current.model, "hardwareIdentifier": hardware,
                       "systemName": UIDevice.current.systemName, "systemVersion": UIDevice.current.systemVersion,
                       "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory],
            "steps": steps
        ]
    }

    /// The 'running' checkpoint is persisted before invoking native code. Failure to persist aborts the run.
    func step(_ name: String, operation: () async throws -> [String: Any]) async throws -> Bool {
        try Task.checkCancellation()
        let index = steps.count
        let start = ProcessInfo.processInfo.systemUptime
        steps.append(["name": name, "status": "running", "startedAt": Self.timestamp()])
        value["activeStep"] = name
        try persist()
        do {
            let details = try await operation()
            steps[index]["details"] = details
            steps[index]["status"] = "completed"
            steps[index]["finishedAt"] = Self.timestamp()
            steps[index]["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - start
            try persist()
            return true
        } catch {
            steps[index]["status"] = error is CancellationError ? "cancelled" : "failed"
            steps[index]["error"] = ["type": String(reflecting: type(of: error)), "message": error.localizedDescription]
            steps[index]["finishedAt"] = Self.timestamp()
            steps[index]["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - start
            try persist()
            if error is CancellationError { throw error }
            return false
        }
    }

    func skip(_ name: String, reason: String) throws {
        steps.append(["name": name, "status": "skipped", "reason": reason, "recordedAt": Self.timestamp()])
        try persist()
    }

    func finish() throws {
        let failed = steps.contains { ($0["status"] as? String) == "failed" || ($0["status"] as? String) == "skipped" }
        value["status"] = failed ? "completed_with_errors" : "completed"
        value["activeStep"] = NSNull()
        value["finishedAt"] = Self.timestamp()
        value["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - startedUptime
        value["qualityAssessment"] = "Review individual fixture checks and returned text. No overall semantic pass is assigned."
        try persist()
    }

    func persist() throws {
        value["steps"] = steps
        value["updatedAt"] = Self.timestamp()
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        // Keep an archive as well as the stable path read by the device smoke-test runner.
        try data.write(to: directory.appendingPathComponent("report-\(runID).json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try data.write(to: directory.appendingPathComponent("report.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }
}
