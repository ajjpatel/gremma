import AVFoundation
import SwiftUI
import UIKit

/// Observable hardware state for the conversation's developer panel.
/// The camera pipeline owns the session; this object never starts a camera.
@MainActor
final class CameraActivityState: ObservableObject {
    static let shared = CameraActivityState()
    @Published private(set) var isRunning = false
    @Published private(set) var isMicrophoneRunning = false

    fileprivate func update(isRunning: Bool) {
        self.isRunning = isRunning
        isMicrophoneRunning = false
    }
}

/// A live preview with an explicit, cancellable capture countdown.
/// The media library continues to use MediaPicker.
@MainActor
struct AccessibleCameraView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera: AccessibleCameraModel

    init(recordVideo: Bool, onImage: @escaping (UIImage) -> Void,
         onVideo: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
        _camera = StateObject(wrappedValue: AccessibleCameraModel(recordVideo: recordVideo,
            onImage: onImage, onVideo: onVideo, onCancel: onCancel))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: camera.session).ignoresSafeArea().accessibilityHidden(true)
            LinearGradient(colors: [.black.opacity(0.7), .clear, .black.opacity(0.85)],
                startPoint: .top, endPoint: .bottom).ignoresSafeArea().allowsHitTesting(false)
            VStack(spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(camera.recordVideo ? "Record an activity" : "Capture an image")
                            .font(.title2.bold()).accessibilityAddTraits(.isHeader)
                        Label(camera.isCameraRunning ? "Camera on · live preview" : "Camera off",
                              systemImage: camera.isCameraRunning ? "camera.fill" : "camera")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(camera.isCameraRunning ? Color.green : .white.opacity(0.8))
                        if camera.recordVideo && camera.isCameraRunning {
                            Label("Video only · microphone off", systemImage: "mic.slash")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    Spacer()
                    Button("Cancel", action: camera.cancel)
                        .font(.headline).padding(.horizontal, 20).frame(minHeight: 52)
                        .background(.black.opacity(0.6), in: Capsule())
                        .accessibilityHint("Closes the camera without saving a capture")
                }
                Spacer()
                if let count = camera.countdown {
                    Text("\(count)").font(.system(size: 100, weight: .bold, design: .rounded))
                        .accessibilityLabel(camera.isRecording ? "\(count) seconds remaining" : "Capturing in \(count) seconds")
                }
                Spacer()
                VStack(spacing: 18) {
                    Text(camera.status).font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    if let error = camera.error {
                        Text(error).font(.body).multilineTextAlignment(.center).foregroundStyle(.orange)
                        Button("Try camera again", action: camera.retry)
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 60)
                            .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 18))
                    } else if camera.isRecording {
                        Button(action: camera.stopRecording) {
                            Label("Stop recording", systemImage: "stop.fill")
                                .font(.title2.bold()).frame(maxWidth: .infinity, minHeight: 76)
                        }.background(.red, in: RoundedRectangle(cornerRadius: 22))
                    } else if camera.canCapture {
                        Button(action: camera.toggleCaptureCountdown) {
                            Label(camera.isCountingDown ? "Cancel countdown" : (camera.recordVideo ? "Start recording" : "Capture image"),
                                  systemImage: camera.isCountingDown ? "pause.fill" : (camera.recordVideo ? "record.circle" : "camera.fill"))
                                .font(.title2.bold()).frame(maxWidth: .infinity, minHeight: 100)
                        }.foregroundStyle(.black)
                            .background(Color(red: 0.56, green: 0.91, blue: 0.81), in: RoundedRectangle(cornerRadius: 22))
                            .accessibilityHint(camera.isCountingDown
                                ? "Stops the countdown and keeps the camera open until you are ready"
                                : "Starts a spoken three, two, one countdown. Activate this button again to cancel.")
                    } else {
                        ProgressView().tint(.white).accessibilityLabel(camera.status)
                    }
                }.padding(22).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 24))
            }.padding(24)
        }.foregroundStyle(.white)
            .onAppear { camera.start() }
            .onDisappear { camera.disappear() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { camera.cancel() }
            }
            .interactiveDismissDisabled()
    }
}

