#!/usr/bin/env swift
import AppKit
import ImageIO
import UniformTypeIdentifiers

// Run from any directory with: xcrun swift /absolute/path/to/generate_icon.swift
// Native vector drawing; no downloaded imagery, fonts, or generated-image services.
let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let catalog = projectRoot.appendingPathComponent("Gremma/Assets.xcassets", isDirectory: true)
let appIcon = catalog.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: appIcon, withIntermediateDirectories: true)

let size = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
// An RGB bitmap with an unused fourth byte exports without PNG transparency.
guard let context = CGContext(data: nil, width: size, height: size,
    bitsPerComponent: 8, bytesPerRow: size * 4, space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("Cannot allocate the icon drawing context.")
}
context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)
context.setFillColor(CGColor(colorSpace: colorSpace, components: [0.035, 0.065, 0.085, 1])!)
context.fill(CGRect(x: 0, y: 0, width: size, height: size))

// Three intersecting rounded strokes make six evenly spaced asterisk arms.
let center = CGPoint(x: 512, y: 512)
let radius: CGFloat = 260
context.setStrokeColor(CGColor(colorSpace: colorSpace, components: [0.56, 0.91, 0.81, 1])!)
context.setLineWidth(104)
context.setLineCap(.round)
for degrees in [30.0, 90.0, 150.0] {
    let angle = CGFloat(degrees * .pi / 180)
    let dx = cos(angle) * radius
    let dy = sin(angle) * radius
    context.move(to: CGPoint(x: center.x - dx, y: center.y - dy))
    context.addLine(to: CGPoint(x: center.x + dx, y: center.y + dy))
    context.strokePath()
}

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(appIcon.appendingPathComponent("AppIcon.png") as CFURL,
          UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Cannot create the icon PNG.")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write the icon PNG.") }

let catalogContents: [String: Any] = ["info": ["author": "xcode", "version": 1]]
let iconContents: [String: Any] = [
    "images": [["filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"]],
    "info": ["author": "xcode", "version": 1]
]
for (url, contents) in [(catalog.appendingPathComponent("Contents.json"), catalogContents),
                        (appIcon.appendingPathComponent("Contents.json"), iconContents)] {
    let data = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: .atomic)
}
print("Wrote opaque 1024×1024 Gremma app icon: \(appIcon.appendingPathComponent("AppIcon.png").path)")
