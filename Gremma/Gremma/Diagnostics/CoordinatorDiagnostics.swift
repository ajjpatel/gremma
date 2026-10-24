import Foundation
import UIKit

/// Explicit developer invocation only. Exercises actual model decisions without executing action handlers.
@MainActor
enum CoordinatorDiagnostics {
    @discardableResult
    static func run(model: LocalModelService) async -> [String: Any] {
        var recorder: CoordinatorDiagnosticReport?
        do {
            let report = try CoordinatorDiagnosticReport(model: model)
            recorder = report
            try report.persist()
            guard !model.isBusy else { throw DiagnosticError.modelBusy }
            let oldIdleTimer = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = oldIdleTimer }
            let context = AssistantContext(room: "Kitchen", mode: "conversation", hasPhoto: false,
                                           savedItemNames: ["keys"], lastTaskResult: "")
            let loaded = try await report.step("model_load") {
                try await model.loadModel()
                try Task.checkCancellation()
                return ["engineCompleted": true, "isReady": model.isReady]
            }
            guard loaded else {
                try report.skip("coordinator_decisions", reason: "Model loading failed.")
                try report.finish()
                return report.value
            }

            let cases: [TestCase] = [
                TestCase(id: "greeting", message: "Hello", action: .chat),
                TestCase(id: "medicine_label", message: "Can you help me read this medicine label?", action: .read, readingMode: .medicine),
                TestCase(id: "remember_keys", message: "Remember where I put my keys", action: .remember),
                TestCase(id: "find_keys", message: "Where did I leave my keys?", action: .find, argument: "keys"),
                TestCase(id: "taj_mahal", message: "Where is the Taj Mahal?", action: .imagine),
                TestCase(id: "general_question", message: "What makes a rainbow?", action: .chat),
                TestCase(id: "negated_capture", message: "Please don't take a photo. Just tell me what you can help me with.", action: .chat),
                TestCase(id: "record_room_video", message: "Can you record a video of this room?", action: .recordVideo),
                TestCase(id: "currency_note", message: "Can you read the amount on this US dollar note?", action: .read, readingMode: .currency),
                TestCase(id: "change_room", message: "I'm in the kitchen now. Use Kitchen as the room name for my next photos.", action: .setRoom, argument: "Kitchen"),
                TestCase(id: "natural_read_aloud", message: "I want to read aloud something", action: .read, readingMode: .text),
                TestCase(id: "natural_read_letter", message: "Could you read a letter to me?", action: .read, readingMode: .text),
                TestCase(id: "explain_reading_only", message: "How does your reading feature work?", action: .chat),
                TestCase(id: "negated_reading", message: "Don't read anything right now, just explain the feature.", action: .chat),
                TestCase(id: "import_existing_video", message: "I want to upload a video I already recorded", action: .importVideo),
                TestCase(id: "manage_old_videos", message: "Show my older recordings so I can delete one", action: .showVideos),
                TestCase(id: "confirm_proposed_room", message: "Yes, that's right", action: .confirmRoom,
                         awaitingRoom: true, proposedRoom: "Kitchen"),
                TestCase(id: "correct_proposed_room", message: "No, it's the bedroom", action: .confirmRoom, argument: "Bedroom",
                         awaitingRoom: true, proposedRoom: "Kitchen"),
                TestCase(id: "reject_proposed_room", message: "No", action: .rejectRoom,
                         awaitingRoom: true, proposedRoom: "Kitchen"),
                TestCase(id: "name_unclear_room", message: "Living room", action: .confirmRoom, argument: "Living room",
                         awaitingRoom: true),
                TestCase(id: "yes_without_proposal", message: "Yes", action: .chat, awaitingRoom: true),
                TestCase(id: "yes_without_pending_video", message: "Yes", action: .chat),
                TestCase(id: "video_try_again", message: "Try again", action: .resumeVideo,
                         hasPhoto: true, hasPendingVideo: true, lastVideoNeedsRetry: true),
                TestCase(id: "video_resume_natural", message: "Could you finish processing that recording from where it stopped?", action: .resumeVideo,
                         hasPhoto: true, hasPendingVideo: true, lastVideoNeedsRetry: true),
                TestCase(id: "video_resume_explicit", message: "Resume processing the video", action: .resumeVideo,
                         hasPendingVideo: true),
                TestCase(id: "photo_retry_despite_video", message: "Try that photo again", action: .retryCapture,
                         hasPhoto: true, hasPendingVideo: true, lastVideoNeedsRetry: true),
                TestCase(id: "video_resume_missing", message: "Resume the video", action: .chat),
                TestCase(id: "video_new_after_failure", message: "Please record a new video", action: .recordVideo,
                         hasPendingVideo: true, lastVideoNeedsRetry: true),
                TestCase(id: "video_resume_negated", message: "Don't resume the video; tell me what happened.", action: .chat,
                         hasPendingVideo: true, lastVideoNeedsRetry: true)
            ]
            let arguments = ProcessInfo.processInfo.arguments
            let focusedCase: String?
            if let index = arguments.firstIndex(of: "--gremma-coordinator-case") {
                guard index + 1 < arguments.count, cases.contains(where: { $0.id == arguments[index + 1] }) else {
                    throw DiagnosticError.invalidCase(index + 1 < arguments.count ? arguments[index + 1] : "missing case ID")
                }
                focusedCase = arguments[index + 1]
                report.value["focusedCase"] = focusedCase
                report.value["scope"] = "One explicitly selected case; conversation-history cases are not run."
            } else { focusedCase = nil }
            for test in cases where focusedCase == nil || test.id == focusedCase {
                _ = try await report.step(test.id) {
                    try await evaluate(test, history: [], context: context, model: model, report: report).details
                }
            }

            if focusedCase != nil {
                try report.finish()
                return report.value
            }

            // Seed the history using the actual first model reply; never fabricate an assistant turn.
            let introduction = TestCase(id: "history_seed", message: "My dog is named Pepper", action: .chat)
            var firstReply: String?
            _ = try await report.step(introduction.id) {
                let result = try await evaluate(introduction, history: [], context: context, model: model, report: report)
                firstReply = result.reply
                return result.details
            }
            if let firstReply, !firstReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var history = [ConversationTurn(role: .user, text: introduction.message),
                               ConversationTurn(role: .assistant, text: firstReply)]
                let recall = TestCase(id: "history_recall", message: "What is my dog called?", action: .chat, expectedReplyWord: "Pepper")
                _ = try await report.step(recall.id) {
                    let result = try await evaluate(recall, history: history, context: context, model: model, report: report)
                    if !result.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        history += [ConversationTurn(role: .user, text: recall.message), ConversationTurn(role: .assistant, text: result.reply)]
                    }
                    return result.details
                }
                let followUp = TestCase(id: "history_pronoun_followup", message: "Write a one-sentence greeting for him using his name.", action: .chat, expectedReplyWord: "Pepper")
                _ = try await report.step(followUp.id) {
                    let result = try await evaluate(followUp, history: history, context: context, model: model, report: report)
                    if !result.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        history += [ConversationTurn(role: .user, text: followUp.message), ConversationTurn(role: .assistant, text: result.reply)]
                    }
                    return result.details
                }
                if history.count == 6 {
                    let readAfterConversation = TestCase(id: "history_three_exchanges_then_read", message: "Now can you help me read this medicine label?", action: .read, readingMode: .medicine)
                    _ = try await report.step(readAfterConversation.id) {
                        try await evaluate(readAfterConversation, history: history, context: context, model: model, report: report).details
                    }
                } else {
                    try report.skip("history_three_exchanges_then_read", reason: "Three complete actual conversation exchanges were not available; no substitute replies were invented.")
                }
            } else {
                try report.skip("history_recall", reason: "The seed request did not produce an assistant reply; no substitute history was invented.")
                try report.skip("history_pronoun_followup", reason: "The seed request did not produce an assistant reply; no substitute history was invented.")
                try report.skip("history_three_exchanges_then_read", reason: "The seed request did not produce an assistant reply; no substitute history was invented.")
            }
            try report.finish()
            return report.value
        } catch {
            guard let recorder else { return ["status": "report_storage_unavailable", "error": error.localizedDescription] }
            recorder.value["status"] = error is CancellationError ? "cancelled" : "aborted"
            recorder.value["error"] = error.localizedDescription
            recorder.value["finishedAt"] = CoordinatorDiagnosticReport.timestamp()
            do { try recorder.persist() } catch { recorder.value["reportWriteError"] = error.localizedDescription }
            return recorder.value
        }
    }

    private struct TestCase {
        let id: String
        let message: String
        let action: AssistantAction
        var readingMode: ReadingMode? = nil
        var argument: String? = nil
        var expectedReplyWord: String? = nil
        var awaitingRoom = false
        var proposedRoom: String? = nil
        var hasPhoto = false
        var hasPendingVideo = false
        var lastVideoNeedsRetry = false
    }

    private static func evaluate(_ test: TestCase, history: [ConversationTurn], context: AssistantContext,
                                 model: LocalModelService, report: CoordinatorDiagnosticReport) async throws -> (reply: String, details: [String: Any]) {
        var context = context
        context.hasPendingRoomConfirmation = test.awaitingRoom
        context.pendingRoomProposal = test.proposedRoom
        context.hasPhoto = test.hasPhoto
        context.hasPendingVideo = test.hasPendingVideo
        context.lastVideoNeedsRetry = test.lastVideoNeedsRetry
        if test.lastVideoNeedsRetry { context.lastTaskResult = "Video indexing stopped after frame 9 of 12. Saved progress is available to resume." }
        let usesImmediateConfirmation = AgentCoordinator.immediateRoomDecision(message: test.message, context: context) != nil
        let usesImmediateVideoRetry = AgentCoordinator.immediateVideoRetryDecision(message: test.message, context: context) != nil
        let usesImmediateDecision = usesImmediateConfirmation || usesImmediateVideoRetry
        try report.partial(["message": test.message,
                            "history": history.map { ["role": $0.role == .user ? "user" : "assistant", "text": $0.text] },
                            "expectedAction": test.action.rawValue,
                            "expectedReadingMode": test.readingMode?.rawValue ?? NSNull() as Any,
                            "expectedArgument": test.argument ?? NSNull() as Any,
                            "expectedReplyWord": test.expectedReplyWord ?? NSNull() as Any,
                            "videoAwaitingRoomConfirmation": test.awaitingRoom,
                            "hasPhoto": test.hasPhoto,
                            "hasPendingVideo": test.hasPendingVideo,
                            "lastVideoNeedsRetry": test.lastVideoNeedsRetry,
                            "proposedRoom": test.proposedRoom ?? NSNull() as Any,
                            "handlersExecuted": false])
        do {
            let decision = try await AgentCoordinator.decide(message: test.message, history: history, context: context, model: model)
            try Task.checkCancellation()
            let nonempty = !decision.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            var checks: [String: Any] = ["actionMatchesExpected": decision.action == test.action,
                                         "replyIsNonempty": nonempty]
            if test.action == .chat { checks["chatHasNonemptyReply"] = decision.action == .chat && nonempty }
            if let expected = test.readingMode { checks["readingModeMatchesExpected"] = decision.readingMode == expected }
            if let expected = test.argument {
                checks["argumentMatchesExpectedAfterNameNormalization"] = MemoryRetrieval.normalizedName(decision.argument) == MemoryRetrieval.normalizedName(expected)
            }
            if let word = test.expectedReplyWord {
                checks["replyContainsExpectedWord"] = decision.reply.range(of: "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b", options: [.regularExpression, .caseInsensitive]) != nil
            }
            let runtime: [String: Any]
            let runtimeResponse: Any
            if usesImmediateDecision {
                runtime = ["interpretation": "The explicit pending-room or video-recovery reply was handled locally. No model request was made for this decision."]
                runtimeResponse = NSNull()
            } else {
                runtime = runtimeDetails(model)
                runtimeResponse = model.response
            }
            let details: [String: Any] = [
                "engineCompleted": !usesImmediateDecision,
                "decisionCompleted": true,
                "usedImmediateRoomConfirmation": usesImmediateConfirmation,
                "usedImmediateVideoRetry": usesImmediateVideoRetry,
                "decision": ["action": decision.action.rawValue, "argument": decision.argument,
                             "reply": decision.reply, "readingMode": decision.readingMode.rawValue],
                "lastRuntimeResponse": runtimeResponse,
                "runtime": runtime,
                "expectedMatchChecks": checks,
                "qualityAssessment": "These are checks of a small fixed case. Read the full reply; word or action matches do not establish answer correctness or general routing accuracy."
            ]
            return (decision.reply, details)
        } catch {
            try report.partial(["lastRuntimeResponse": model.response, "runtime": runtimeDetails(model)])
            throw error
        }
    }

    private static func runtimeDetails(_ model: LocalModelService) -> [String: Any] {
        var result: [String: Any] = [:]
        if let metrics = model.metrics {
            var timings: [String: Any] = ["elapsedSeconds": metrics.elapsedSeconds, "characterCount": metrics.characterCount,
                                          "cancelled": metrics.cancelled]
            if let first = metrics.firstTextSeconds { timings["firstTextSeconds"] = first }
            result["lastGenerationMetrics"] = timings
        }
        if let diagnostics = model.lastGenerationDiagnostics,
           let encoded = try? JSONEncoder().encode(diagnostics),
           let data = try? JSONSerialization.jsonObject(with: encoded) {
            result["lastGenerationDiagnostics"] = data
        }
        result["interpretation"] = "These metrics describe the final generation. Step elapsedSeconds includes any coordinator fallback. constrainedJSON=false can indicate a conversational fallback; no intermediate response is reconstructed."
        return result
    }

    private enum DiagnosticError: LocalizedError {
        case modelBusy
        case invalidCase(String)
        var errorDescription: String? {
            switch self {
            case .modelBusy: return "Another model operation is running; coordinator diagnostics did not start."
            case .invalidCase(let value): return "Unknown focused coordinator case: \(value). No decision cases were run."
            }
        }
    }
}

