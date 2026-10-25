import Foundation
import SQLite3

public enum ActivityStoreError: LocalizedError {
    case database(String), invalidEvent, invalidTranscript, unsupportedVersion
    public var errorDescription: String? {
        switch self {
        case .database: return "Activity memory could not be saved. Your existing activity records are unchanged."
        case .invalidEvent: return "This activity has invalid evidence or timing and was not saved."
        case .invalidTranscript: return "This transcript has invalid evidence or timing and was not saved."
        case .unsupportedVersion: return "This activity database was created by a newer app and has been preserved."
        }
    }
}

/// SQLite transactions couple segment replacement with its retrieval fields. A retry is idempotent.
/// The original AsterMemory store is deliberately untouched during this additive migration.
public actor ActivityRepository {
    private let db: OpaquePointer
    public let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(directory requestedDirectory: URL? = nil) throws {
        let directory = try requestedDirectory ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("GremmaActivity", isDirectory: true)
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var privateDirectory = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try privateDirectory.setResourceValues(values)
        var opened: OpaquePointer?
        let status = sqlite3_open_v2(directory.appendingPathComponent("activities.sqlite").path, &opened,
                                    SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let opened else {
            if let opened { sqlite3_close(opened) }
            throw ActivityStoreError.database("open")
        }
        db = opened
        do {
            sqlite3_busy_timeout(opened, 2_000)
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(opened, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else { throw ActivityStoreError.database("version") }
            let version = sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : -1
            sqlite3_finalize(statement)
            guard version == 0 || version == 1 else { throw ActivityStoreError.unsupportedVersion }
            let schema = """
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=FULL;
            CREATE TABLE IF NOT EXISTS activity_events (
              id TEXT PRIMARY KEY, video_id TEXT NOT NULL, segment_id TEXT NOT NULL,
              entity_key TEXT NOT NULL, kind TEXT NOT NULL, occurred_at REAL, indexed_at REAL NOT NULL,
              payload BLOB NOT NULL
            );
            CREATE INDEX IF NOT EXISTS activity_entity_time ON activity_events(entity_key,occurred_at);
            CREATE INDEX IF NOT EXISTS activity_time ON activity_events(occurred_at);
            CREATE INDEX IF NOT EXISTS activity_video_segment ON activity_events(video_id,segment_id);
            CREATE TABLE IF NOT EXISTS activity_transcripts (
              id TEXT PRIMARY KEY, video_id TEXT NOT NULL, chunk_id TEXT NOT NULL,
              occurred_at REAL, text TEXT NOT NULL, payload BLOB NOT NULL,
              UNIQUE(video_id,chunk_id)
            );
            CREATE INDEX IF NOT EXISTS transcript_time ON activity_transcripts(occurred_at);
            PRAGMA user_version=1;
            """
            guard sqlite3_exec(opened, schema, nil, nil, nil) == SQLITE_OK else { throw ActivityStoreError.database("schema") }
        } catch {
            sqlite3_close(opened)
            throw error
        }
    }

    deinit { sqlite3_close(db) }

    public func events() throws -> [ActivityEvent] {
        try decodeRows("SELECT payload FROM activity_events ORDER BY occurred_at IS NULL, occurred_at DESC, indexed_at DESC, id", bindings: [])
    }

    public func transcripts() throws -> [ActivityTranscript] {
        try decodeRows("SELECT payload FROM activity_transcripts ORDER BY occurred_at IS NULL, occurred_at DESC, video_id, chunk_id", bindings: [])
    }

    public func replaceSegment(videoID: String, segmentID: String, events: [ActivityEvent]) throws {
        guard !videoID.isEmpty, !segmentID.isEmpty, events.count <= 40,
              Set(events.map(\.id)).count == events.count,
              events.allSatisfy({ Self.valid($0) && $0.videoID == videoID && $0.segmentID == segmentID }) else { throw ActivityStoreError.invalidEvent }
        // Encode before beginning the write transaction so malformed values cannot delete previous data.
        let payloads = try events.map { try encoder.encode($0) }
        try transaction {
            let existing: [ActivityEvent] = try decodeRows("SELECT payload FROM activity_events WHERE video_id=? AND segment_id=?",
                bindings: [.text(videoID), .text(segmentID)])
            let confirmedUpdates = Set(events.filter(\.isUserConfirmed).map(\.id))
            let retained = existing.filter { $0.isUserConfirmed && !confirmedUpdates.contains($0.id) }
            let retainedIDs = Set(retained.map(\.id))
            // Reanalysis may replace model output, including with an empty result,
            // but only another explicit confirmation can revise a confirmed row.
            let replacements = zip(events, payloads).filter { !retainedIDs.contains($0.0.id) }
                + (try retained.map { ($0, try encoder.encode($0)) })
            try execute("DELETE FROM activity_events WHERE video_id=? AND segment_id=?", [.text(videoID), .text(segmentID)])
            for (event, payload) in replacements {
                try execute("INSERT INTO activity_events(id,video_id,segment_id,entity_key,kind,occurred_at,indexed_at,payload) VALUES(?,?,?,?,?,?,?,?)", [
                    .text(event.id), .text(videoID), .text(segmentID), .text(event.entityKey), .text(event.kind.rawValue),
                    event.occurredAt.map { .number($0.timeIntervalSince1970) } ?? .null,
                    .number(event.indexedAt.timeIntervalSince1970), .data(payload)
                ])
            }
        }
    }

    public func saveTranscript(_ transcript: ActivityTranscript) throws {
        guard !transcript.id.isEmpty, !transcript.videoID.isEmpty, !transcript.chunkID.isEmpty,
              transcript.text.count <= 30_000, Self.validRange(transcript.startSeconds, transcript.endSeconds),
              transcript.occurredAt?.timeIntervalSince1970.isFinite ?? true else { throw ActivityStoreError.invalidTranscript }
        let payload = try encoder.encode(transcript)
        try transaction {
            try execute("DELETE FROM activity_transcripts WHERE video_id=? AND chunk_id=?", [.text(transcript.videoID), .text(transcript.chunkID)])
            try execute("INSERT INTO activity_transcripts(id,video_id,chunk_id,occurred_at,text,payload) VALUES(?,?,?,?,?,?)", [
                .text(transcript.id), .text(transcript.videoID), .text(transcript.chunkID),
                transcript.occurredAt.map { .number($0.timeIntervalSince1970) } ?? .null,
                .text(transcript.text), .data(payload)
            ])
        }
    }

    public func deleteVideo(id: String) throws {
        try transaction {
            try execute("DELETE FROM activity_events WHERE video_id=?", [.text(id)])
            try execute("DELETE FROM activity_transcripts WHERE video_id=?", [.text(id)])
        }
    }

    public func deleteAll() throws {
        try transaction {
            try execute("DELETE FROM activity_events")
            try execute("DELETE FROM activity_transcripts")
        }
    }

    /// No inference: occurrence time, not arrival/import time, controls daily views.
    public func events(on date: Date, calendar: Calendar = .current) throws -> [ActivityEvent] {
        let interval = Self.dayInterval(date, calendar: calendar)
        return try events(in: interval)
    }

    public func medicineLogStatus(for window: MedicineLogWindow, on date: Date = Date(), calendar: Calendar = .current,
                                  asOf now: Date = Date()) throws -> MedicineVideoLogStatus {
        let events = try events(in: window.interval(on: date, calendar: calendar)).filter {
            $0.kind == .medicine && ($0.occurredAt.map { $0 <= now } ?? false) && $0.indexedAt <= now
        }
        return MedicineVideoLogStatus(window: window, date: date, events: events)
    }

    public func answer(query: String, now: Date = Date(), calendar: Calendar = .current) throws -> ActivityAnswer? {
        let known = Set(try stringRows("SELECT DISTINCT entity_key FROM activity_events", []))
        guard let request = ActivityQuery.parse(query, knownEntities: known) else { return nil }
        switch request {
        case .medicine(let requestedWindow, let offset):
            let day = calendar.date(byAdding: .day, value: offset, to: now) ?? now
            let window = requestedWindow ?? (calendar.component(.hour, from: now) < 12 ? .morning : .evening)
            let status = try medicineLogStatus(for: window, on: day, calendar: calendar, asOf: now)
            let text = offset == -1 ? status.message.replacingOccurrences(of: "this \(window.rawValue)", with: "yesterday \(window.rawValue)") : status.message
            return ActivityAnswer(text: text, event: status.events.first(where: \.hasClearEvidence) ?? status.events.first)
        case .location(let requested, let offset):
            return try locationAnswer(requested, knownEntities: known, dayOffset: offset, now: now, calendar: calendar)
        case .timeline(let offset):
            let selected: [ActivityEvent]
            if let offset { selected = try events(on: calendar.date(byAdding: .day, value: offset, to: now) ?? now, calendar: calendar) }
            else { selected = try events() }
            guard !selected.isEmpty else { return ActivityAnswer(text: "No activities have been logged\(offset == -1 ? " for yesterday" : (offset == 0 ? " for today" : "")) yet.") }
            let ordered = selected.prefix(8).reversed()
            let lines = ordered.map { event in
                let when = event.occurredAt?.formatted(date: offset == nil ? .abbreviated : .omitted, time: .shortened) ?? "Unknown recording date"
                return "\(when): \(event.isUncertain || !event.hasClearEvidence ? "Possibly " : "")\(event.sourcedSummary.prefix(200))"
            }
            let prefix = selected.count > 8 ? "Here are the latest eight recorded activities. " : "Here is the recorded activity. "
            return ActivityAnswer(text: prefix + lines.joined(separator: ". "), event: selected.first)
        case .conversation(let requested, let offset):
            return try conversationAnswer(requested, dayOffset: offset, now: now, calendar: calendar)
        }
    }

    /// Small bounded evidence set for Gemma's open-ended answer path; content remains untrusted data.
    public func relevantContext(for query: String, limit: Int = 6, naturalSampleVideoIDs: Set<String> = []) throws -> String {
        try recallEvidence(for: query, limit: limit, naturalSampleVideoIDs: naturalSampleVideoIDs).text
    }

    public func recallEvidence(for query: String, limit: Int = 6, naturalSampleVideoIDs: Set<String> = []) throws -> ActivityRecallEvidence {
        let allowSamples = ActivityEvidenceScope.permitsNaturalSamples(query)
        let scope = ActivityEvidenceScope.resolve(query)
        let clipNumber = scope == .demo ? ActivityEvidenceScope.clipNumber(query) : nil
        var terms = ActivityText.queryWords(query)
        if clipNumber != nil {
            terms.subtract(["number", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen"])
            terms = terms.filter { Int($0) == nil }
        }
        let allEvents = try events()
        let demoVideoIDs = Set(allEvents.filter(\.isDemoFootage).map(\.videoID))
        let sourceEvents = allEvents.filter { event in
            switch scope {
            case .personal: return !event.isDemoFootage || (allowSamples && naturalSampleVideoIDs.contains(event.videoID))
            case .all: return true
            case .demo:
                guard event.isDemoFootage else { return false }
                return clipNumber == nil || ActivityEvidenceScope.clipNumber(event.summary) == clipNumber
            }
        }
        var eventRows = sourceEvents.map { event in (event, terms.intersection(ActivityText.queryWords(event.entity + " " + event.summary + " " + event.location)).count) }
            .filter { terms.isEmpty || $0.1 > 0 }.sorted { $0.1 == $1.1 ? ($0.0.occurredAt ?? .distantPast) > ($1.0.occurredAt ?? .distantPast) : $0.1 > $1.1 }.prefix(max(1, min(limit, 10)))
        // Existing personal evidence outranks sample footage for an ordinary question.
        if scope == .personal, eventRows.contains(where: { !$0.0.isDemoFootage }) {
            eventRows = eventRows.filter { !$0.0.isDemoFootage }[...]
        }
        let transcriptRows = try transcripts().filter { row in
            switch scope {
            case .personal: return !demoVideoIDs.contains(row.videoID)
            case .all: return true
            case .demo: return false // Demo imports are visual evidence, never personal conversation transcripts.
            }
        }.map { row in (row, terms.intersection(ActivityText.queryWords(row.text)).count) }
            .filter { terms.isEmpty || $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(2)
        let eventText = eventRows.map { row in
            "VIDEO EVENT [\(row.0.videoID), \(row.0.startSeconds)s; \(row.0.timeDescription); \(row.0.hasClearEvidence ? "observed" : "uncertain")]: \(row.0.sourcedSummary)"
        }
        let spokenText = transcriptRows.map { row in
            "UNVERIFIED TRANSCRIPT [\(row.0.videoID), \(row.0.startSeconds)s; \(row.0.occurredAt?.formatted(date: .abbreviated, time: .shortened) ?? "date unknown")]: \(row.0.text.prefix(500))"
        }
        // Keep the answer path's existing 6,000-character ceiling, but budget
        // complete records. A note's final sentence may contain the outcome;
        // a per-row prefix can remove that evidence or even cut a word in half.
        var selected: [String] = []
        var count = 0
        for record in eventText + spokenText {
            let cost = record.count + (selected.isEmpty ? 0 : 1)
            guard count + cost <= 6_000 else { continue }
            selected.append(record)
            count += cost
        }
        return ActivityRecallEvidence(text: selected.joined(separator: "\n"), event: eventRows.first?.0,
            includesSamples: eventRows.contains { $0.0.isDemoFootage })
    }

    public func relevantContext(query: String, limit: Int = 6) throws -> String {
        try relevantContext(for: query, limit: limit)
    }

    private func locationAnswer(_ query: String, knownEntities: Set<String>, dayOffset: Int?, now: Date, calendar: Calendar) throws -> ActivityAnswer {
        let terms = ActivityText.queryWords(query)
        let entityKeys = knownEntities.filter { !terms.isDisjoint(with: ActivityText.queryWords($0)) }.sorted()
        var source: [ActivityEvent] = []
        if !entityKeys.isEmpty {
            let placeholders = Array(repeating: "?", count: entityKeys.count).joined(separator: ",")
            var sql = "SELECT payload FROM activity_events WHERE entity_key IN (\(placeholders))"
            var bindings = entityKeys.map(Binding.text)
            if let offset = dayOffset {
                let interval = Self.dayInterval(calendar.date(byAdding: .day, value: offset, to: now) ?? now, calendar: calendar)
                sql += " AND occurred_at>=? AND occurred_at<?"
                bindings += [.number(interval.start.timeIntervalSince1970), .number(interval.end.timeIntervalSince1970)]
            }
            sql += " ORDER BY occurred_at IS NULL, occurred_at DESC, indexed_at DESC, id"
            source = try decodeRows(sql, bindings: bindings)
        }
        let matching = source.filter { !$0.isDemoFootage && [.placed, .pickedUp, .moved, .sighting].contains($0.kind) }
        guard !matching.isEmpty else { return ActivityAnswer(text: "I don't have a matching object activity in the saved videos\(dayOffset == -1 ? " for yesterday" : (dayOffset == 0 ? " for today" : "")) yet.") }
        let identities = Set(matching.map(\.entityKey))
        // Generic "keys" must not silently choose between car keys and house keys.
        if identities.count > 1 {
            let exact = ActivityText.entityKey(terms.sorted().joined(separator: " "))
            let exactRows = matching.filter { Set($0.entityKey.split(separator: " ").map(String.init)) == Set(exact.split(separator: " ").map(String.init)) }
            if exactRows.isEmpty {
                return ActivityAnswer(text: "I found more than one possible item: \(identities.sorted().joined(separator: ", ")). Which one do you mean?")
            }
            return Self.answerLocationEvents(exactRows)
        }
        return Self.answerLocationEvents(matching)
    }

    private static func answerLocationEvents(_ events: [ActivityEvent]) -> ActivityAnswer {
        let dated = events.filter { $0.occurredAt != nil }.sorted { $0.occurredAt! > $1.occurredAt! }
        let undated = events.filter { $0.occurredAt == nil }
        guard let latest = dated.first else {
            let sample = undated[0]
            return ActivityAnswer(text: "There is video evidence for \(sample.entity), but its recording date is unknown. I can't tell which activity happened last.\(confirmationNotice(sample))", event: sample)
        }
        // Different actions with identical timestamps have no supported temporal order.
        let simultaneous = dated.filter { $0.occurredAt == latest.occurredAt }
        if Set(simultaneous.map { $0.kind.rawValue + ":" + ActivityText.normalized($0.location) }).count > 1 {
            return ActivityAnswer(text: "There are conflicting activities for \(latest.entity) at the same recorded time. I can't determine the latest location.", event: latest)
        }
        guard latest.hasClearEvidence else {
            return ActivityAnswer(text: "The latest video for \(latest.entity) is unclear. I can't establish its latest location from that activity.\(confirmationNotice(latest))", event: latest)
        }
        let date = latest.timeDescription
        let unknownSuffix = undated.isEmpty ? "" : " Other videos have unknown recording dates, so I can't confirm this was the most recent activity."
        if latest.kind == .pickedUp {
            return ActivityAnswer(text: "The latest video showed \(latest.entity) being picked up at \(date). I haven't seen where they went next.\(confirmationNotice(latest))\(unknownSuffix)", event: latest)
        }
        guard !latest.location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ActivityAnswer(text: "The latest video showed \(latest.entity) moving at \(date), but the new location wasn't clear.\(confirmationNotice(latest))\(unknownSuffix)", event: latest)
        }
        return ActivityAnswer(text: "Last seen: \(latest.entity), \(latest.location), at \(date).\(confirmationNotice(latest, hasObservedLocation: true)) This is the latest dated sighting in the saved videos.\(unknownSuffix)", event: latest)
    }

    private static func confirmationNotice(_ event: ActivityEvent, hasObservedLocation: Bool = false) -> String {
        guard event.isUserConfirmed else { return "" }
        return hasObservedLocation
            ? " You confirmed the object label and activity; the location was observed in the video."
            : " You confirmed the object label and activity."
    }

    private func conversationAnswer(_ query: String, dayOffset: Int?, now: Date, calendar: Calendar) throws -> ActivityAnswer {
        var rows = try transcripts().filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let offset = dayOffset {
            let interval = Self.dayInterval(calendar.date(byAdding: .day, value: offset, to: now) ?? now, calendar: calendar)
            rows = rows.filter { $0.occurredAt.map { $0 >= interval.start && $0 < interval.end } ?? false }
        }
        let terms = ActivityText.queryWords(query)
        if !terms.isEmpty {
            let scored = rows.map { ($0, terms.intersection(ActivityText.queryWords($0.text)).count) }
                .filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
            rows = scored.map(\.0)
        }
        guard let first = rows.first else { return ActivityAnswer(text: "I don't have a matching conversation transcript in the saved videos yet.") }
        let when = first.occurredAt?.formatted(date: .abbreviated, time: .shortened) ?? "an unknown recording date"
        return ActivityAnswer(text: "In the video from \(when), the transcript says: \(first.text.prefix(650)). Transcription may contain mistakes.", transcript: first)
    }

    private func events(in interval: DateInterval) throws -> [ActivityEvent] {
        let rows: [ActivityEvent] = try decodeRows("SELECT payload FROM activity_events WHERE occurred_at>=? AND occurred_at<? ORDER BY occurred_at DESC,id", bindings: [.number(interval.start.timeIntervalSince1970), .number(interval.end.timeIntervalSince1970)])
        return rows.filter { !$0.isDemoFootage }
    }

    private static func dayInterval(_ date: Date, calendar: Calendar) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
    }

    private static func validRange(_ start: Double, _ end: Double) -> Bool { start.isFinite && end.isFinite && start >= 0 && end >= start && end <= 86_400 }
    private static func valid(_ event: ActivityEvent) -> Bool {
        !event.id.isEmpty && !event.videoID.isEmpty && !event.segmentID.isEmpty && !event.entityKey.isEmpty &&
        event.entity.count <= 200 && event.location.count <= 500 && event.summary.count <= 3_000 &&
        validRange(event.startSeconds, event.endSeconds) && event.confidence.isFinite && (0...1).contains(event.confidence) &&
        event.indexedAt.timeIntervalSince1970.isFinite && (event.occurredAt?.timeIntervalSince1970.isFinite ?? true)
    }

    private enum Binding { case text(String), number(Double), data(Data), null }
    private func prepare(_ sql: String, _ bindings: [Binding]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw ActivityStoreError.database("prepare") }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            switch value {
            case .text(let text): result = sqlite3_bind_text(statement, position, text, -1, transient)
            case .number(let value): result = sqlite3_bind_double(statement, position, value)
            case .null: result = sqlite3_bind_null(statement, position)
            case .data(let data): result = data.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32($0.count), transient) }
            }
            if result != SQLITE_OK { sqlite3_finalize(statement); throw ActivityStoreError.database("bind") }
        }
        return statement
    }

    private func execute(_ sql: String, _ bindings: [Binding] = []) throws {
        let statement = try prepare(sql, bindings); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ActivityStoreError.database("write") }
    }

    private func decodeRows<T: Decodable>(_ sql: String, bindings: [Binding]) throws -> [T] {
        let statement = try prepare(sql, bindings); defer { sqlite3_finalize(statement) }
        var result: [T] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw ActivityStoreError.database("read") }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            result.append(try decoder.decode(T.self, from: data))
        }
    }

    private func stringRows(_ sql: String, _ bindings: [Binding]) throws -> [String] {
        let statement = try prepare(sql, bindings); defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw ActivityStoreError.database("read") }
            result.append(String(cString: text))
        }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
}
