import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import Vision

/// Image-normalized coordinates with Vision's bottom-left origin. This is an
/// attention suggestion, never evidence of an object identity or an action.
struct VideoAttentionCropPlan: Sendable {
    let normalizedRect: CGRect
    let sourceFrameIndex: Int
    let poseConfidence: Float
    let score: Double
    /// Original pose anchor/scale survive context-crop edge clamping. They are
    /// optional so an arbitrary rectangle cannot invent a refined wrist crop.
    let normalizedWrist: CGPoint?
    let sourceImageSize: CGSize?
    let torsoLengthPixels: Double?

    init(normalizedRect: CGRect, sourceFrameIndex: Int, poseConfidence: Float, score: Double,
         normalizedWrist: CGPoint? = nil, sourceImageSize: CGSize? = nil, torsoLengthPixels: Double? = nil) {
        self.normalizedRect = normalizedRect; self.sourceFrameIndex = sourceFrameIndex
        self.poseConfidence = poseConfidence; self.score = score
        self.normalizedWrist = normalizedWrist; self.sourceImageSize = sourceImageSize
        self.torsoLengthPixels = torsoLengthPixels
    }
}

/// Chooses one spatial region for the entire chronological sequence. A fixed
/// crop preserves before/after context instead of following a hand as it moves.
/// Works best when the camera stays approximately still during the short window.
enum VideoAttentionCrop {
    struct Arm: Sendable {
        let shoulder: CGPoint
        let elbow: CGPoint
        let wrist: CGPoint
        let hip: CGPoint
        let confidence: Float
    }

    static func plan(for imageURLs: [URL]) async throws -> VideoAttentionCropPlan? {
        let worker = Task.detached(priority: .userInitiated) { () throws -> VideoAttentionCropPlan? in
            var best: VideoAttentionCropPlan?
            var initialAspect: Double?
            for (index, url) in imageURLs.prefix(8).enumerated() {
                try Task.checkCancellation()
                guard let image = image(at: url) else { continue }
                let size = CGSize(width: image.width, height: image.height)
                let aspect = Double(image.width) / Double(image.height)
                if let initialAspect, abs(aspect / initialAspect - 1) > 0.03 { return nil }
                initialAspect = initialAspect ?? aspect
                let request = VNDetectHumanBodyPoseRequest()
                do { try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request]) }
                catch { try Task.checkCancellation(); continue }
                try Task.checkCancellation()
                for observation in request.results ?? [] {
                    for side in [true, false] {
                        guard let arm = arm(from: observation, left: side),
                              let candidate = candidate(for: arm, imageSize: size, frameIndex: index) else { continue }
                        if best == nil || candidate.score > best!.score { best = candidate }
                    }
                }
            }
            return best
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    /// Optional closer inspection of the same wrist region. This does not change
    /// the normal context plan or establish an object's identity. Keep this one
    /// fixed rectangle for every before/contact/after frame in the sequence.
    static func detailPlan(from context: VideoAttentionCropPlan) -> VideoAttentionCropPlan? {
        guard let wrist = context.normalizedWrist, let size = context.sourceImageSize,
              let torso = context.torsoLengthPixels,
              wrist.x.isFinite, wrist.y.isFinite, (0...1).contains(wrist.x), (0...1).contains(wrist.y),
              size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              torso.isFinite, torso > 0 else { return nil }
        let shorter = min(size.width, size.height)
        let side = min(shorter * 0.55, max(shorter * 0.22, torso * 0.75))
        guard side >= 80 else { return nil }
        let width = side / size.width, height = side / size.height
        let centerY = wrist.y - 0.10 * torso / size.height
        let rectangle = CGRect(x: max(0, min(1 - width, wrist.x - width / 2)),
                               y: max(0, min(1 - height, centerY - height / 2)), width: width, height: height)
        return VideoAttentionCropPlan(normalizedRect: rectangle, sourceFrameIndex: context.sourceFrameIndex,
            poseConfidence: context.poseConfidence, score: context.score, normalizedWrist: wrist,
            sourceImageSize: size, torsoLengthPixels: torso)
    }

