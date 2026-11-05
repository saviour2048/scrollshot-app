#!/usr/bin/env swift
//
// Generates ScrollShot's app icon (all macOS sizes) into
// Resources/Assets.xcassets/AppIcon.appiconset.
//
// Run once on a Mac, from the ScrollShot project dir:
//     cd ScrollShot && swift scripts/make_icon.swift
//
// Then `xcodegen generate` (or just rebuild) and the icon is used.

import AppKit

let entries: [(base: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2),
    (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)
]

/// Original ScrollShot mark: a blue card with lines + a downward chevron,
/// evoking "capture / scroll / save" without resembling any other product.
func draw(_ s: CGFloat) {
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    // MARK: Background — blue gradient rounded squircle.
    let inset = s * 0.06
    let bgRect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: bgRect.width * 0.225, yRadius: bgRect.width * 0.225)
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.18, green: 0.56, blue: 1.00, alpha: 1),   // top  #2E8FFF
        NSColor(srgbRed: 0.00, green: 0.40, blue: 1.00, alpha: 1)    // bot  #0066FF
    ])!
    bgPath.addClip()
    gradient.draw(in: bgRect, angle: -90)
    NSGraphicsContext.current!.cgContext.resetClip()

    // MARK: White document card.
    let cardW = s * 0.52
    let cardH = s * 0.40
    let cardX = (s - cardW) / 2
    let cardY = s * 0.32
    let cardPath = NSBezierPath(roundedRect: CGRect(x: cardX, y: cardY, width: cardW, height: cardH),
                                xRadius: cardW * 0.10, yRadius: cardW * 0.10)
    NSColor.white.setFill()
    cardPath.fill()

    // MARK: Gray text lines inside the card.
    let lineColor = NSColor(srgbRed: 0.77, green: 0.80, blue: 0.84, alpha: 1) // #C5CCD6
    lineColor.setFill()
    let lineH = s * 0.042
    let lineCorner = lineH / 2
    let lineLeft = cardX + cardW * 0.14
    let lineRight = cardX + cardW * 0.86

    for (i, (_, widthFactor)) in [(0, 0.52), (1, 1.0), (2, 1.0), (3, 1.0)].enumerated() {
        let y = cardY + cardH * (0.24 + CGFloat(i) * 0.21)
        let width = (lineRight - lineLeft) * widthFactor
        let rect = CGRect(x: lineLeft, y: y - lineH / 2, width: width, height: lineH)
        NSBezierPath(roundedRect: rect, xRadius: lineCorner, yRadius: lineCorner).fill()
    }

    // MARK: Downward chevron below the card.
    let chevronY = cardY - cardH * 0.42
    let arm = s * 0.10
    let chevronPath = NSBezierPath()
    chevronPath.move(to: CGPoint(x: s / 2 - arm, y: chevronY + arm))
    chevronPath.line(to: CGPoint(x: s / 2, y: chevronY))
    chevronPath.line(to: CGPoint(x: s / 2 + arm, y: chevronY + arm))
    NSColor.white.setStroke()
    chevronPath.lineWidth = s * 0.06
    chevronPath.lineCapStyle = .round
    chevronPath.lineJoinStyle = .round
    chevronPath.stroke()
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let outDir = "Resources/Assets.xcassets/AppIcon.appiconset"
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

var images: [[String: String]] = []
for (base, scale) in entries {
    let px = base * scale
    let name = scale == 1 ? "icon_\(base).png" : "icon_\(base)@\(scale)x.png"
    try! render(pixels: px).write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
    images.append([
        "idiom": "mac",
        "size": "\(base)x\(base)",
        "scale": "\(scale)x",
        "filename": name
    ])
}

let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
let data = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! data.write(to: URL(fileURLWithPath: "\(outDir)/Contents.json"))

print("✓ App icon written to \(outDir)")
