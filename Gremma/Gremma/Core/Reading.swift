import Foundation
#if canImport(Vision)
import Vision
#endif

/// Vision image coordinates: normalized to 0...1 with the origin at the bottom left.
public struct EvidenceRect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct RecognizedLine: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let confidence: Float
    public let bounds: EvidenceRect
    public init(id: UUID = UUID(), text: String, confidence: Float, bounds: EvidenceRect = EvidenceRect(x: 0, y: 0, width: 1, height: 1)) {
        self.id = id; self.text = text; self.confidence = confidence; self.bounds = bounds
    }
}

public struct ReadingResult: Codable, Equatable, Sendable {
    public let lines: [RecognizedLine]
    public let capturedAt: Date
    public init(lines: [RecognizedLine], capturedAt: Date = Date()) { self.lines = lines; self.capturedAt = capturedAt }
    public var rawText: String { lines.map(\.text).joined(separator: "\n") }
}

public enum ReadingMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case text, medicine, expiry, currency
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .text: return "Read text"
        case .medicine: return "Medicine label"
        case .expiry: return "Expiry marking"
        case .currency: return "US currency"
        }
    }
}

public struct ReadingField: Identifiable, Codable, Equatable, Sendable {
    public var id: String { label }
    public let label: String
    public let value: String
    public let evidenceLineIDs: [UUID]
    public init(label: String, value: String, evidenceLineIDs: [UUID]) {
        self.label = label; self.value = value; self.evidenceLineIDs = evidenceLineIDs
    }
}

public struct ReadingInterpretation: Equatable, Sendable {
    public let title: String
    public let spokenText: String
    public let fields: [ReadingField]
    public let needsRetake: Bool
    public let warnings: [String]
}

