import Foundation
@preconcurrency import AVFoundation
@preconcurrency import Speech

enum VideoAudioTranscriptStatus: String, Codable, Sendable {
    case transcribed, noAudio, noSpeech, unavailable
}

struct VideoAudioTranscriptResult: Sendable {
    let text: String
    let status: VideoAudioTranscriptStatus
}

enum VideoAudioTranscriptionError: LocalizedError, CustomNSError {
    case busy, invalidRange, invalidVideo, speechPermissionDenied, offlineUnavailable
    case exportFailed, recognitionFailed(VideoSpeechFailure)

    var nativeFailure: VideoSpeechFailure? {
        if case .recognitionFailed(let failure) = self { return failure }
        return nil
    }

    static var errorDomain: String { "com.gremma.video-audio" }
    var errorCode: Int {
        switch self {
        case .busy: return 1
        case .invalidRange: return 2
        case .invalidVideo: return 3
        case .speechPermissionDenied: return 4
        case .offlineUnavailable: return 5
        case .exportFailed: return 6
        case .recognitionFailed: return 7
        }
    }
    var errorUserInfo: [String: Any] {
        var info: [String: Any] = [NSLocalizedDescriptionKey: errorDescription ?? "Video audio processing failed."]
        if let failure = nativeFailure {
            info["speechErrorDomain"] = failure.domain
            info["speechErrorCode"] = failure.code
            info[NSUnderlyingErrorKey] = failure.nativeError
        }
        return info
    }

    var errorDescription: String? {
        switch self {
        case .busy: return "Another video audio segment is still being transcribed. Try again when it finishes."
        case .invalidRange: return "The video audio segment is invalid. Audio is processed in segments of up to 30 seconds."
        case .invalidVideo: return "The source video is unavailable for transcription."
        case .speechPermissionDenied: return "Allow Speech Recognition for Gremma in Settings to remember conversations from your videos."
        case .offlineUnavailable: return "On-device English transcription is unavailable. Your video is saved; Gremma will not send its audio to a server."
        case .exportFailed: return "This video's audio could not be prepared. The original video is unchanged."
        case .recognitionFailed(let detail): return "Optional clip audio could not be transcribed. Your visual activity is saved. \(detail.message)"
        }
    }
}

/// File-based English transcription. This never opens the microphone or uses a server.
/// The caller cancels live VoiceService listening, persists each returned chunk, and
/// advances its audio checkpoint only after that write succeeds.
@MainActor
final class VideoAudioTranscriber {
    nonisolated static let maximumChunkSeconds: Double = 30
    private var isTranscribing = false

    func transcribe(videoURL: URL, startSeconds: Double,
                    endSeconds: Double) async throws -> VideoAudioTranscriptResult {
        guard !isTranscribing else { throw VideoAudioTranscriptionError.busy }
        guard Self.isValidRange(startSeconds: startSeconds, endSeconds: endSeconds) else {
            throw VideoAudioTranscriptionError.invalidRange
        }
        guard videoURL.isFileURL, FileManager.default.isReadableFile(atPath: videoURL.path) else {
            throw VideoAudioTranscriptionError.invalidVideo
        }
        try Task.checkCancellation()
        isTranscribing = true
        defer { isTranscribing = false }

        let hasAudio = try await BoundedAsync.run(maximumDuration: 20) {
            let asset = AVURLAsset(url: videoURL)
            return try await !asset.loadTracks(withMediaType: .audio).isEmpty
        }
        guard hasAudio else { return VideoAudioTranscriptResult(text: "", status: .noAudio) }

        // Clip audio is optional enrichment. Never interrupt activity recording or
        // indexing with a speech permission prompt, or ask the user to narrate.
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            return VideoAudioTranscriptResult(text: "", status: .unavailable)
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
            return VideoAudioTranscriptResult(text: "", status: .unavailable)
        }
        try Task.checkCancellation()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gremma-transcript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audioURL = directory.appendingPathComponent("audio.m4a")
        // The export worker also removes its output after late cancellation. Removing
        // a temporary file never touches the source recording or persisted transcript.
        defer { try? FileManager.default.removeItem(at: directory) }
        let exporter = try VideoAudioExport(source: videoURL, destination: audioURL,
                                            start: startSeconds, end: endSeconds)
        try await BoundedAsync.run(maximumDuration: 45, cancellationGrace: 1,
                                  onCancellation: { exporter.cancel() }) {
            try await exporter.run()
        }
        try Task.checkCancellation()

