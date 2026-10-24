import Accelerate
import Foundation
@preconcurrency import AVFoundation

/// Metadata only: never includes audio samples, recognized words, or route/device names.
struct VoiceDiagnosticsSnapshot: Codable, Sendable {
    let windowID: UUID
    let startedAt: Date
    var updatedAt: Date
    var endedAt: Date?
    var captureStartedAt: Date?
    var phase = "checking_access"
    var localeIdentifier = "en-US"
    var speechAuthorization: Int?
    var microphonePermissionGranted: Bool?
    var supportsOnDeviceRecognition: Bool?
    var recognizerAvailable: Bool?
    var inputPortTypes: [String] = []
    var outputPortTypes: [String] = []
    var sampleRate: Double?
    var channelCount: UInt32?
    var sampleFormat: String?
    var isInterleaved: Bool?
    var engineRunning = false
    var recognitionTaskState: Int?
    var bufferCount: UInt64 = 0
    var frameCount: UInt64 = 0
    var firstBufferAt: Date?
    var lastBufferAt: Date?
    /// Normalized channel-zero levels; a level is not a speech detector.
    var latestRMS: Double?
    var maximumPeak: Double?
    var recognitionCallbackCount = 0
    var partialResultCount = 0
    var finalResultCount = 0
    var transcriptCharacterCount = 0
    var lastErrorDomain: String?
    var lastErrorCode: Int?

    var summary: String {
        let route = inputPortTypes.isEmpty ? "none" : inputPortTypes.joined(separator: ", ")
        let format = sampleRate.map { "\(Int($0)) Hz / \(channelCount ?? 0) ch / \(sampleFormat ?? "unknown")" } ?? "not configured"
        let rms = latestRMS.map { String(format: "%.5f", $0) } ?? "—"
        let peak = maximumPeak.map { String(format: "%.5f", $0) } ?? "—"
        let nativeError = lastErrorDomain.map { "\($0) / \(lastErrorCode ?? 0)" } ?? "none"
        return """
        Window \(windowID.uuidString.prefix(8)) · \(phase)
        Input: \(route) · \(format)
        Engine: \(engineRunning ? "running" : "stopped") · buffers \(bufferCount) · frames \(frameCount)
        Channel 0 RMS \(rms) · peak \(peak)
        Speech callbacks \(recognitionCallbackCount) · partials \(partialResultCount) · finals \(finalResultCount)
        Transcript characters: \(transcriptCharacterCount) · native error: \(nativeError)
        Offline supported: \(supportsOnDeviceRecognition.map(String.init) ?? "unknown") · available: \(recognizerAvailable.map(String.init) ?? "unknown")
        """
    }
}

/// Bounded to two metadata snapshots so automatic listening renewal does not erase the last result.
struct VoiceDiagnosticsReport: Codable, Sendable {
    var schemaVersion = 1
    let current: VoiceDiagnosticsSnapshot
    let lastCompleted: VoiceDiagnosticsSnapshot?
}

/// One accumulator per window. The audio tap keeps only scalar statistics and never stores a buffer.
/// The lock protects a few scalar assignments; UI/file work stays outside the real-time callback.
final class VoiceAudioMetrics: @unchecked Sendable {
    struct Snapshot: Sendable {
        var bufferCount: UInt64 = 0
        var frameCount: UInt64 = 0
        var firstBufferAt: Date?
        var lastBufferAt: Date?
        var latestRMS: Double?
        var maximumPeak: Double?
    }

    private let lock = NSLock()
    private var values = Snapshot()

    func record(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        var rms: Float?
        var peak: Float?
        if frames > 0, let channel = buffer.floatChannelData?[0] {
            let stride = vDSP_Stride(buffer.format.isInterleaved ? buffer.format.channelCount : 1)
            var measuredRMS: Float = 0
            var measuredPeak: Float = 0
            vDSP_rmsqv(channel, stride, &measuredRMS, vDSP_Length(frames))
            vDSP_maxmgv(channel, stride, &measuredPeak, vDSP_Length(frames))
            if measuredRMS.isFinite { rms = measuredRMS }
            if measuredPeak.isFinite { peak = measuredPeak }
        }
        let now = Date()
        lock.lock()
        values.bufferCount += 1
        values.frameCount += UInt64(frames)
        if frames > 0 {
            if values.firstBufferAt == nil { values.firstBufferAt = now }
            values.lastBufferAt = now
        }
        values.latestRMS = rms.map(Double.init)
        if let peak { values.maximumPeak = max(values.maximumPeak ?? 0, Double(peak)) }
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