/// Extractive only: never invents missing digits, units, dates, instructions, or currencies.
/// OCR confidence is a capture-quality heuristic, not a guarantee that text is correct.
public enum ReadingInterpreter {
    public static func describe(_ result: ReadingResult, mode: ReadingMode, minimumConfidence: Float = 0.80) -> ReadingInterpretation {
        let usable = result.lines.filter { $0.confidence >= minimumConfidence && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !usable.isEmpty else {
            return refusal(mode, "I can't read that clearly. Hold the camera steady, include the full label, and try more light.")
        }
        let omitted = usable.count < result.lines.count
        // For high-stakes labels a partially uncertain result must not be presented as complete.
        if mode == .medicine && omitted {
            return refusal(mode, "Part of this medicine label is unclear. Please take a clearer picture of the full label. I won't fill in missing words or numbers.")
        }
        if mode == .currency && result.lines.contains(where: { $0.confidence < minimumConfidence && matches(#"\b(?:USD|DOLLARS?)\b|\$\s*\d"#, $0.text) }) {
            return refusal(mode, "A currency or denomination marking is unclear. Please show one note clearly; I won't choose a value from uncertain text.")
        }
        switch mode {
        case .text:
            let fields = usable.enumerated().map { index, line in
                ReadingField(label: "Line \(index + 1)", value: line.text, evidenceLineIDs: [line.id])
            }
            let warning = omitted ? "Some text is unclear and has been left out. " : ""
            return ReadingInterpretation(title: "Visible text", spokenText: warning + usable.map(\.text).joined(separator: ". "), fields: fields, needsRetake: omitted, warnings: omitted ? ["Some low-confidence text was omitted."] : [])
        case .medicine:
            // The complete reliable OCR is the evidence. The first line is not presumed to be a drug name.
            let field = ReadingField(label: "Label text as recognized", value: usable.map(\.text).joined(separator: "\n"), evidenceLineIDs: usable.map(\.id))
            return ReadingInterpretation(title: "Medicine label text", spokenText: "The visible label reads: " + usable.map(\.text).joined(separator: ". ") + ". This is camera-recognized text and can contain mistakes. For advice on taking medicine, check with a pharmacist or doctor.", fields: [field], needsRetake: false, warnings: ["OCR can misread words and numbers. This is not dosing or medical advice."])
        case .expiry:
            return expiry(usable, mode: mode)
        case .currency:
            return currency(usable, mode: mode)
        }
    }

    private static func expiry(_ lines: [RecognizedLine], mode: ReadingMode) -> ReadingInterpretation {
        let marker = #"\b(?:exp(?:iry|ires|iration)?|use[\s-]+by|best[\s-]+before)\b"#
        var relevant: [RecognizedLine] = []
        for (index, line) in lines.enumerated() where matches(marker, line.text) {
            relevant.append(line)
            // Some packages print the marker and value on consecutive lines. Copy rather than infer.
            if !hasDateLikeValue(line.text), index + 1 < lines.count, hasDateLikeValue(lines[index + 1].text) {
                relevant.append(lines[index + 1])
            }
        }
        var seen = Set<UUID>()
        relevant = relevant.filter { seen.insert($0.id).inserted }
        guard !relevant.isEmpty, relevant.contains(where: { hasDateLikeValue($0.text) }) else {
            return refusal(mode, "I can't find a clear expiry or best-before marking. Show the printed date and its label together.")
        }
        let text = relevant.map(\.text).joined(separator: " ")
        return ReadingInterpretation(title: "Date marking as printed", spokenText: "The date marking reads: \(text). I'm repeating the printed marking without interpreting an ambiguous date or deciding whether this item is safe to use.", fields: [ReadingField(label: "Printed marking", value: text, evidenceLineIDs: relevant.map(\.id))], needsRetake: false, warnings: ["Numeric date order may be ambiguous. No freshness or safety judgment is made."])
    }

    private static func currency(_ lines: [RecognizedLine], mode: ReadingMode) -> ReadingInterpretation {
        let text = lines.map(\.text).joined(separator: " ").uppercased()
        guard matches(#"\bUNITED STATES\b|\bUSD\b|\bUS DOLLARS?\b|\bU\.S\."#, text) else {
            return refusal(mode, "I can't confirm the currency from the visible text. Show one note with its currency name and denomination. This prototype recognizes printed US dollar denominations.")
        }
        let phrases: [(String, Int)] = [("ONE HUNDRED", 100), ("FIFTY", 50), ("TWENTY", 20), ("TEN", 10), ("FIVE", 5), ("TWO", 2), ("ONE", 1)]
        var amounts = Set<Int>()
        for (phrase, amount) in phrases where matches("\\b\(phrase)\\s+DOLLARS?\\b", text) { amounts.insert(amount) }
        let regex = try! NSRegularExpression(pattern: #"(?:\$\s*|\bUSD\s*)(100|50|20|10|5|2|1)(?![A-Z\d.,])"#)
        let nsText = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            if let amount = Int(nsText.substring(with: match.range(at: 1))) { amounts.insert(amount) }
        }
        guard amounts.count == 1, let amount = amounts.first else {
            return refusal(mode, amounts.isEmpty ? "I can see US currency text, but can't confirm a denomination. Show the full printed denomination." : "I found conflicting denominations. Please show one note clearly; I won't choose one.")
        }
        return ReadingInterpretation(title: "Printed US denomination", spokenText: "The visible text indicates \(amount) US \(amount == 1 ? "dollar" : "dollars"). This does not authenticate the note.", fields: [ReadingField(label: "Denomination from visible text", value: "USD \(amount)", evidenceLineIDs: lines.map(\.id))], needsRetake: false, warnings: ["Recognition is limited to clearly printed US dollar denominations; it does not authenticate money."])
    }

    private static func refusal(_ mode: ReadingMode, _ message: String) -> ReadingInterpretation {
        ReadingInterpretation(title: mode.title, spokenText: message, fields: [], needsRetake: true, warnings: [])
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func hasDateLikeValue(_ text: String) -> Bool {
        matches(#"\b\d{1,4}[./-]\d{1,2}(?:[./-]\d{1,4})?\b|\b(?:JAN(?:UARY)?|FEB(?:RUARY)?|MAR(?:CH)?|APR(?:IL)?|MAY|JUN(?:E)?|JUL(?:Y)?|AUG(?:UST)?|SEP(?:TEMBER)?|OCT(?:OBER)?|NOV(?:EMBER)?|DEC(?:EMBER)?)\s+\d{2,4}\b|\b20\d{2}\b"#, text)
    }
}

#if canImport(Vision)
/// Keeps Vision work away from the UI actor and disables language correction for literal labels.
public actor ReadingService {
    public init() {}

    public func recognize(imageData: Data) async throws -> ReadingResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(data: imageData, options: [:])
        try handler.perform([request])
        let observations = (request.results ?? []).sorted { left, right in
            // Quantize vertical positions to create stable lines before sorting left-to-right.
            let leftRow = Int((left.boundingBox.midY * 50).rounded())
            let rightRow = Int((right.boundingBox.midY * 50).rounded())
            return leftRow == rightRow ? left.boundingBox.minX < right.boundingBox.minX : leftRow > rightRow
        }
        let lines = observations.compactMap { observation -> RecognizedLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let rect = observation.boundingBox
            return RecognizedLine(text: candidate.string, confidence: candidate.confidence,
                                  bounds: EvidenceRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height))
        }
        return ReadingResult(lines: lines)
    }
}
#endif
