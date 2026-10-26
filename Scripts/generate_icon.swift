#!/usr/bin/env swift
import AppKit
import CoreGraphics

let baseDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "/Users/theodeville/Documents/Mac Ressource Guard/Sources/MacResourceGuardApp/Resources/Assets.xcassets/AppIcon.appiconset"

let fm = FileManager.default
try fm.createDirectory(atPath: baseDir, withIntermediateDirectories: true)

func renderIcon(pixelSize: Int) -> Data? {
    let size = NSSize(width: pixelSize, height: pixelSize)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }
    rep.size = size

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = context
    let cg = context.cgContext

    let s = CGFloat(pixelSize)
    let inset = s * 0.08
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let cornerRadius = rect.width * 0.225

    // Background squircle with deep navy-teal gradient
    let squirclePath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    cg.saveGState()
    squirclePath.addClip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let colors = [
        CGColor(red: 0.07, green: 0.14, blue: 0.26, alpha: 1.0),
        CGColor(red: 0.04, green: 0.32, blue: 0.38, alpha: 1.0)
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0]) {
        cg.drawLinearGradient(
            gradient,
            start: CGPoint(x: s * 0.5, y: s - inset),
            end: CGPoint(x: s * 0.5, y: inset),
            options: []
        )
    }

    // Subtle inner border
    NSColor(calibratedWhite: 1.0, alpha: 0.18).setStroke()
    squirclePath.lineWidth = max(1.0, s * 0.015)
    squirclePath.stroke()

    // Draw SF Symbol gauge/shield centered
    let symbolPointSize = s * 0.46
    let symbolConfig = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "gauge.with.dots.needle.bottom.50percent", accessibilityDescription: nil)?
        .withSymbolConfiguration(symbolConfig) {
        let symSize = symbol.size
        let symRect = NSRect(
            x: (s - symSize.width) / 2.0,
            y: (s - symSize.height) / 2.0,
            width: symSize.width,
            height: symSize.height
        )
        let tinted = NSImage(size: symSize)
        tinted.lockFocus()
        NSColor(calibratedRed: 0.32, green: 0.92, blue: 0.72, alpha: 1.0).set()
        let localRect = NSRect(origin: .zero, size: symSize)
        symbol.draw(in: localRect)
        localRect.fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.draw(in: symRect)
    }

    cg.restoreGState()
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])
}

let specs: [(name: String, size: Int, scale: Int, pixels: Int)] = [
    ("icon_16x16.png", 16, 1, 16),
    ("icon_16x16@2x.png", 16, 2, 32),
    ("icon_32x32.png", 32, 1, 32),
    ("icon_32x32@2x.png", 32, 2, 64),
    ("icon_128x128.png", 128, 1, 128),
    ("icon_128x128@2x.png", 128, 2, 256),
    ("icon_256x256.png", 256, 1, 256),
    ("icon_256x256@2x.png", 256, 2, 512),
    ("icon_512x512.png", 512, 1, 512),
    ("icon_512x512@2x.png", 512, 2, 1024)
]

for spec in specs {
    if let data = renderIcon(pixelSize: spec.pixels) {
        let outURL = URL(fileURLWithPath: baseDir).appendingPathComponent(spec.name)
        try data.write(to: outURL)
    }
}

let contentsJSON = """
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try contentsJSON.write(
    to: URL(fileURLWithPath: baseDir).appendingPathComponent("Contents.json"),
    atomically: true,
    encoding: .utf8
)

let rootContentsJSON = """
{
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
let assetsRoot = URL(fileURLWithPath: baseDir).deletingLastPathComponent()
try rootContentsJSON.write(
    to: assetsRoot.appendingPathComponent("Contents.json"),
    atomically: true,
    encoding: .utf8
)
print("Generated AppIcon asset catalog in \(baseDir)")