    /// Apply the same plan to every frame, including before and after the reach.
    /// Original frame files are never modified.
    static func jpeg(at url: URL, using plan: VideoAttentionCropPlan) throws -> Data {
        try Task.checkCancellation()
        guard let image = image(at: url) else { throw CropError.unreadableImage }
        let normalized = plan.normalizedRect
        guard normalized.width > 0, normalized.height > 0,
              normalized.minX >= 0, normalized.minY >= 0,
              normalized.maxX <= 1.00001, normalized.maxY <= 1.00001 else { throw CropError.invalidRegion }
        // CGImage crop pixels start at the top-left; Vision starts bottom-left.
        let pixels = CGRect(x: normalized.minX * Double(image.width),
                            y: (1 - normalized.maxY) * Double(image.height),
                            width: normalized.width * Double(image.width),
                            height: normalized.height * Double(image.height)).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard pixels.width >= 80, pixels.height >= 80,
              let cropped = image.cropping(to: pixels) else { throw CropError.invalidRegion }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CropError.encodingFailed
        }
        CGImageDestinationAddImage(destination, cropped, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CropError.encodingFailed }
        return data as Data
    }

    /// Pure geometry used by controlled tests. Normalized body joints alone are
    /// not enough to conclude that an object is being held or placed.
    static func candidate(for arm: Arm, imageSize: CGSize, frameIndex: Int) -> VideoAttentionCropPlan? {
        guard arm.confidence.isFinite, (0.25...1).contains(arm.confidence),
              imageSize.width.isFinite, imageSize.height.isFinite, imageSize.width > 0, imageSize.height > 0,
              [arm.shoulder, arm.elbow, arm.wrist, arm.hip].allSatisfy({
                  $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y)
              }) else { return nil }
        func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
            hypot((a.x - b.x) * imageSize.width, (a.y - b.y) * imageSize.height)
        }
        let torso = distance(arm.shoulder, arm.hip)
        guard torso >= min(imageSize.width, imageSize.height) * 0.12 else { return nil }
        let elevation = (arm.wrist.y - arm.hip.y) * imageSize.height / torso
        let reach = abs(arm.wrist.x - arm.shoulder.x) * imageSize.width / torso
        let path = distance(arm.shoulder, arm.elbow) + distance(arm.elbow, arm.wrist)
        guard path > 0 else { return nil }
        let extensionRatio = distance(arm.shoulder, arm.wrist) / path
        // Ignore hanging walking arms. A bent elevated hand can still matter
        // (e.g. interacting with an object near the torso).
        let elevated = elevation >= 0.20
        let sideways = reach >= 0.45 && elevation >= -0.08 && extensionRatio >= 0.65
        guard elevated || sideways else { return nil }
        let shorter = min(imageSize.width, imageSize.height)
        let side = min(shorter * 0.85, max(shorter * 0.40, torso * 1.30))
        let width = side / imageSize.width, height = side / imageSize.height
        let centerY = arm.wrist.y - 0.10 * torso / imageSize.height
        let rectangle = CGRect(x: max(0, min(1 - width, arm.wrist.x - width / 2)),
                               y: max(0, min(1 - height, centerY - height / 2)),
                               width: width, height: height)
        let score = Double(arm.confidence) * (0.60 * min(2, reach) + 0.35 * max(0, min(1.5, elevation)) + 0.15 * extensionRatio)
        return VideoAttentionCropPlan(normalizedRect: rectangle, sourceFrameIndex: frameIndex,
            poseConfidence: arm.confidence, score: score, normalizedWrist: arm.wrist,
            sourceImageSize: imageSize, torsoLengthPixels: torso)
    }

    private static func arm(from observation: VNHumanBodyPoseObservation, left: Bool) -> Arm? {
        let joints: [VNHumanBodyPoseObservation.JointName] = left
            ? [.leftShoulder, .leftElbow, .leftWrist, .leftHip]
            : [.rightShoulder, .rightElbow, .rightWrist, .rightHip]
        let points = joints.compactMap { try? observation.recognizedPoint($0) }
        guard points.count == 4, let confidence = points.map(\.confidence).min() else { return nil }
        return Arm(shoulder: points[0].location, elbow: points[1].location, wrist: points[2].location,
                   hip: points[3].location, confidence: confidence)
    }

    /// Normalize EXIF orientation before both pose detection and pixel cropping.
    private static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600
        ] as CFDictionary)
    }

    enum CropError: Error { case unreadableImage, invalidRegion, encodingFailed }
}
