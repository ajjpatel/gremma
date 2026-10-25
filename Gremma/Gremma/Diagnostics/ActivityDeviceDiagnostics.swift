import Foundation
@preconcurrency import AVFoundation
import CoreVideo
import UIKit

/// Explicit developer-only smoke checks. Every queue/database path is a unique
/// temporary directory. This never opens or mutates the user's activity stores.
@MainActor
enum ActivityDeviceDiagnostics {
    static func run(model: LocalModelService) async -> [String: Any] {
        let runID = UUID().uuidString
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("gremma-activity-diagnostics-\(runID)")
        let fixedDate = Date(timeIntervalSince1970: 1_761_264_000)
        let recorder: ActivityDeviceReport
        do {
            recorder = try ActivityDeviceReport(runID: runID)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            try recorder.persist()
        } catch {
            return ["passed": false, "status": "failed", "syntheticOnly": true,
                    "error": error.localizedDescription, "phase": "initialize_report"]
        }
        defer { try? FileManager.default.removeItem(at: scratch) }
        let previousIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdle }

        let movie = scratch.appendingPathComponent("synthetic-moving-shapes.mov")
        let madeMovie = await recorder.step("synthetic_video") {
            try await makeMovie(at: movie)
            let duration = try await BoundedAsync.run(maximumDuration: 20) {
                try await AVURLAsset(url: movie).load(.duration).seconds
            }
            return ["durationSeconds": duration, "checksPassed": abs(duration - 6) < 0.15,
                    "scene": "Four positions of a red square moving left to right; stationary blue circle and gray table line. No person, keys, or medicine.",
                    "framePositions": 4, "encodedFrames": 60, "framesPerSecond": 10,
                    "syntheticOnly": true]
        }
        if Task.isCancelled { return recorder.finish(cancelled: true) }

        var queue: VideoIndexQueue?
        var job: VideoIndexJob?
        if madeMovie {
            _ = await recorder.step("scratch_video_import") {
                let newQueue = try VideoIndexQueue(directory: scratch.appendingPathComponent("video-queue"))
                let imported = try await newQueue.importVideo(from: movie, room: "Synthetic test scene", roomConfirmed: true,
                    recordedAt: fixedDate, recordingDateSource: .userConfirmed)
                queue = newQueue; job = imported
                return ["videoID": imported.id, "durationSeconds": imported.duration,
                        "activityWindowCount": imported.activityWindowCount,
                        "recordedAt": ISO8601DateFormatter().string(from: fixedDate),
                        "checksPassed": imported.recordedAt == fixedDate && imported.isRoomConfirmed,
                        "usesScratchStore": true]
            }
        } else { recorder.skip("scratch_video_import", reason: "Synthetic video generation failed.") }
        if Task.isCancelled { return recorder.finish(cancelled: true) }

        let modelReady = await recorder.step("e4b_model_ready") {
            guard !model.isBusy else { throw ActivityDeviceDiagnosticError("Gemma was busy before the diagnostic.") }
            await model.refreshModels()
            guard model.modelName.localizedCaseInsensitiveContains("E4B") else {
                throw ActivityDeviceDiagnosticError("The selected model is not Gemma E4B.")
            }
            try await model.loadModel()
            try Task.checkCancellation()
            return ["model": model.modelName, "checksPassed": model.isReady,
                    "engine": "LiteRT-LM", "syntheticOnly": true]
        }
        if Task.isCancelled { return recorder.finish(cancelled: true) }

