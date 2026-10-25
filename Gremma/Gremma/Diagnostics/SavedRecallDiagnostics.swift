import Foundation

/// Explicit developer-only queries through the same controller path used by
/// typed/spoken input. These queries supply no expected answers or new memories.
@MainActor
enum SavedRecallDiagnostics {
    static func run(app: AppController) async {
        let numbers = app.videoJobs.filter(\.isDemoVideo)
            .compactMap { ActivityEvidenceScope.clipNumber($0.room) }.sorted()
        let natural = ProcessInfo.processInfo.arguments.contains("--gremma-verify-natural-recall")
        let modelRecall = ProcessInfo.processInfo.arguments.contains("--gremma-verify-model-recall")
        let questions = modelRecall ? ["Where is my key?", "Did I take my medicine this evening?",
            "Where are my keys?", "Where is my wallet?", "Where are my glasses?", "Where is my passport?"] : natural ? ["Where are my keys?", "Where is my wallet?", "Where are my glasses?",
            "Where is the TV remote?", "Have I eaten?", "Where is my passport?", "Did I eat today?"] : ["Where are my keys?"] + numbers.map { "What happened in demo clip \($0)?" } + [
            "What was used to wash the utensils in the demo video?",
            "What did I do today?"
        ]
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostics", isDirectory: true)
        var entries: [[String: Any]] = []
        func persist(_ status: String) {
            let report: [String: Any] = ["status": status, "queries": entries,
                "userRecordsModified": false, "includesSpeechRecognitionTest": false]
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("saved-recall-report.json"),
                       options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        app.voiceSessionEnabled = false
        app.voice.cancelListening()
        persist("running")
        for question in questions {
            if Task.isCancelled { persist("cancelled"); return }
            let start = Date()
            app.lastLookupSeconds = nil
            app.sendMessage(question)
            while app.isWorking && Date().timeIntervalSince(start) < 180 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled { app.stop(); persist("cancelled"); return }
            }
            if app.isWorking {
                app.stop()
                entries.append(["question": question, "error": "Diagnostic query exceeded 180 seconds."])
                persist("failed")
                return
            }
            var entry: [String: Any] = ["question": question, "answer": app.answer,
                "status": app.status, "elapsedSeconds": Date().timeIntervalSince(start),
                "openedCamera": app.captureRequest != nil, "openedLibrary": app.showVideoLibrary]
            if let performance = app.queryPerformance,
               let data = try? JSONEncoder().encode(performance),
               let value = try? JSONSerialization.jsonObject(with: data) { entry["performance"] = value }
            if let error = app.error { entry["error"] = error }
            if app.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                entry["error"] = "The query ended without an answer, possibly after cancellation."
            }
            if modelRecall && (app.queryPerformance?.source != "Gemma E4B" || (app.queryPerformance?.outputTokens ?? 0) <= 0) {
                entry["error"] = "The answer did not report actual E4B output tokens."
            }
            if let lookup = app.lastLookupSeconds { entry["savedLookupSeconds"] = lookup }
            entries.append(entry)
            persist("running")
            app.voice.stopSpeaking()
            if app.captureRequest != nil || app.showVideoLibrary {
                persist("misrouted")
                return
            }
        }
        persist(entries.contains { $0["error"] != nil } ? "failed" : "completed")
        app.status = "Saved-memory query checks finished"
    }
}
