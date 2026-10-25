import Foundation

struct VideoSpeechFailure: Codable, Equatable, Sendable {
    let domain: String
    let code: Int
    let message: String

    init(_ error: NSError) {
        domain = error.domain
        code = error.code
        message = error.localizedDescription
    }

    var nativeError: NSError {
        NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

enum VideoSpeechCallbackDecision: Equatable, Sendable {
    case waiting
    case transcript(String)
    case noSpeech
    case failed(VideoSpeechFailure)
}

/// Interpret the recognition callback without converting infrastructure failures
/// into silence. Apple documents precisely this domain/code as no recognized speech:
/// https://developer.apple.com/documentation/speech/sfspeechrecognitiontask/error
enum VideoSpeechPolicy {
    static func classify(text: String?, isFinal: Bool, error: NSError?) -> VideoSpeechCallbackDecision {
        let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A completed, nonempty recognition result is usable even when the same
        // callback also reports teardown failure. Never promote partial text.
        if isFinal && !text.isEmpty { return .transcript(text) }
        if let error {
            if error.domain == "kAFAssistantErrorDomain", error.code == 1110 {
                return .noSpeech
            }
            return .failed(VideoSpeechFailure(error))
        }
        if isFinal { return .noSpeech }
        return .waiting
    }
}
