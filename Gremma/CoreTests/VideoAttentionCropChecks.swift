import Foundation
import CoreGraphics

@main
enum VideoAttentionCropChecks {
    static func main() throws {
        let size = CGSize(width: 640, height: 960)
        func arm(wrist: CGPoint, confidence: Float = 0.9) -> VideoAttentionCrop.Arm {
            .init(shoulder: CGPoint(x: 0.5, y: 0.7), elbow: CGPoint(x: 0.65, y: 0.60),
                  wrist: wrist, hip: CGPoint(x: 0.5, y: 0.35), confidence: confidence)
        }
        var checked = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            precondition(value(), label); checked += 1
        }
        let reached = VideoAttentionCrop.candidate(for: arm(wrist: CGPoint(x: 0.85, y: 0.55)), imageSize: size, frameIndex: 3)!
        check(reached.sourceFrameIndex == 3, "Peak source index must survive")
        check(reached.normalizedRect.contains(CGPoint(x: 0.85, y: 0.55)), "Crop must include the wrist")
        check(abs(reached.normalizedRect.width * size.width - reached.normalizedRect.height * size.height) < 0.01, "Crop should be square in pixels")
        check(reached.normalizedRect.maxX <= 1 && reached.normalizedRect.maxY <= 1, "Crop must stay within image")
        let low = VideoAttentionCrop.Arm(shoulder: CGPoint(x: 0.5, y: 0.7), elbow: CGPoint(x: 0.52, y: 0.48),
            wrist: CGPoint(x: 0.54, y: 0.20), hip: CGPoint(x: 0.5, y: 0.35), confidence: 0.95)
        check(VideoAttentionCrop.candidate(for: low, imageSize: size, frameIndex: 0) == nil, "Hanging walking arm should not trigger")
        check(VideoAttentionCrop.candidate(for: arm(wrist: CGPoint(x: 0.85, y: 0.55), confidence: 0.1), imageSize: size, frameIndex: 0) == nil, "Low-confidence wrist should not trigger")
        check(VideoAttentionCrop.candidate(for: arm(wrist: CGPoint(x: 0.85, y: 0.55), confidence: .nan), imageSize: size, frameIndex: 0) == nil, "Nonfinite confidence should not trigger")
        check(VideoAttentionCrop.candidate(for: arm(wrist: CGPoint(x: 1.2, y: 0.55)), imageSize: size, frameIndex: 0) == nil, "Outside-image point should not trigger")
        check(VideoAttentionCrop.candidate(for: arm(wrist: CGPoint(x: 0.85, y: 0.55)), imageSize: .zero, frameIndex: 0) == nil, "Empty image should not trigger")
        check(VideoAttentionCrop.candidate(for: arm(wrist: CGPoint(x: 0.85, y: 0.55)), imageSize: CGSize(width: CGFloat.infinity, height: 960), frameIndex: 0) == nil, "Nonfinite image should not trigger")
        let edge = VideoAttentionCrop.candidate(for: arm(wrist: CGPoint(x: 0.99, y: 0.7)), imageSize: size, frameIndex: 1)!
        check(edge.normalizedRect.maxX <= 1 && edge.normalizedRect.contains(CGPoint(x: 0.99, y: 0.7)), "Edge crop should preserve wrist and bounds")
        let raised = VideoAttentionCrop.candidate(for: arm(wrist: CGPoint(x: 0.55, y: 0.68)), imageSize: size, frameIndex: 2)
        check(raised != nil, "Bent elevated hand should remain eligible")
        print("Passed \(checked) attention-crop geometry checks.")
    }
}
