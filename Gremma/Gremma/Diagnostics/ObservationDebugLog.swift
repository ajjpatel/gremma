import Foundation

/// Explicit local developer capture only. Unlike normal metadata diagnostics, this file
/// contains visual descriptions and raw model text, so it must never be enabled implicitly.
@MainActor
enum ObservationDebugLog {
    private struct Attempt: Codable {
        let number: Int
        var rawResponse: String?
        var status: String
        var failureCategory: String?
        var failureMessage: String?
    }
    private struct Record: Codable {
        let id: String
        let startedAt: String
        var updatedAt: String
        var status: String
        var visualDescription: String?
        var attempts: [Attempt]
        var failureCategory: String?
        var failureMessage: String?
        var itemCount: Int?
    }
    private struct Archive: Codable {
        var schemaVersion = 1
        var explicitDebugCapture = true
        var latestRecordID: String?
        var records: [Record] = []
    }
    private static var archive = Archive()
    private static var loaded = false
    private static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--gremma-observation-debug") }

    static func begin() -> String? {
        guard enabled else { return nil }
        if !loaded {
            loaded = true
            if let url = try? fileURL(), let data = try? Data(contentsOf: url),
               let previous = try? JSONDecoder().decode(Archive.self, from: data), previous.schemaVersion == 1 {
                archive = previous
            }
        }
        let id = UUID().uuidString
        archive.records.append(Record(id: id, startedAt: now(), updatedAt: now(), status: "describing", attempts: []))
        archive.records = Array(archive.records.suffix(8))
        archive.latestRecordID = id
        persist()
        return id
    }

    static func described(_ id: String?, text: String) {
        update(id) { $0.visualDescription = text; $0.status = "extracting" }
    }

    static func received(_ id: String?, attempt: Int, raw: String) {
        update(id) { record in
            record.attempts.append(Attempt(number: attempt, rawResponse: raw, status: "validating"))
        }
    }

    static func attemptOutcome(_ id: String?, attempt: Int, status: String,
                               category: String? = nil, message: String? = nil) {
        update(id) { record in
            if let index = record.attempts.lastIndex(where: { $0.number == attempt }) {
                record.attempts[index].status = status
                record.attempts[index].failureCategory = category
                record.attempts[index].failureMessage = message
            } else {
                record.attempts.append(Attempt(number: attempt, status: status,
                                              failureCategory: category, failureMessage: message))
            }
        }
    }

    static func finish(_ id: String?, status: String, category: String? = nil,
                       message: String? = nil, itemCount: Int? = nil) {
        update(id) { record in
            record.status = status; record.failureCategory = category
            record.failureMessage = message; record.itemCount = itemCount
        }
    }

    /// Records early exits without converting a logging failure into an inference failure.
    static func finishIfOpen(_ id: String?) {
        guard let id, let record = archive.records.first(where: { $0.id == id }),
              ["describing", "extracting"].contains(record.status) else { return }
        finish(id, status: "exited_before_result", category: "UnclassifiedExit")
    }

    private static func update(_ id: String?, _ change: (inout Record) -> Void) {
        guard enabled, let id, let index = archive.records.firstIndex(where: { $0.id == id }) else { return }
        change(&archive.records[index])
        archive.records[index].updatedAt = now()
        persist()
    }

    private static func persist() {
        guard enabled else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(archive).write(to: fileURL(), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // Metadata only on the console; never print the captured model text.
            print("[GremmaObservationDebug] Could not save the explicit local debug capture: \(error.localizedDescription)")
        }
    }

    private static func fileURL() throws -> URL {
        var directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return directory.appendingPathComponent("observation-debug-latest.json")
    }
    private static func now() -> String { ISO8601DateFormatter().string(from: Date()) }
}
