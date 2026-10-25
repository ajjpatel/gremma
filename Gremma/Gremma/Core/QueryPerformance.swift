import Foundation

struct InferenceMetrics: Codable, Sendable {
    let elapsedSeconds: TimeInterval
    let firstTextSeconds: TimeInterval?
    let characterCount: Int
    let cancelled: Bool
    var startedUptime: TimeInterval = 0
    var lastTextSeconds: TimeInterval?
    var outputTokenCount: Int?
    var decodeTokensPerSecond: Double?
    var nativeFirstTokenSeconds: Double?
}

/// Query duration starts after typed/speech input is accepted and ends when the
/// answer is ready. Text timings use stream arrival; throughput is native decode.
struct QueryPerformance: Codable, Sendable {
    let answerSeconds: Double
    let firstTokenSeconds: Double?
    let lastTokenSeconds: Double?
    /// Mean arrival time per output token after the first, using the native
    /// token count (never characters or stream chunks). Nil for <2 tokens.
    let timePerOutputTokenSeconds: Double?
    let tokensPerSecond: Double?
    let outputTokens: Int?
    let source: String

    init(start: Double, end: Double, inference: InferenceMetrics?) {
        let duration = max(0, end - start)
        answerSeconds = duration
        if let inference, !inference.cancelled, inference.startedUptime >= start,
           inference.startedUptime <= end {
            let offset = inference.startedUptime - start
            firstTokenSeconds = inference.firstTextSeconds.map { min(duration, offset + max(0, $0)) }
            lastTokenSeconds = inference.lastTextSeconds.map { min(duration, offset + max(0, $0)) }
            tokensPerSecond = inference.decodeTokensPerSecond.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            outputTokens = inference.outputTokenCount.flatMap { $0 > 0 ? $0 : nil }
            if let count = outputTokens, count > 1,
               let first = inference.firstTextSeconds, let last = inference.lastTextSeconds,
               first.isFinite, last.isFinite, first >= 0, last >= first {
                timePerOutputTokenSeconds = (last - first) / Double(count - 1)
            } else { timePerOutputTokenSeconds = nil }
            source = "Gemma E4B"
        } else {
            firstTokenSeconds = nil; lastTokenSeconds = nil
            timePerOutputTokenSeconds = nil
            tokensPerSecond = nil; outputTokens = nil
            source = "Saved answer"
        }
    }
}
