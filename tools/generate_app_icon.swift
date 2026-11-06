import AppKit
import Foundation

// Original Sign2Speak artwork: a diagonal open hand and two sound waves.
// No SF Symbol, font glyph or third-party graphic is copied into this icon.
// Run from the repository root: swift tools/generate_app_icon.swift
let destination = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Sign2Speak/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }

func drawMark() {
    let teal = NSColor(srgbRed: 0.188, green: 0.820, blue: 0.784, alpha: 1)
    NSGraphicsContext.saveGraphicsState()
    let rotation = NSAffineTransform()
    rotation.translateX(by: 400, yBy: 500)
    rotation.rotate(byDegrees: -48)
    rotation.translateX(by: -400, yBy: -500)
    rotation.concat()
    let hand = NSBezierPath()
    hand.move(to: point(300, 220))
    hand.curve(to: point(215, 410), controlPoint1: point(300, 300), controlPoint2: point(250, 340))
    hand.line(to: point(165, 495))
    hand.curve(to: point(225, 535), controlPoint1: point(140, 540), controlPoint2: point(195, 570))
    hand.line(to: point(285, 455))
    hand.line(to: point(285, 690))
    hand.curve(to: point(345, 690), controlPoint1: point(285, 730), controlPoint2: point(345, 730))
    hand.line(to: point(345, 540))
    hand.curve(to: point(375, 540), controlPoint1: point(345, 520), controlPoint2: point(375, 520))
    hand.line(to: point(375, 710))
    hand.curve(to: point(435, 710), controlPoint1: point(375, 750), controlPoint2: point(435, 750))
    hand.line(to: point(435, 540))
    hand.curve(to: point(465, 540), controlPoint1: point(435, 520), controlPoint2: point(465, 520))
    hand.line(to: point(465, 690))
    hand.curve(to: point(525, 690), controlPoint1: point(465, 730), controlPoint2: point(525, 730))
    hand.line(to: point(525, 520))
    hand.curve(to: point(555, 520), controlPoint1: point(525, 500), controlPoint2: point(555, 500))
    hand.line(to: point(555, 630))
    hand.curve(to: point(615, 630), controlPoint1: point(555, 670), controlPoint2: point(615, 670))
    hand.line(to: point(615, 440))
    hand.curve(to: point(530, 220), controlPoint1: point(615, 340), controlPoint2: point(530, 300))
    hand.close()
    teal.setStroke()
    hand.lineWidth = 24
    hand.lineJoinStyle = .round
    hand.lineCapStyle = .round
    hand.stroke()
    NSGraphicsContext.restoreGraphicsState()

    for (x, radius) in [(CGFloat(725), CGFloat(55)), (CGFloat(825), CGFloat(105))] {
        let wave = NSBezierPath()
        wave.move(to: point(x, 500 - radius))
        wave.curve(to: point(x, 500 + radius),
                   controlPoint1: point(x + radius * 0.8, 500 - radius * 0.5),
                   controlPoint2: point(x + radius * 0.8, 500 + radius * 0.5))
        wave.lineWidth = 28
        wave.lineCapStyle = .round
        teal.setStroke()
        wave.stroke()
    }
}

func render(pixels: Int, opaque: Bool) -> Data {
    let canvas = CGContext(data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: pixels * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: canvas, flipped: false)
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixels) / 1024)
    transform.concat()
    if opaque {
        NSColor.black.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024)).fill()
    }
    drawMark()
    NSGraphicsContext.restoreGraphicsState()
    return NSBitmapImageRep(cgImage: canvas.makeImage()!).representation(using: .png, properties: [:])!
}

let entries: [(String, String, String, Int)] = [
    ("iphone", "20x20", "2x", 40), ("iphone", "20x20", "3x", 60),
    ("iphone", "29x29", "2x", 58), ("iphone", "29x29", "3x", 87),
    ("iphone", "40x40", "2x", 80), ("iphone", "40x40", "3x", 120),
    ("iphone", "60x60", "2x", 120), ("iphone", "60x60", "3x", 180),
    ("ios-marketing", "1024x1024", "1x", 1024)
]
var images: [[String: String]] = []
for (idiom, size, scale, pixels) in entries {
    let filename = "AppIcon-\(size)-\(scale).png"
    try render(pixels: pixels, opaque: true).write(to: destination.appendingPathComponent(filename))
    images.append(["idiom": idiom, "size": size, "scale": scale, "filename": filename])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: destination.appendingPathComponent("Contents.json"))
let brand = destination.deletingLastPathComponent().appendingPathComponent("BrandMark.imageset")
try FileManager.default.createDirectory(at: brand, withIntermediateDirectories: true)
// Launch snapshots use ordinary bundle PNGs, generated from the same artwork.
// Keep these byte-identical to BrandMark so branding cannot drift.
let launch = destination.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("LaunchAssets")
try FileManager.default.createDirectory(at: launch, withIntermediateDirectories: true)
var brandImages: [[String: String]] = []
for scale in 1...3 {
    let filename = "BrandMark-\(scale)x.png"
    let data = render(pixels: 256 * scale, opaque: false)
    try data.write(to: brand.appendingPathComponent(filename))
    let launchFilename = scale == 1 ? "LaunchMark.png" : "LaunchMark@\(scale)x.png"
    try data.write(to: launch.appendingPathComponent(launchFilename))
    brandImages.append(["idiom": "universal", "scale": "\(scale)x", "filename": filename])
}
try JSONSerialization.data(withJSONObject: ["images": brandImages, "info": ["author": "xcode", "version": 1],
    "properties": ["template-rendering-intent": "original"]], options: [.prettyPrinted, .sortedKeys])
    .write(to: brand.appendingPathComponent("Contents.json"))
print("Generated app icons, transparent BrandMark assets and matching launch PNGs.")
