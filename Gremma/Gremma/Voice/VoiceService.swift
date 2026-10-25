import Foundation
import Combine
import UIKit
@preconcurrency import AVFoundation
@preconcurrency import Speech

/// Why a recognition window ended without delivering a completed utterance.
enum VoiceListeningEnd: Sendable {
    case idle
    case retryableFailure(String)
}

/// Offline conversational speech and spoken replies. Listening and speaking are mutually exclusive.
/// `onCommand` fires once per completed recognition result, on the main actor.
@MainActor
final class VoiceService: NSObject, ObservableObject {
    @Published private(set) var transcript = ""
    @Published private(set) var isListening = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var status = "Ready"
    @Published private(set) var error: String?
    @Published private(set) var developerStatus = "Voice has not started. No audio or transcript is saved by voice diagnostics."
    @Published private(set) var diagnostics: VoiceDiagnosticsSnapshot?
    @Published private(set) var lastCompletedDiagnostics: VoiceDiagnosticsSnapshot?

    var onCommand: ((String) -> Void)?
    /// Called only when recognition ends without a command. The controller owns renewal policy.
    /// Explicit cancellation, interruptions, and permission/start errors do not call this.
    var onListeningEnded: ((VoiceListeningEnd) -> Void)?
    /// Called after the current spoken reply completes naturally, on the main actor.
    var onSpeechFinished: (() -> Void)?
    /// Called after an audio interruption, background transition, or device disconnection.
    var onInterruption: (() -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private let audioSession = AVAudioSession.sharedInstance()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionID: UUID?
    private var pendingStartID: UUID?
    private var tapInstalled = false
    private var isFinishingRecognition = false
    private var silenceTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var finishTimeoutTask: Task<Void, Never>?
    private var diagnosticsTask: Task<Void, Never>?
    private var audioMetrics: VoiceAudioMetrics?
    private var windowDiagnostics: VoiceDiagnosticsSnapshot?
    private var lastDiagnosticsWriteAt: Date?
    private let persistDiagnostics = ProcessInfo.processInfo.arguments.contains("--gremma-voice-diagnostics")
    private var activeUtteranceID: ObjectIdentifier?
    private var lastSpokenText = ""
    private var notificationObservers: [NSObjectProtocol] = []

    enum VoiceError: LocalizedError {
        case speechPermissionDenied
        case microphonePermissionDenied
        case offlineRecognitionUnavailable
        case recognizerUnavailable
        case microphoneUnavailable

        var errorDescription: String? {
            switch self {
            case .speechPermissionDenied:
                return "Speech recognition permission is required. You can enable it in Settings."
            case .microphonePermissionDenied:
                return "Microphone permission is required. You can enable it in Settings."
            case .offlineRecognitionUnavailable:
                return "On-device English speech recognition is unavailable. Use the accessible controls; Gremma will not send your voice to a server."
            case .recognizerUnavailable:
                return "Speech recognition is temporarily unavailable. Use the accessible controls or try again."
            case .microphoneUnavailable:
                return "No microphone is available. Check the audio connection and try again."
            }
        }
    }

    override init() {
        super.init()
        synthesizer.delegate = self

        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard rawType == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor [weak self] in
                self?.interruptAudio(message: "Audio interrupted. Tap to start again.")
            }
        })

        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.interruptAudio(message: "Ready")
            }
        })

        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard rawReason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            Task { @MainActor [weak self] in
                self?.interruptAudio(message: "Audio device disconnected. Tap to start again.")
            }
        })
    }

    deinit {
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        silenceTask?.cancel()
        timeoutTask?.cancel()
        finishTimeoutTask?.cancel()
        diagnosticsTask?.cancel()
        recognitionTask?.cancel()
        audioEngine.stop()
        if tapInstalled { audioEngine.inputNode.removeTap(onBus: 0) }
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Requests permissions if needed. Fails closed unless recognition can stay on the phone.
    func startListening() async throws {
        stopSpeaking()
        cancelRecognition()
        error = nil
        transcript = ""
        status = "Checking speech access…"
        let operationID = UUID()
        pendingStartID = operationID
        let now = Date()
        windowDiagnostics = VoiceDiagnosticsSnapshot(windowID: operationID, startedAt: now, updatedAt: now)
        publishDiagnostics()

        do {
            let speechAuthorization = await requestSpeechAuthorization()
            try checkPendingStart(operationID)
            windowDiagnostics?.speechAuthorization = speechAuthorization.rawValue
            guard speechAuthorization == .authorized else { throw VoiceError.speechPermissionDenied }

            let hasMicrophonePermission = await requestMicrophonePermission()
            try checkPendingStart(operationID)
            windowDiagnostics?.microphonePermissionGranted = hasMicrophonePermission
            windowDiagnostics?.supportsOnDeviceRecognition = recognizer?.supportsOnDeviceRecognition
            windowDiagnostics?.recognizerAvailable = recognizer?.isAvailable
            guard hasMicrophonePermission else { throw VoiceError.microphonePermissionDenied }
            guard let recognizer, recognizer.supportsOnDeviceRecognition else {
                throw VoiceError.offlineRecognitionUnavailable
            }
            guard recognizer.isAvailable else { throw VoiceError.recognizerUnavailable }

            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true)

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            windowDiagnostics?.sampleRate = format.sampleRate
            windowDiagnostics?.channelCount = format.channelCount
            windowDiagnostics?.sampleFormat = String(describing: format.commonFormat)
            windowDiagnostics?.isInterleaved = format.isInterleaved
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw VoiceError.microphoneUnavailable
            }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            recognitionRequest = request
            recognitionID = operationID
            pendingStartID = nil
            let metrics = VoiceAudioMetrics()
            audioMetrics = metrics

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, recognitionError in
                // Copy simple values before hopping from Speech's callback queue to the UI actor.
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                let failure = recognitionError?.localizedDescription
                let nativeError = recognitionError as NSError?
                let errorDomain = nativeError?.domain
                let errorCode = nativeError?.code
                Task { @MainActor [weak self] in
                    self?.receiveRecognition(text: text, isFinal: isFinal, failure: failure,
                                             errorDomain: errorDomain, errorCode: errorCode, id: operationID)
                }
            }

            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
                request.append(buffer)
                metrics.record(buffer)
            }
            tapInstalled = true
            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
            status = "Listening on this iPhone…"
            windowDiagnostics?.captureStartedAt = Date()
            windowDiagnostics?.phase = "listening"
            publishDiagnostics()
            startDiagnosticsMonitor(id: operationID)

            // Bound each recognition window. The controller may renew an active foreground session.
            timeoutTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                guard let self, self.recognitionID == operationID else { return }
                if self.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Real samples with no recognized words may simply be a quiet room.
                    // Zero samples is a capture failure, not ordinary idle time.
                    if (self.audioMetrics?.snapshot().frameCount ?? 0) == 0 {
                        self.endListeningWithoutCommand(.retryableFailure(
                            "The microphone started but delivered no audio. Please try again."
                        ), diagnosticReason: "capture_no_frames")
                    } else {
                        self.endListeningWithoutCommand(.idle)
                    }
                } else {
                    self.stopListening()
                }
            }
        } catch {
            // A newer listen/speak operation must not be torn down by an older permission reply.
            guard pendingStartID == operationID || recognitionID == operationID else { throw error }
            if !(error is CancellationError) {
                let nativeError = error as NSError
                windowDiagnostics?.lastErrorDomain = nativeError.domain
                windowDiagnostics?.lastErrorCode = nativeError.code
            }
            pendingStartID = nil
            cancelRecognition(diagnosticReason: error is CancellationError ? "cancelled" : "startup_failed")
            if !(error is CancellationError) {
                self.error = error.localizedDescription
                status = "Voice unavailable"
            }
            throw error
        }
    }

    /// Stops the microphone immediately, then waits briefly for Speech's final result.
    /// Use `cancelListening` to discard a command without delivering it.
    func stopListening() {
        pendingStartID = nil
        guard let id = recognitionID else {
            if !isSpeaking { status = "Ready" }
            return
        }
        guard !isFinishingRecognition else { return }
        isFinishingRecognition = true
        silenceTask?.cancel()
        timeoutTask?.cancel()
        stopMicrophone()
        recognitionRequest?.endAudio()
        status = "Finishing command…"
        windowDiagnostics?.phase = "finishing"
        publishDiagnostics()

        finishTimeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            guard let self, self.recognitionID == id else { return }
            if self.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.endListeningWithoutCommand(.idle)
            } else {
                self.endListeningWithoutCommand(.retryableFailure(
                    "I couldn't finish hearing that. Please try again or use the accessible controls."
                ), diagnosticReason: "final_result_timeout")
            }
        }
    }

    /// Stops recognition and invalidates pending results without dispatching a command.
    func cancelListening() {
        cancelRecognition()
        if !isSpeaking { status = "Ready" }
    }

    func speak(_ text: String) {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return }
        pendingStartID = nil
        cancelRecognition()
        stopSpeaking()
        error = nil
        lastSpokenText = cleanText

        do {
            try audioSession.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try audioSession.setActive(true)
            let utterance = AVSpeechUtterance(string: cleanText)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            activeUtteranceID = ObjectIdentifier(utterance)
            isSpeaking = true
            status = "Speaking…"
            synthesizer.speak(utterance)
        } catch {
            self.error = "Audio playback failed: \(error.localizedDescription)"
            status = "Audio unavailable"
            deactivateAudioSession()
        }
    }

    func stopSpeaking() {
        activeUtteranceID = nil
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        if !isListening && !isFinishingRecognition {
            status = "Ready"
            deactivateAudioSession()
        }
    }

    func repeatLast() {
        guard !lastSpokenText.isEmpty else { return }
        speak(lastSpokenText)
    }

    /// Deleted source evidence must not remain available through the Repeat control.
    func clearSpokenHistory() {
        stopSpeaking()
        lastSpokenText = ""
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { authorization in
                continuation.resume(returning: authorization)
            }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default: return false
        }
    }

    private func checkPendingStart(_ id: UUID) throws {
        try Task.checkCancellation()
        guard pendingStartID == id else { throw CancellationError() }
    }

    private func receiveRecognition(text: String?, isFinal: Bool, failure: String?,
                                    errorDomain: String?, errorCode: Int?, id: UUID) {
        guard recognitionID == id else { return }
        windowDiagnostics?.recognitionCallbackCount += 1
        if isFinal { windowDiagnostics?.finalResultCount += 1 }
        else if let text, !text.isEmpty { windowDiagnostics?.partialResultCount += 1 }
        if let errorDomain {
            windowDiagnostics?.lastErrorDomain = errorDomain
            windowDiagnostics?.lastErrorCode = errorCode
        }
        if let text { transcript = text }

        if isFinal {
            let command = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else {
                endListeningWithoutCommand(.idle)
                return
            }
            cancelRecognition(diagnosticReason: "completed")
            status = "Ready"
            onCommand?(command)
            return
        }

        if let failure {
            endListeningWithoutCommand(.retryableFailure("On-device recognition stopped: \(failure)"))
            return
        }

        guard let text, !text.isEmpty, !isFinishingRecognition else { return }
        // Speech may keep a task open after a short utterance. End its input after a pause,
        // but only dispatch the recognizer's final result, never a partial transcript.
        silenceTask?.cancel()
        silenceTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 1_600_000_000) } catch { return }
            guard self?.recognitionID == id else { return }
            self?.stopListening()
        }
    }

    private func endListeningWithoutCommand(_ reason: VoiceListeningEnd, diagnosticReason: String? = nil) {
        // Invalidate the ID before invoking client code; late Speech callbacks cannot deliver twice.
        guard recognitionID != nil else { return }
        let phase: String
        switch reason {
        case .idle: phase = "idle"
        case .retryableFailure: phase = "recognition_failed"
        }
        cancelRecognition(diagnosticReason: diagnosticReason ?? phase)
        switch reason {
        case .idle:
            error = nil
            status = "No speech heard"
        case .retryableFailure(let message):
            error = message
            status = "Try again"
        }
        onListeningEnded?(reason)
    }

    private func stopMicrophone() {
        if audioEngine.isRunning { audioEngine.stop() }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        isListening = false
    }

    private func cancelRecognition(diagnosticReason: String = "cancelled") {
        recognitionID = nil
        pendingStartID = nil
        silenceTask?.cancel()
        silenceTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        stopMicrophone()
        if windowDiagnostics?.endedAt == nil {
            windowDiagnostics?.phase = diagnosticReason
            windowDiagnostics?.endedAt = Date()
            publishDiagnostics(forcePersist: true)
        }
        audioMetrics = nil
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        isFinishingRecognition = false
        if !isSpeaking { deactivateAudioSession() }
    }

    private func deactivateAudioSession() {
        try? audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func interruptAudio(message: String) {
        pendingStartID = nil
        cancelRecognition(diagnosticReason: "interrupted")
        stopSpeaking()
        status = message
        onInterruption?()
    }

    private func startDiagnosticsMonitor(id: UUID) {
        diagnosticsTask?.cancel()
        diagnosticsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self, self.recognitionID == id else { return }
                self.publishDiagnostics()
                guard !self.isFinishingRecognition,
                      let snapshot = self.diagnostics,
                      let captureStartedAt = snapshot.captureStartedAt,
                      Date().timeIntervalSince(captureStartedAt) >= 3,
                      snapshot.frameCount == 0 else { continue }
                self.endListeningWithoutCommand(.retryableFailure(
                    "The microphone started but delivered no audio. Please try again."
                ), diagnosticReason: "capture_no_frames")
                return
            }
        }
    }

    private func publishDiagnostics(forcePersist: Bool = false) {
        guard var snapshot = windowDiagnostics else { return }
        let now = Date()
        snapshot.updatedAt = now
        snapshot.engineRunning = audioEngine.isRunning
        snapshot.recognitionTaskState = recognitionTask?.state.rawValue
        snapshot.transcriptCharacterCount = transcript.count
        snapshot.recognizerAvailable = recognizer?.isAvailable
        snapshot.inputPortTypes = audioSession.currentRoute.inputs.map { $0.portType.rawValue }
        snapshot.outputPortTypes = audioSession.currentRoute.outputs.map { $0.portType.rawValue }
        if let metrics = audioMetrics?.snapshot() {
            snapshot.bufferCount = metrics.bufferCount
            snapshot.frameCount = metrics.frameCount
            snapshot.firstBufferAt = metrics.firstBufferAt
            snapshot.lastBufferAt = metrics.lastBufferAt
            snapshot.latestRMS = metrics.latestRMS
            snapshot.maximumPeak = metrics.maximumPeak
        }
        windowDiagnostics = snapshot
        diagnostics = snapshot
        if snapshot.endedAt != nil { lastCompletedDiagnostics = snapshot }
        developerStatus = snapshot.summary
        if let previous = lastCompletedDiagnostics, previous.windowID != snapshot.windowID {
            developerStatus += "\nPrevious window: \(previous.phase) · callbacks \(previous.recognitionCallbackCount) · transcript characters \(previous.transcriptCharacterCount)"
        }
        guard persistDiagnostics,
              forcePersist || lastDiagnosticsWriteAt.map({ now.timeIntervalSince($0) >= 1 }) != false else { return }
        lastDiagnosticsWriteAt = now
        do {
            guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            let directory = documents.appendingPathComponent("Diagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var url = directory.appendingPathComponent("voice-latest.json")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let report = VoiceDiagnosticsReport(current: snapshot, lastCompleted: lastCompletedDiagnostics)
            try encoder.encode(report).write(to: url, options: .atomic)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            // The optional diagnostic file must never interfere with microphone operation.
            developerStatus += "\nDiagnostic file could not be saved."
        }
    }

    private func finishedSpeaking(id: ObjectIdentifier, naturally: Bool) {
        guard activeUtteranceID == id else { return }
        activeUtteranceID = nil
        isSpeaking = false
        status = "Ready"
        if !isListening { deactivateAudioSession() }
        if naturally { onSpeechFinished?() }
    }
}

extension VoiceService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finishedSpeaking(id: id, naturally: true) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finishedSpeaking(id: id, naturally: false) }
    }
}