        if modelReady, let queue, let job {
            _ = await recorder.step("e4b_temporal_activity_extraction") {
                let events = try await ActivityVideoIndexer.extract(job: job, windowIndex: 0, queue: queue, model: model,
                    diagnosticTrace: { recorder.syntheticModelTrace($0) })
                try Task.checkCancellation()
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                let encoded = try JSONSerialization.jsonObject(with: encoder.encode(events))
                func describes(_ event: ActivityEvent, color: String, shapes: [String]) -> Bool {
                    let words = Set((event.entity + " " + event.summary).lowercased()
                        .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
                    return words.contains(color) && shapes.contains(where: words.contains)
                }
                let redSquare = events.contains { describes($0, color: "red", shapes: ["square", "block", "rectangle"]) }
                let blueCircle = events.contains { $0.kind == .sighting && describes($0, color: "blue", shapes: ["circle", "disk", "disc", "dot"]) }
                let redMovement = events.contains { $0.kind == .moved && describes($0, color: "red", shapes: ["square", "block", "rectangle"]) }
                return ["engineCompleted": true, "checksPassed": redSquare && blueCircle, "events": encoded,
                        "eventCount": events.count, "inputFrameCount": try job.activityWindow(at: 0).frameTimes.count,
                        "expectedShapeChecks": ["redSquarePresent": redSquare, "stationaryBlueCircleSighting": blueCircle],
                        "redMovementCaptured": redMovement,
                        "validationMeaning": "Engine completion is separate from recognizing the fixture's red square and stationary blue circle. The moving-square observation is reported separately. Neither establishes recognition accuracy for real human activities.",
                        "eventsWrittenToUserStore": false]
            }
        } else {
            recorder.skip("e4b_temporal_activity_extraction", reason: "The model or synthetic source was not ready.", required: true)
        }
        if Task.isCancelled { return recorder.finish(cancelled: true) }

        _ = await recorder.step("scratch_store_pickup_and_lookup") {
            let store = try ActivityRepository(directory: scratch.appendingPathComponent("activity-store"))
            let videoID = "synthetic-location-test"
            let placed = ActivityEvent(id: "synthetic-placement", videoID: videoID, segmentID: "placed",
                kind: .placed, entity: "keys", location: "on the table", summary: "A hand places keys on the table.",
                occurredAt: fixedDate, startSeconds: 0, endSeconds: 1, confidence: 0.95)
            try await store.replaceSegment(videoID: videoID, segmentID: "placed", events: [placed])
            let before = try await store.answer(query: "Where are my keys?", now: fixedDate.addingTimeInterval(120))
            let pickedUp = ActivityEvent(id: "synthetic-pickup", videoID: videoID, segmentID: "picked-up",
                kind: .pickedUp, entity: "keys", summary: "A hand picks up the keys.",
                occurredAt: fixedDate.addingTimeInterval(60), startSeconds: 2, endSeconds: 3, confidence: 0.95)
            try await store.replaceSegment(videoID: videoID, segmentID: "picked-up", events: [pickedUp])
            var times = [Double]()
            var after: ActivityAnswer?
            for _ in 0..<20 {
                try Task.checkCancellation()
                let start = ProcessInfo.processInfo.systemUptime
                after = try await store.answer(query: "Where are my keys?", now: fixedDate.addingTimeInterval(120))
                times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
            let sorted = times.sorted()
            let retained = try await store.events()
            let pickupInvalidates = before?.event?.kind == .placed && after?.event?.kind == .pickedUp
                && before?.text.contains("on the table") == true
                && after?.text.contains("haven't seen where") == true
                && after?.text.contains("on the table") == false
            return ["checksPassed": pickupInvalidates && retained.count == 2,
                    "beforePickup": before?.text ?? "No answer", "afterPickup": after?.text ?? "No answer",
                    "historyEventCount": retained.count, "lookupCount": times.count,
                    "lookupMilliseconds": ["minimum": sorted.first ?? 0,
                        "median": sorted[sorted.count / 2], "maximum": sorted.last ?? 0],
                    "modelCallsDuringLookup": 0, "usesScratchStore": true,
                    "validationMeaning": "Controlled two-event correctness and warm lookup timing; not a large-history or end-to-end speech benchmark."]
        }
        if Task.isCancelled { return recorder.finish(cancelled: true) }

        let audioFixture = recorder.directory.appendingPathComponent("activity-speech-fixture.aiff")
        if FileManager.default.fileExists(atPath: audioFixture.path) {
            _ = await recorder.step("on_device_speech_fixture") {
                let duration = try await BoundedAsync.run(maximumDuration: 20) {
                    try await AVURLAsset(url: audioFixture).load(.duration).seconds
                }
                guard duration.isFinite, duration > 0 else { throw ActivityDeviceDiagnosticError("Synthetic speech fixture has no valid duration.") }
                let result = try await VideoAudioTranscriber().transcribe(videoURL: audioFixture,
                    startSeconds: 0, endSeconds: min(30, duration))
                let normalized = result.text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { !$0.isEmpty }.joined(separator: " ")
                let words = Set(normalized.split(separator: " ").map(String.init))
                let checks = ["containsKeys": words.contains("keys"), "containsBlueCup": normalized.contains("blue cup"),
                              "containsFour": words.contains("four") || words.contains("4")]
                return ["checksPassed": result.status == .transcribed && checks.values.allSatisfy { $0 },
                        "status": result.status.rawValue, "transcript": result.text,
                        "expectedPhraseChecks": checks, "requiresOnDeviceRecognition": true,
                        "fixtureFilename": audioFixture.lastPathComponent, "durationSeconds": duration,
                        "validationMeaning": "Synthetic speech recognition only; no conversation identification or real-world transcription accuracy claim."]
            }
        } else {
            recorder.skip("on_device_speech_fixture", reason: "Optional activity-speech-fixture.aiff was not provided. Audio recognition was not tested.")
        }
        return recorder.finish(cancelled: Task.isCancelled)
    }

    private static func makeMovie(at url: URL) async throws {
        let width = 640, height = 360
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height])
        input.expectsMediaDataInRealTime = false
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
        guard writer.canAdd(input) else { throw ActivityDeviceDiagnosticError("Synthetic movie input could not be added.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ActivityDeviceDiagnosticError("Synthetic movie writing could not start.") }
        writer.startSession(atSourceTime: .zero)
        let operation = ActivitySyntheticMovieWriter(writer: writer, output: url)
        do {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
            let scenes = (0..<4).map { position in
                renderer.image { context in
                    UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                    UIColor.darkGray.setFill(); context.fill(CGRect(x: 20, y: 290, width: 600, height: 8))
                    UIColor.systemRed.setFill(); context.fill(CGRect(x: 60 + position * 100, y: 200, width: 70, height: 70))
                    UIColor.systemBlue.setFill(); UIBezierPath(ovalIn: CGRect(x: 520, y: 210, width: 55, height: 55)).fill()
                    let title = "SYNTHETIC SHAPES — NO REAL PERSON"
                    title.draw(at: CGPoint(x: 20, y: 35), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 18), .foregroundColor: UIColor.black])
                }.cgImage!
            }
            for frame in 0..<60 {
                try Task.checkCancellation()
                let deadline = ProcessInfo.processInfo.systemUptime + 5
                while !input.isReadyForMoreMediaData {
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw ActivityDeviceDiagnosticError("Synthetic movie encoder stalled.") }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                var pixelBuffer: CVPixelBuffer?
                let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                    [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
                    &pixelBuffer)
                guard status == kCVReturnSuccess, let pixelBuffer else { throw ActivityDeviceDiagnosticError("Synthetic pixel buffer allocation failed.") }
                CVPixelBufferLockBaseAddress(pixelBuffer, [])
                let appended: Bool
                do {
                    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
                    guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
                        throw ActivityDeviceDiagnosticError("Synthetic pixel drawing failed.")
                    }
                    context.draw(scenes[min(3, frame / 15)], in: CGRect(x: 0, y: 0, width: width, height: height))
                    appended = adapter.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 10))
                }
                guard appended else { throw writer.error ?? ActivityDeviceDiagnosticError("Synthetic video frame could not be written.") }
            }
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTime(seconds: 6, preferredTimescale: 600))
            try await BoundedAsync.run(maximumDuration: 30, cancellationGrace: 1,
                                      onCancellation: { operation.cancel() }) { try await operation.finish() }
        } catch { operation.cancel(); throw error }
    }
}

