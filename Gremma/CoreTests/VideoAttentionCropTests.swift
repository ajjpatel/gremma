import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import TemporalVideoCore

final class VideoAttentionCropTests: XCTestCase {
    private let portrait = CGSize(width: 640, height: 960)
    private func arm(wrist: CGPoint = CGPoint(x: 0.85, y: 0.55), confidence: Float = 0.9) -> VideoAttentionCrop.Arm {
        .init(shoulder: CGPoint(x: 0.5, y: 0.7), elbow: CGPoint(x: 0.65, y: 0.60),
              wrist: wrist, hip: CGPoint(x: 0.5, y: 0.35), confidence: confidence)
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AttentionCrop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testLowHangingArmIsRejectedEvenWhenConfident() throws {
        let low = VideoAttentionCrop.Arm(shoulder: CGPoint(x: 0.5, y: 0.7), elbow: CGPoint(x: 0.52, y: 0.48),
            wrist: CGPoint(x: 0.54, y: 0.20), hip: CGPoint(x: 0.5, y: 0.35), confidence: 0.99)
        XCTAssertNil(VideoAttentionCrop.candidate(for: low, imageSize: portrait, frameIndex: 0))
        XCTAssertNotNil(VideoAttentionCrop.candidate(for: arm(confidence: 0.7), imageSize: portrait, frameIndex: 1))
    }
    func testWeakOrNonfinitePoseCannotProposeCrop() throws {
        for confidence: Float in [0, 0.1, .nan, .infinity, 1.5] {
            XCTAssertNil(VideoAttentionCrop.candidate(for: arm(confidence: confidence), imageSize: portrait, frameIndex: 0))
        }
        for wrist in [CGPoint(x: 1.2, y: 0.55), CGPoint(x: CGFloat.nan, y: 0.55), CGPoint(x: 0.5, y: -0.1)] {
            XCTAssertNil(VideoAttentionCrop.candidate(for: arm(wrist: wrist), imageSize: portrait, frameIndex: 0))
        }
    }
    func testInvalidImageOrCollapsedTorsoCannotProposeCrop() throws {
        for size in [CGSize.zero, CGSize(width: -100, height: 960), CGSize(width: CGFloat.infinity, height: 960)] {
            XCTAssertNil(VideoAttentionCrop.candidate(for: arm(), imageSize: size, frameIndex: 0))
        }
        let collapsed = VideoAttentionCrop.Arm(shoulder: CGPoint(x: 0.5, y: 0.35), elbow: CGPoint(x: 0.7, y: 0.5),
            wrist: CGPoint(x: 0.85, y: 0.55), hip: CGPoint(x: 0.5, y: 0.35), confidence: 0.9)
        XCTAssertNil(VideoAttentionCrop.candidate(for: collapsed, imageSize: portrait, frameIndex: 0))
    }
    func testReachAndBentRaisedHandAreAttentionCandidates() throws {
        let reached = try XCTUnwrap(VideoAttentionCrop.candidate(for: arm(), imageSize: portrait, frameIndex: 4))
        XCTAssertEqual(reached.sourceFrameIndex, 4)
        XCTAssertTrue(reached.normalizedRect.contains(arm().wrist))
        XCTAssertGreaterThan(reached.normalizedRect.height * portrait.height, 100)
        let bent = try XCTUnwrap(VideoAttentionCrop.candidate(for: arm(wrist: CGPoint(x: 0.55, y: 0.68)), imageSize: portrait, frameIndex: 2))
        XCTAssertTrue(bent.normalizedRect.contains(CGPoint(x: 0.55, y: 0.68)))
        // Attention candidates carry geometry, not an object/action classification.
        XCTAssertTrue(reached.score.isFinite && bent.score.isFinite)
    }
    func testEdgeCropKeepsHandAndSurfaceContextWithinImage() throws {
        for x: CGFloat in [0.01, 0.99] {
            let plan = try XCTUnwrap(VideoAttentionCrop.candidate(for: arm(wrist: CGPoint(x: x, y: 0.70)), imageSize: portrait, frameIndex: 0))
            XCTAssertGreaterThanOrEqual(plan.normalizedRect.minX, 0)
            XCTAssertGreaterThanOrEqual(plan.normalizedRect.minY, 0)
            XCTAssertLessThanOrEqual(plan.normalizedRect.maxX, 1)
            XCTAssertLessThanOrEqual(plan.normalizedRect.maxY, 1)
            XCTAssertTrue(plan.normalizedRect.contains(CGPoint(x: x, y: 0.70)))
            XCTAssertLessThan(plan.normalizedRect.minY, 0.70)
        }
    }
    func testPortraitAndLandscapeUseSquarePixelsNotSquareNormalizedCoordinates() throws {
        for size in [portrait, CGSize(width: 960, height: 640)] {
            let plan = try XCTUnwrap(VideoAttentionCrop.candidate(for: arm(), imageSize: size, frameIndex: 0))
            XCTAssertEqual(plan.normalizedRect.width * size.width, plan.normalizedRect.height * size.height, accuracy: 0.01)
            XCTAssertNotEqual(plan.normalizedRect.width, plan.normalizedRect.height)
        }
    }
    func testDetailPlanKeepsSameWristAndPeakWhileReducingBackground() throws {
        let context = try XCTUnwrap(VideoAttentionCrop.candidate(for: arm(), imageSize: portrait, frameIndex: 4))
        let originalRect = context.normalizedRect
        let detail = try XCTUnwrap(VideoAttentionCrop.detailPlan(from: context))
        XCTAssertEqual(detail.sourceFrameIndex, context.sourceFrameIndex)
        XCTAssertEqual(detail.normalizedWrist, context.normalizedWrist)
        XCTAssertEqual(detail.poseConfidence, context.poseConfidence)
        XCTAssertLessThan(detail.normalizedRect.width, context.normalizedRect.width)
        XCTAssertLessThan(detail.normalizedRect.height, context.normalizedRect.height)
        XCTAssertTrue(detail.normalizedRect.contains(arm().wrist))
        XCTAssertTrue(context.normalizedRect.contains(detail.normalizedRect))
        XCTAssertEqual(detail.normalizedRect.width * portrait.width, detail.normalizedRect.height * portrait.height, accuracy: 0.01)
        XCTAssertEqual(context.normalizedRect, originalRect)
        XCTAssertEqual(VideoAttentionCrop.detailPlan(from: detail)?.normalizedRect, detail.normalizedRect)
    }
    func testDetailPlanUsesOriginalWristInsteadOfClampedContextCenter() throws {
        let wrist = CGPoint(x: 0.14, y: 0.70)
        let context = try XCTUnwrap(VideoAttentionCrop.candidate(for: arm(wrist: wrist), imageSize: portrait, frameIndex: 2))
        let detail = try XCTUnwrap(VideoAttentionCrop.detailPlan(from: context))
        XCTAssertEqual(context.normalizedRect.minX, 0)
        XCTAssertLessThan(detail.normalizedRect.midX, context.normalizedRect.midX)
        XCTAssertTrue(detail.normalizedRect.contains(wrist))
        XCTAssertGreaterThanOrEqual(detail.normalizedRect.minX, 0)
        XCTAssertLessThanOrEqual(detail.normalizedRect.maxY, 1)
        let arbitrary = VideoAttentionCropPlan(normalizedRect: context.normalizedRect,
            sourceFrameIndex: 2, poseConfidence: 0.9, score: 0.8)
        XCTAssertNil(VideoAttentionCrop.detailPlan(from: arbitrary), "No original wrist means no invented refined crop")
    }
    func testFixedROIUsesVisionTopRegionAcrossFramesAndPreservesSources() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let first = try fixture(at: folder.appendingPathComponent("before.jpg"), top: [255, 0, 0])
        let second = try fixture(at: folder.appendingPathComponent("after.jpg"), top: [0, 255, 0])
        let sourceBytes = try [Data(contentsOf: first), Data(contentsOf: second)]
        let plan = VideoAttentionCropPlan(normalizedRect: CGRect(x: 0.25, y: 0.60, width: 0.30, height: 0.30),
                                          sourceFrameIndex: 1, poseConfidence: 0.9, score: 0.6)
        let before = try decode(VideoAttentionCrop.jpeg(at: first, using: plan))
        let after = try decode(VideoAttentionCrop.jpeg(at: second, using: plan))
        XCTAssertEqual(before.width, after.width); XCTAssertEqual(before.height, after.height)
        let firstColor = try averageColor(before), secondColor = try averageColor(after)
        XCTAssertGreaterThan(firstColor[0], 220); XCTAssertLessThan(firstColor[2], 30)
        XCTAssertGreaterThan(secondColor[1], 220); XCTAssertLessThan(secondColor[2], 30)
        XCTAssertEqual(try Data(contentsOf: first), sourceBytes[0])
        XCTAssertEqual(try Data(contentsOf: second), sourceBytes[1])
    }
    func testExifRotationIsAppliedBeforeNormalizedCropping() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let source = try fixture(at: folder.appendingPathComponent("rotated.jpg"), top: [255, 0, 0], width: 400, height: 800, orientation: 6)
        // EXIF rotation makes the upright image 800 x 400. This ROI is 100 x 100 pixels.
        let plan = VideoAttentionCropPlan(normalizedRect: CGRect(x: 0.10, y: 0.10, width: 0.125, height: 0.25),
                                          sourceFrameIndex: 0, poseConfidence: 0.9, score: 0.6)
        let cropped = try decode(VideoAttentionCrop.jpeg(at: source, using: plan))
        XCTAssertEqual(cropped.width, 100)
        XCTAssertEqual(cropped.height, 100)
    }
    func testInvalidRegionsAndMissingImagesDoNotProduceCrops() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let source = try fixture(at: folder.appendingPathComponent("fixture.jpg"), top: [255, 0, 0])
        for rect in [CGRect(x: -0.2, y: 0.2, width: 0.3, height: 0.3), CGRect(x: 0.9, y: 0.9, width: 0.3, height: 0.3), CGRect.zero] {
            let plan = VideoAttentionCropPlan(normalizedRect: rect, sourceFrameIndex: 0, poseConfidence: 0.9, score: 0.6)
            XCTAssertThrowsError(try VideoAttentionCrop.jpeg(at: source, using: plan))
        }
        let plan = try XCTUnwrap(VideoAttentionCrop.candidate(for: arm(), imageSize: portrait, frameIndex: 0))
        XCTAssertThrowsError(try VideoAttentionCrop.jpeg(at: folder.appendingPathComponent("missing.jpg"), using: plan))
    }

    private func fixture(at url: URL, top: [UInt8], width: Int = 400, height: Int = 400, orientation: Int = 1) throws -> URL {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let color: [UInt8] = y < height / 2 ? top : [0, 0, 255]
            for x in 0..<width {
                let index = (y * width + x) * 4
                bytes[index] = color[0]; bytes[index + 1] = color[1]; bytes[index + 2] = color[2]
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1, kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
    private func decode(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
    private func averageColor(_ image: CGImage) throws -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return pixel
    }
}
