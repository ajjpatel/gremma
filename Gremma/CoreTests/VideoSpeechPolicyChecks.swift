import Foundation

private struct PolicyCheckFailure: Error {
    let message: String
}

@main
struct VideoSpeechPolicyChecks {
    static func main() throws {
        var count = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw PolicyCheckFailure(message: message) }
            count += 1
        }
        func native(_ domain: String, _ code: Int, _ description: String) -> NSError {
            NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: description])
        }
        let noSpeech = native("kAFAssistantErrorDomain", 1110, "No speech detected")
        try check(VideoSpeechPolicy.classify(text: nil, isFinal: false, error: noSpeech) == .noSpeech,
                  "A non-speaking activity clip must finish its optional audio step")
        try check(VideoSpeechPolicy.classify(text: nil, isFinal: false,
                    error: native("kAFAssistantErrorDomain", 1110, "Localized message")) == .noSpeech,
                  "Classification must use native domain/code, not English text")
        let disconnected = native("kAFAssistantErrorDomain", 1101, "No speech detected")
        try check(VideoSpeechPolicy.classify(text: nil, isFinal: false, error: disconnected) == .failed(VideoSpeechFailure(disconnected)),
                  "A speech process failure cannot be relabeled as silence")
        let wrongDomain = native("NSURLErrorDomain", 1110, "No speech detected")
        try check(VideoSpeechPolicy.classify(text: nil, isFinal: false, error: wrongDomain) == .failed(VideoSpeechFailure(wrongDomain)),
                  "Matching code in an unrelated domain must remain a failure")
        let unauthorized = native("kAFAssistantErrorDomain", 1700, "Not authorized")
        try check(VideoSpeechPolicy.classify(text: "  ", isFinal: true, error: unauthorized) == .failed(VideoSpeechFailure(unauthorized)),
                  "An empty result cannot hide a permission failure")
        try check(VideoSpeechPolicy.classify(text: "  The keys are on the desk.  ", isFinal: true, error: disconnected)
                    == .transcript("The keys are on the desk."),
                  "A valid final transcript takes precedence over teardown error")
        try check(VideoSpeechPolicy.classify(text: "partial words", isFinal: false, error: disconnected)
                    == .failed(VideoSpeechFailure(disconnected)),
                  "Partial words must not turn a failed task into success")
        try check(VideoSpeechPolicy.classify(text: "partial words", isFinal: false, error: nil) == .waiting,
                  "Partial results must wait for a final callback")
        try check(VideoSpeechPolicy.classify(text: nil, isFinal: false, error: nil) == .waiting,
                  "A progress-only callback must not complete as silence")
        try check(VideoSpeechPolicy.classify(text: " \n", isFinal: true, error: nil) == .noSpeech,
                  "A successful empty final result means no recognized speech")
        try check(VideoSpeechPolicy.classify(text: "hello", isFinal: true, error: noSpeech) == .transcript("hello"),
                  "A valid final transcript wins even over an inconsistent no-speech callback")
        let cancelled = native("kLSRErrorDomain", 301, "Request was canceled")
        try check(VideoSpeechPolicy.classify(text: nil, isFinal: false, error: cancelled) == .failed(VideoSpeechFailure(cancelled)),
                  "Cancellation cannot be called no speech")
        let wrapped = NSError(domain: "SFSpeechErrorDomain", code: 1, userInfo: [NSUnderlyingErrorKey: noSpeech])
        try check(VideoSpeechPolicy.classify(text: nil, isFinal: false, error: wrapped) == .failed(VideoSpeechFailure(wrapped)),
                  "A different top-level infrastructure error must remain visible")
        let diagnostic = VideoSpeechFailure(disconnected)
        try check(diagnostic.domain == "kAFAssistantErrorDomain" && diagnostic.code == 1101
                    && diagnostic.nativeError.domain == disconnected.domain && diagnostic.nativeError.code == disconnected.code,
                  "Failure diagnostics must retain native domain and code")
        let roundTrip = try JSONDecoder().decode(VideoSpeechFailure.self, from: JSONEncoder().encode(diagnostic))
        try check(roundTrip == diagnostic, "Persisted error evidence must survive encoding")
        print("\(count) optional clip speech policy checks passed")
    }
}