private final class PreviewSurface: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewSurface {
        let view = PreviewSurface()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = session
        if let connection = view.previewLayer.connection,
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        return view
    }

    func updateUIView(_ view: PreviewSurface, context: Context) {
        if let connection = view.previewLayer.connection,
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }

    static func dismantleUIView(_ view: PreviewSurface, coordinator: ()) {
        view.previewLayer.session = nil
    }
}

@MainActor
private final class AccessibleCameraModel: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    let recordVideo: Bool
    @Published private(set) var status = "Preparing the camera…"
    @Published private(set) var error: String?
    @Published private(set) var countdown: Int?
    @Published private(set) var isRecording = false
    @Published private(set) var isCountingDown = false
    @Published private(set) var canCapture = false
    @Published private(set) var isCameraRunning = false
    var session: AVCaptureSession { pipeline.session }

    private let onImage: (UIImage) -> Void
    private let onVideo: (URL) -> Void
    private let onCancel: () -> Void
    private let speech = AVSpeechSynthesizer()
    private var captureUtterance: AVSpeechUtterance?
    private var nextCountdownNumber = 3
    private var recordingTimer: Task<Void, Never>?
    private var countdownWatchdog: Task<Void, Never>?
    private var started = false
    private var finished = false
    private var deliveredVideoURL: URL?
    private var ownsAudioSession = false
    private var previousAudio: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?
    private lazy var pipeline = CameraCapturePipeline(recordVideo: recordVideo) { [weak self] event in
        Task { @MainActor [weak self] in self?.receive(event) }
    }

    init(recordVideo: Bool, onImage: @escaping (UIImage) -> Void,
         onVideo: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
        self.recordVideo = recordVideo
        self.onImage = onImage
        self.onVideo = onVideo
        self.onCancel = onCancel
        super.init()
        speech.delegate = self
    }

    func start() {
        guard !started, !finished else { return }
        started = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: pipeline.start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self, !self.finished else { return }
                    if granted { self.pipeline.start() }
                    else { self.fail("Allow camera access in Settings to capture an activity.") }
                }
            }
        default: fail("Camera access is unavailable. Enable Camera for Gremma in Settings.")
        }
    }

    func retry() {
        guard !finished else { return }
        error = nil
        status = "Preparing the camera…"
        started = false
        start()
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        status = "Stopping the camera…"
        cleanup { [self] in onCancel() }
    }

    func disappear() {
        finished = true
        cleanup()
    }

    func toggleCaptureCountdown() {
        guard canCapture, !finished else { return }
        if isCountingDown {
            cancelCountdown()
        } else {
            beginCountdown()
        }
    }

    private func captureNow() {
        guard canCapture, isCountingDown, !finished else { return }
        clearCountdown()
        canCapture = false
        status = recordVideo ? "Starting recording…" : "Taking your photo…"
        pipeline.capture()
    }

    func stopRecording() {
        guard isRecording, !finished else { return }
        isRecording = false
        countdown = nil
        recordingTimer?.cancel()
        recordingTimer = nil
        status = "Preparing your video…"
        pipeline.stopRecording()
    }

    private func receive(_ event: CameraCaptureEvent) {
        if case .running = event {
            // Read the current value when the main actor handles this notification,
            // so a delayed start notification cannot overwrite a completed stop.
            let running = session.isRunning
            isCameraRunning = running
            CameraActivityState.shared.update(isRunning: running)
            return
        }
        guard !finished else {
            if case .video(let url) = event, url != deliveredVideoURL {
                try? FileManager.default.removeItem(at: url)
            }
            return
        }
        switch event {
        case .running: break
        case .ready:
            canCapture = true
            status = readyStatus
            prepareSpeech()
            let message = recordVideo
                ? "Camera ready. Point at the activity. Tap Start recording when ready. Tap again during the countdown to cancel. Recording lasts up to one minute."
                : "Camera ready. Point at what you want to capture. Tap the large Capture image button when ready. Tap it again during the countdown to cancel."
            speech.speak(makeUtterance(message))
        case .recording:
            isRecording = true
            status = "Recording the activity. Keep the action in view."
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            recordingTimer = Task { [weak self] in
                for remaining in stride(from: 60, through: 1, by: -1) {
                    guard !Task.isCancelled, let self, !self.finished, self.isRecording else { return }
                    self.countdown = remaining
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
                self?.stopRecording()
            }
        case .processing:
            isRecording = false
            recordingTimer?.cancel()
            recordingTimer = nil
            countdown = nil
            status = "Preparing your video…"
        case .photo(let data):
            guard let image = UIImage(data: data) else {
                fail("The camera image could not be decoded. Please try again.")
                return
            }
            finished = true
            cleanup { [self] in onImage(image) }
        case .video(let url):
            // Transfer ownership before dismissal; the receiver may still be copying
            // this file after onDisappear stops the camera session.
            deliveredVideoURL = url
            finished = true
            cleanup { [self] in onVideo(url) }
        case .failure(let message): fail(message)
        }
    }

    private func beginCountdown() {
        guard canCapture, !finished, !isCountingDown else { return }
        speech.stopSpeaking(at: .immediate)
        isCountingDown = true
        nextCountdownNumber = 3
        status = "Countdown starting. Tap the large button again to cancel."
        speakCountdownStep(recordVideo ? "Starting recording in" : "Capturing image in")
    }

    private var readyStatus: String {
        "Point at \(recordVideo ? "the activity" : "the item"). Tap the large button when ready."
    }

    private func clearCountdown() {
        // Clear identity before stopping speech so delayed finish/cancel callbacks
        // from a previous countdown can never capture or advance a new countdown.
        captureUtterance = nil
        countdownWatchdog?.cancel()
        countdownWatchdog = nil
        isCountingDown = false
        countdown = nil
        speech.stopSpeaking(at: .immediate)
    }

    private func cancelCountdown(message: String = "Countdown cancelled. Tap the large button when you are ready.") {
        guard isCountingDown, !finished else { return }
        clearCountdown()
        status = readyStatus
        speech.speak(makeUtterance(message))
    }

    private func speakCountdownStep(_ text: String) {
        guard canCapture, isCountingDown, !finished else { return }
        let utterance = makeUtterance(text)
        utterance.postUtteranceDelay = 0.35
        captureUtterance = utterance
        speech.speak(utterance)
        countdownWatchdog?.cancel()
        countdownWatchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, !Task.isCancelled, self.captureUtterance === utterance else { return }
            // If TTS stalls, return to readiness instead of taking an unannounced photo.
            self.cancelCountdown(message: "The countdown was interrupted. Tap the large button to try again.")
        }
    }

    private func advanceCountdown(after identifier: ObjectIdentifier) {
        guard canCapture, isCountingDown, !finished,
              let utterance = captureUtterance, ObjectIdentifier(utterance) == identifier else { return }
        captureUtterance = nil
        countdownWatchdog?.cancel()
        countdownWatchdog = nil
        if nextCountdownNumber > 0 {
            let remaining = nextCountdownNumber
            nextCountdownNumber -= 1
            countdown = remaining
            status = "\(recordVideo ? "Recording" : "Capturing image") in \(remaining). Tap again to cancel."
            speakCountdownStep(String(remaining))
        } else {
            captureNow()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let identifier = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            self?.advanceCountdown(after: identifier)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let identifier = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, let current = self.captureUtterance, ObjectIdentifier(current) == identifier else { return }
            self.cancelCountdown(message: "The countdown was interrupted. Tap the large button to try again.")
        }
    }

    private func makeUtterance(_ text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        return utterance
    }

    private func prepareSpeech() {
        guard !ownsAudioSession else { return }
        let audio = AVAudioSession.sharedInstance()
        previousAudio = (audio.category, audio.mode, audio.categoryOptions)
        do {
            try audio.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
            try audio.setActive(true)
            ownsAudioSession = true
        } catch { status += " Spoken instructions are unavailable." }
    }

    private func fail(_ message: String) {
        canCapture = false
        isRecording = false
        recordingTimer?.cancel()
        recordingTimer = nil
        clearCountdown()
        pipeline.stop()
        error = message
        status = "Camera needs attention"
        prepareSpeech()
        speech.speak(makeUtterance(message))
    }

    private func cleanup(onStopped: (@MainActor @Sendable () -> Void)? = nil) {
        canCapture = false
        isRecording = false
        recordingTimer?.cancel()
        recordingTimer = nil
        clearCountdown()
        // Keep the capture view visible until stopRunning has returned. The controller
        // may start a spoken reply or a new listening window in the callback.
        pipeline.stop { [self] in
            Task { @MainActor [self] in
                self.isCameraRunning = false
                CameraActivityState.shared.update(isRunning: false)
                self.restoreAudioSession()
                onStopped?()
            }
        }
    }

    private func restoreAudioSession() {
        if previousAudio != nil {
            let audio = AVAudioSession.sharedInstance()
            if ownsAudioSession { try? audio.setActive(false, options: .notifyOthersOnDeactivation) }
            if let previousAudio {
                try? audio.setCategory(previousAudio.0, mode: previousAudio.1, options: previousAudio.2)
            }
            ownsAudioSession = false
            previousAudio = nil
        }
    }
}