        // Only digital silence is skipped. Quiet speech is still sent to the local
        // recognizer; a recognizer failure must not be mislabeled as no speech.
        let isSilent = try await BoundedAsync.run(maximumDuration: 10) {
            try Self.isDigitallySilent(audioURL)
        }
        if isSilent { return VideoAudioTranscriptResult(text: "", status: .noSpeech) }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        let operation = VideoSpeechOperation(recognizer: recognizer, request: request)
        let worker = Task { @MainActor in try await operation.run() }
        let gate = RuntimeDeadlineGate<VideoAudioTranscriptResult>(maximumDuration: 60, cancellationGrace: 1)
        let result = try await gate.wait(for: worker, onCancellation: { operation.cancel() })
        try Task.checkCancellation()
        return result
    }

    nonisolated static func isValidRange(startSeconds: Double, endSeconds: Double) -> Bool {
        startSeconds.isFinite && endSeconds.isFinite && startSeconds >= 0
            && endSeconds > startSeconds && endSeconds - startSeconds <= maximumChunkSeconds + 0.001
    }

    nonisolated private static func isDigitallySilent(_ url: URL) throws -> Bool {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else {
            return false
        }
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            guard let channels = buffer.floatChannelData else { return false }
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) where abs(channels[channel][frame]) > 0.000001 {
                    return false
                }
            }
        }
        return true
    }
}

/// The native exporter may finish after cancellation. Retaining it in this worker
/// keeps resources valid, and the cancelled flag removes any late temporary output.
private final class VideoAudioExport: @unchecked Sendable {
    private let exporter: AVAssetExportSession
    private let destination: URL
    private let lock = NSLock()
    private var cancelled = false

    init(source: URL, destination: URL, start: Double, end: Double) throws {
        guard let exporter = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetAppleM4A) else {
            throw VideoAudioTranscriptionError.exportFailed
        }
        self.exporter = exporter
        self.destination = destination
        exporter.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                        end: CMTime(seconds: end, preferredTimescale: 600))
    }

    func run() async throws {
        guard !isCancelled else { throw CancellationError() }
        do {
            try await exporter.export(to: destination, as: .m4a)
            if isCancelled {
                try? FileManager.default.removeItem(at: destination)
                throw CancellationError()
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if isCancelled { throw CancellationError() }
            throw VideoAudioTranscriptionError.exportFailed
        }
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        exporter.cancelExport()
    }
}

/// Completion is exactly-once, including cancellation before native task creation.
/// Partial results are never committed as a successful transcript.
private final class VideoSpeechOperation: @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer
    private let request: SFSpeechURLRecognitionRequest
    private let lock = NSLock()
    private var task: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<VideoAudioTranscriptResult, Error>?
    private var outcome: Result<VideoAudioTranscriptResult, Error>?

    init(recognizer: SFSpeechRecognizer, request: SFSpeechURLRecognitionRequest) {
        self.recognizer = recognizer
        self.request = request
    }

    @MainActor
    func run() async throws -> VideoAudioTranscriptResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let outcome { lock.unlock(); continuation.resume(with: outcome); return }
            self.continuation = continuation
            lock.unlock()
            let native = recognizer.recognitionTask(with: request) { [self] result, error in
                switch VideoSpeechPolicy.classify(text: result?.bestTranscription.formattedString,
                                                  isFinal: result?.isFinal ?? false, error: error as NSError?) {
                case .waiting: break
                case .transcript(let text):
                    finish(.success(VideoAudioTranscriptResult(text: text, status: .transcribed)))
                case .noSpeech:
                    finish(.success(VideoAudioTranscriptResult(text: "", status: .noSpeech)))
                case .failed(let failure):
                    finish(.failure(VideoAudioTranscriptionError.recognitionFailed(failure)))
                }
            }
            lock.lock()
            let isFinished = outcome != nil
            if !isFinished { task = native }
            lock.unlock()
            if isFinished { native.cancel() }
        }
    }

    func cancel() { finish(.failure(CancellationError()), cancelNative: true) }

    private func finish(_ result: Result<VideoAudioTranscriptResult, Error>, cancelNative: Bool = false) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        let waiter = continuation
        continuation = nil
        let native = task
        task = nil
        lock.unlock()
        waiter?.resume(with: result)
        if cancelNative { native?.cancel() }
    }
}
