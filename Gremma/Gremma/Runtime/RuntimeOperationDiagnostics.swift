import Foundation

/// Metadata only. Never stores model input/output, images, audio, or file paths.
struct RuntimeOperationDiagnostics: Codable {
    var schemaVersion = 1
    let operationID: UUID
    let kind: String
    let startedAt: Date
    var updatedAt: Date
    var phase: String
    var elapsedSeconds: TimeInterval = 0
    var requiresRestart = false
    var deadlineReason: RuntimeDeadlineReason?
    var errorType: String?
    var phaseBeforeFailure: String?
    var generation: InferenceDiagnostics?
    var availableProcessMemoryBytes: UInt64 = RuntimeMemory.availableBytes

    func persist() throws {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
        var directory = documents.appendingPathComponent("Diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent("runtime-latest.json"), options: .atomic)
    }
}