private enum CameraCaptureEvent: Sendable {
    case running(Bool)
    case ready
    case recording
    case processing
    case photo(Data)
    case video(URL)
    case failure(String)
}

/// Every session mutation and capture state transition occurs on `queue`.
/// Preview-layer attachment is the sole main-thread use of the session reference.
private final class CameraCapturePipeline: NSObject, @unchecked Sendable,
    AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.gremma.camera", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let recordVideo: Bool
    private let event: @Sendable (CameraCaptureEvent) -> Void
    private var configured = false
    private var cancelled = false
    private var captureStarted = false
    private var completed = false
    private var movieURL: URL?
    private var exportSession: AVAssetExportSession?
    private var exportGeneration: UUID?
    private var runningObservation: NSKeyValueObservation?

    init(recordVideo: Bool, event: @escaping @Sendable (CameraCaptureEvent) -> Void) {
        self.recordVideo = recordVideo
        self.event = event
        super.init()
        runningObservation = session.observe(\.isRunning, options: [.initial, .new]) { [weak self] session, _ in
            self?.event(.running(session.isRunning))
        }
    }

    func start() {
        queue.async {
            self.exportGeneration = nil
            self.exportSession?.cancelExport()
            self.exportSession = nil
            self.cancelled = false
            self.captureStarted = false
            self.completed = false
            do {
                if !self.configured { try self.configure() }
                if !self.session.isRunning { self.session.startRunning() }
                guard self.session.isRunning else { throw CameraFailure("The camera could not start. Try again.") }
                self.event(.ready)
            } catch { self.finishWithError(error.localizedDescription) }
        }
    }

    private func configure() throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraFailure("A back camera is not available on this device.")
        }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer {
            if !configured {
                session.inputs.forEach(session.removeInput)
                session.outputs.forEach(session.removeOutput)
            }
            session.commitConfiguration()
        }
        // Playback supports the spoken countdown; the capture session has no audio input.
        session.automaticallyConfiguresApplicationAudioSession = false
        session.sessionPreset = recordVideo ? .hd1280x720 : .photo
        guard session.canAddInput(input) else { throw CameraFailure("Gremma cannot access the back camera right now.") }
        session.addInput(input)
        let output: AVCaptureOutput = recordVideo ? movieOutput : photoOutput
        guard session.canAddOutput(output) else {
            session.removeInput(input)
            throw CameraFailure("The camera does not support this capture mode.")
        }
        session.addOutput(output)
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        if recordVideo {
            movieOutput.maxRecordedDuration = CMTime(seconds: 60, preferredTimescale: 600)
            if let connection = movieOutput.connection(with: .video), movieOutput.availableVideoCodecTypes.contains(.h264) {
                movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.h264], for: connection)
            }
        }
        configured = true
    }

    func capture() {
        queue.async {
            guard !self.cancelled, !self.captureStarted, self.session.isRunning else { return }
            self.captureStarted = true
            if self.recordVideo {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("gremma-camera-\(UUID().uuidString).mov")
                self.movieURL = url
                self.movieOutput.startRecording(to: url, recordingDelegate: self)
            } else {
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    func stopRecording() {
        queue.async {
            if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
        }
    }

    func stop(completion: (@Sendable () -> Void)? = nil) {
        queue.async {
            self.cancelled = true
            self.exportGeneration = nil
            self.exportSession?.cancelExport()
            if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
            if self.session.isRunning { self.session.stopRunning() }
            completion?()
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        let failure = error?.localizedDescription
        queue.async {
            guard !self.cancelled, !self.completed else { return }
            if let failure { self.finishWithError(failure); return }
            guard let data else { self.finishWithError("The camera did not return a photo. Please try again."); return }
            self.completed = true
            if self.session.isRunning { self.session.stopRunning() }
            self.event(.photo(data))
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        queue.async {
            guard !self.cancelled else {
                if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
                return
            }
            self.event(.recording)
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        let nsError = error as NSError?
        let recordingSucceeded = nsError == nil || (nsError?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true)
        let failure = nsError?.localizedDescription
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
            guard !self.cancelled, !self.completed else {
                try? FileManager.default.removeItem(at: outputFileURL)
                return
            }
            guard recordingSucceeded else {
                try? FileManager.default.removeItem(at: outputFileURL)
                self.finishWithError(failure ?? "The video recording could not be saved.")
                return
            }
            self.event(.processing)
            self.exportMovie(outputFileURL)
        }
    }

    private func exportMovie(_ source: URL) {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("gremma-camera-\(UUID().uuidString).mp4")
        guard let exporter = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetPassthrough) else {
            try? FileManager.default.removeItem(at: source)
            finishWithError("This recording could not be prepared as an MP4 video.")
            return
        }
        exportSession = exporter
        let generation = UUID()
        exportGeneration = generation
        queue.asyncAfter(deadline: .now() + 45) {
            guard self.exportGeneration == generation, !self.cancelled, !self.completed else { return }
            self.exportGeneration = nil
            self.exportSession = nil
            exporter.cancelExport()
            self.finishWithError("Preparing this recording took too long. You can close the camera or try again.")
        }
        Task {
            do {
                try await exporter.export(to: destination, as: .mp4)
                self.queue.async {
                    try? FileManager.default.removeItem(at: source)
                    guard self.exportGeneration == generation, !self.cancelled, !self.completed else {
                        try? FileManager.default.removeItem(at: destination)
                        return
                    }
                    self.exportGeneration = nil
                    self.exportSession = nil
                    self.completed = true
                    self.event(.video(destination))
                }
            } catch {
                let message = error.localizedDescription
                self.queue.async {
                    try? FileManager.default.removeItem(at: source)
                    try? FileManager.default.removeItem(at: destination)
                    guard self.exportGeneration == generation else { return }
                    self.exportGeneration = nil
                    self.exportSession = nil
                    if !self.cancelled { self.finishWithError(message) }
                }
            }
        }
    }

    private func finishWithError(_ message: String) {
        guard !cancelled, !completed else { return }
        completed = true
        event(.failure(message))
    }
}

private struct CameraFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