private struct ActivityDeviceDiagnosticError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Retains the native writer while its asynchronous completion drains after cancellation.
private final class ActivitySyntheticMovieWriter: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let output: URL
    private let lock = NSLock()
    private var cancelled = false
    init(writer: AVAssetWriter, output: URL) { self.writer = writer; self.output = output }
    func cancel() { lock.lock(); cancelled = true; lock.unlock(); writer.cancelWriting() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func finish() async throws {
        await writer.finishWriting()
        if isCancelled { try? FileManager.default.removeItem(at: output); throw CancellationError() }
        guard writer.status == .completed else { throw writer.error ?? ActivityDeviceDiagnosticError("Synthetic movie finalization failed.") }
    }
}

@MainActor
private final class ActivityDeviceReport {
    let directory: URL
    private var value: [String: Any]
    private var steps = [[String: Any]]()
    init(runID: String) throws {
        directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        value = ["runID": runID, "startedAt": ISO8601DateFormatter().string(from: Date()),
                 "status": "running", "passed": false, "syntheticOnly": true,
                 "userRecordsModified": false,
                 "scope": "E4B temporal pipeline smoke check, scratch activity-store correctness/timing, and optional synthetic offline speech."]
    }
    func persist() throws {
        value["steps"] = steps
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("activity-device-report.json"),
                       options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func step(_ name: String, operation: @MainActor () async throws -> [String: Any]) async -> Bool {
        let index = steps.count
        let start = ProcessInfo.processInfo.systemUptime
        steps.append(["name": name, "status": "running"])
        do {
            try persist()
            let details = try await operation()
            let passed = details["checksPassed"] as? Bool ?? true
            steps[index]["status"] = passed ? "passed" : "failed"
            steps[index]["details"] = details
            steps[index]["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - start
            try persist()
            return passed
        } catch {
            steps[index]["status"] = Task.isCancelled ? "cancelled" : "failed"
            steps[index]["error"] = error.localizedDescription
            steps[index]["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - start
            do { try persist() } catch { value["reportWriteError"] = error.localizedDescription }
            return false
        }
    }

    /// This recorder only receives the generated moving-shapes fixture. Persist
    /// after each model call so JSON/validation failures retain their evidence.
    func syntheticModelTrace(_ trace: ActivityVideoDiagnosticTrace) {
        guard let index = steps.lastIndex(where: {
            $0["name"] as? String == "e4b_temporal_activity_extraction" && $0["status"] as? String == "running"
        }) else { return }
        let phase: String, output: String
        switch trace {
        case .attention(let text): phase = "attention"; output = text
        case .visualDescription(let text): phase = "visual_description"; output = text
        case .structuredExtraction(let text): phase = "structured_extraction"; output = text
        }
        var traces = steps[index]["syntheticModelTrace"] as? [[String: Any]] ?? []
        traces.append(["phase": phase, "output": output, "syntheticOnly": true])
        steps[index]["syntheticModelTrace"] = traces
        do { try persist() } catch { value["reportWriteError"] = error.localizedDescription }
    }
    func skip(_ name: String, reason: String, required: Bool = false) {
        steps.append(["name": name, "status": "skipped", "reason": reason, "required": required])
        do { try persist() } catch { value["reportWriteError"] = error.localizedDescription }
    }
    func finish(cancelled: Bool) -> [String: Any] {
        let failed = steps.contains { ($0["status"] as? String) == "failed" || ($0["status"] as? String) == "cancelled"
            || (($0["status"] as? String) == "skipped" && ($0["required"] as? Bool) == true) }
        value["passed"] = !cancelled && !failed && value["reportWriteError"] == nil
        value["status"] = cancelled ? "cancelled" : (failed ? "failed" : "completed")
        value["finishedAt"] = ISO8601DateFormatter().string(from: Date())
        value["audioTested"] = steps.contains { $0["name"] as? String == "on_device_speech_fixture" && $0["status"] as? String != "skipped" }
        do { try persist() } catch { value["passed"] = false; value["reportWriteError"] = error.localizedDescription }
        value["steps"] = steps
        return value
    }
}