@MainActor
private final class CoordinatorDiagnosticReport {
    private let directory: URL
    private let runID = UUID().uuidString.lowercased()
    private var steps: [[String: Any]] = []
    var value: [String: Any]

    init(model: LocalModelService) throws {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var location = documents.appendingPathComponent("Diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
        var resources = URLResourceValues(); resources.isExcludedFromBackup = true
        try location.setResourceValues(resources)
        directory = location
        value = ["schemaVersion": 1, "runID": runID, "status": "running", "startedAt": Self.timestamp(),
                 "activeStep": "starting", "steps": steps,
                 "modelFilename": model.selectedModelURL?.lastPathComponent ?? "none",
                 "requestedBackend": model.useGPU ? "GPU" : "CPU",
                 "device": ["model": UIDevice.current.model, "osVersion": UIDevice.current.systemVersion,
                            "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory],
                 "context": ["room": "Kitchen", "mode": "conversation", "hasPhoto": false,
                             "savedItemNames": ["keys"], "lastTaskResult": ""],
                 "scope": "Explicit actual-model coordinator diagnostic with synthetic conversation context. No action handlers run; no camera, microphone, photo library, or user memories are accessed.",
                 "interpretation": "Completed means execution returned, not that an expected decision matched. Inspect per-case checks and full replies. No blanket accuracy or safety pass is assigned. A report left running indicates interruption or termination, not its cause."]
    }

    func step(_ name: String, operation: () async throws -> [String: Any]) async throws -> Bool {
        try Task.checkCancellation()
        let started = ProcessInfo.processInfo.systemUptime
        let index = steps.count
        steps.append(["name": name, "status": "running", "startedAt": Self.timestamp()])
        value["activeStep"] = name
        try persist()
        do {
            let details = try await operation()
            var merged = steps[index]["details"] as? [String: Any] ?? [:]
            merged.merge(details, uniquingKeysWith: { _, new in new })
            steps[index]["details"] = merged
            steps[index]["status"] = "completed"
        } catch {
            steps[index]["status"] = error is CancellationError ? "cancelled" : "failed"
            steps[index]["error"] = error.localizedDescription
            steps[index]["finishedAt"] = Self.timestamp()
            steps[index]["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
            try persist()
            if error is CancellationError { throw error }
            return false
        }
        steps[index]["finishedAt"] = Self.timestamp()
        steps[index]["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
        try persist()
        return true
    }

    func partial(_ details: [String: Any]) throws {
        guard !steps.isEmpty else { return }
        var merged = steps[steps.count - 1]["details"] as? [String: Any] ?? [:]
        merged.merge(details, uniquingKeysWith: { _, new in new })
        steps[steps.count - 1]["details"] = merged
        try persist()
    }

    func skip(_ name: String, reason: String) throws {
        steps.append(["name": name, "status": "skipped", "reason": reason])
        try persist()
    }

    func finish() throws {
        value["status"] = steps.contains { ($0["status"] as? String) != "completed" } ? "completed_with_errors" : "completed"
        value["finishedAt"] = Self.timestamp()
        value["activeStep"] = NSNull()
        try persist()
    }

    func persist() throws {
        value["steps"] = steps
        value["updatedAt"] = Self.timestamp()
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("coordinator-report-\(runID).json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try data.write(to: directory.appendingPathComponent("coordinator-report.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }
}
