#!/usr/bin/env swift
import AppKit
import CoreGraphics

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()

let defaultAssetDir = repoRoot
    .appendingPathComponent("Sources/MacResourceGuardApp/Resources/Assets.xcassets/AppIcon.appiconset")
    .path

let baseDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : defaultAssetDir

let fm = FileManager.default
try fm.createDirectory(atPath: baseDir, withIntermediateDirectories: true)

/// Renders the 111iridescence v2.1 Resource Guard icon using 100% custom vector & pixel-grid geometry (zero SF Symbols).
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
    let scale = s / 1024.0

    // 1. Luminous Pearl macOS Squircle (824x824 at 100,100, rx=185)
    let sqRect = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    let sqRadius = 185 * scale
    let squirclePath = NSBezierPath(roundedRect: sqRect, xRadius: sqRadius, yRadius: sqRadius)

    cg.saveGState()
    squirclePath.addClip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let pearlColors = [
        CGColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1.0),
        CGColor(red: 0.925, green: 0.902, blue: 0.961, alpha: 1.0)
    ] as CFArray
    if let grad = CGGradient(colorsSpace: colorSpace, colors: pearlColors, locations: [0.0, 1.0]) {
        cg.drawLinearGradient(
            grad,
            start: CGPoint(x: s * 0.5, y: sqRect.maxY),
            end: CGPoint(x: s * 0.5, y: sqRect.minY),
            options: []
        )
    }

    // 2. Recessed Obsidian Telemetry Screen (640x640 at 192,192, rx=124)
    let screenRect = NSRect(x: 192 * scale, y: 192 * scale, width: 640 * scale, height: 640 * scale)
    let screenPath = NSBezierPath(roundedRect: screenRect, xRadius: 124 * scale, yRadius: 124 * scale)
    NSColor(srgbRed: 0.086, green: 0.063, blue: 0.114, alpha: 1.0).setFill()
    screenPath.fill()

    // 3. 5 Stepped Pixel-Grid Telemetry Columns (Emerald Phosphor + Controlled Turquoise + Cyan)
    let colHeights = [4, 6, 5, 7, 3]
    for c in 0..<5 {
        let x = (264.0 + CGFloat(c) * 104.0) * scale
        let activeRows = colHeights[c]
        for r in 0..<7 {
            // In flipped SVG y=696 is bottom; in AppKit y increases upward from bottom
            let svgY = 696.0 - CGFloat(r) * 48.0
            let appKitY = (1024.0 - svgY - 36.0) * scale
            let segRect = NSRect(x: x, y: appKitY, width: 80 * scale, height: 36 * scale)
            let segPath = NSBezierPath(roundedRect: segRect, xRadius: 7 * scale, yRadius: 7 * scale)
            if r < activeRows {
                if r <= 1 {
                    NSColor(srgbRed: 0.020, green: 0.588, blue: 0.412, alpha: 1.0).setFill()
                } else if r == activeRows - 1 && c == 3 {
                    NSColor(srgbRed: 0.047, green: 0.753, blue: 0.910, alpha: 1.0).setFill()
                } else if r >= 4 {
                    NSColor(srgbRed: 0.204, green: 0.827, blue: 0.600, alpha: 1.0).setFill()
                } else if c == 2 {
                    NSColor(srgbRed: 0.071, green: 0.800, blue: 0.722, alpha: 1.0).setFill()
                } else {
                    NSColor(srgbRed: 0.063, green: 0.725, blue: 0.506, alpha: 1.0).setFill()
                }
            } else {
                NSColor(srgbRed: 0.165, green: 0.129, blue: 0.231, alpha: 0.65).setFill()
            }
            segPath.fill()
        }
    }

    // 4. Top '111.' Pixel Indicator + Guard Ceiling Line
    let ceilingY = (1024.0 - 340.0 - 10.0) * scale
    NSColor(srgbRed: 0.071, green: 0.800, blue: 0.722, alpha: 0.85).setFill()
    NSBezierPath(
        roundedRect: NSRect(x: 252 * scale, y: ceilingY, width: 520 * scale, height: 10 * scale),
        xRadius: 5 * scale,
        yRadius: 5 * scale
    ).fill()

    // 5. Signature 5-Cell Pixel Cross Star (`cross-5`) at top-right of screen
    let starCx = 712.0 * scale
    let starCy = (1024.0 - 280.0) * scale
    let pitch = 26.0 * scale
    let cell = 22.0 * scale
    let starCells: [(CGFloat, CGFloat, NSColor)] = [
        (0, 0, NSColor(srgbRed: 0.878, green: 0.980, blue: 1.000, alpha: 1.0)),
        (0, 1, NSColor(srgbRed: 0.204, green: 0.827, blue: 0.600, alpha: 1.0)),
        (-1, 0, NSColor(srgbRed: 0.071, green: 0.800, blue: 0.722, alpha: 1.0)),
        (1, 0, NSColor(srgbRed: 0.047, green: 0.753, blue: 0.910, alpha: 1.0)),
        (0, -1, NSColor(srgbRed: 0.063, green: 0.725, blue: 0.506, alpha: 1.0))
    ]
    for (dx, dy, col) in starCells {
        col.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: starCx + dx * pitch - cell * 0.5, y: starCy + dy * pitch - cell * 0.5, width: cell, height: cell),
            xRadius: 4 * scale,
            yRadius: 4 * scale
        ).fill()
    }

    NSColor(srgbRed: 0.086, green: 0.063, blue: 0.114, alpha: 0.14).setStroke()
    squirclePath.lineWidth = max(1.0, 3.0 * scale)
    squirclePath.stroke()

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
print("Generated 111iridescence Resource Guard AppIcon asset catalog in \(baseDir)")
