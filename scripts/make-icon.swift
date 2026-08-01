#!/usr/bin/env swift
// Generates assets/AppIcon.icns — the app icon's single source of truth.
//
//   swift scripts/make-icon.swift [output-dir]
//
// The artwork is the app's menu bar motif at desktop-icon scale: three status
// dots (red / green / grey) on a dark rounded square. Drawn programmatically
// so the icon can be regenerated exactly; the .icns is committed because
// rebuilding it on every `make app` would drag AppKit rendering into the
// bundle pipeline for no benefit.
//
// Geometry follows the macOS Big Sur icon grid: on a 1024pt canvas the tile is
// 824pt, centered, with continuous-corner radius ≈ 185pt.

import AppKit

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets"

func drawIcon(canvas: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
        let scale = canvas / 1024

        // Tile with the system grid's margin; the shadow lives inside the
        // canvas margin like every stock icon's.
        let tileSize = 824 * scale
        let tileOrigin = (canvas - tileSize) / 2
        let tileRect = NSRect(x: tileOrigin, y: tileOrigin, width: tileSize, height: tileSize)
        let tile = NSBezierPath(
            roundedRect: tileRect, xRadius: 185 * scale, yRadius: 185 * scale)

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
        shadow.shadowBlurRadius = 24 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
        NSGraphicsContext.current?.saveGraphicsState()
        shadow.set()
        NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).setFill()
        tile.fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        // Subtle vertical sheen so the tile reads as a surface, not a hole.
        let gradient = NSGradient(
            starting: NSColor(srgbRed: 0.19, green: 0.19, blue: 0.21, alpha: 1),
            ending: NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1))
        gradient?.draw(in: tile, angle: -90)

        // Three dots, menu-bar order: red, green, grey. Sized to survive 16px.
        let dot = 168 * scale
        let gap = 76 * scale
        let totalWidth = dot * 3 + gap * 2
        var penX = (canvas - totalWidth) / 2
        let dotY = (canvas - dot) / 2
        let colors = [
            NSColor(srgbRed: 1.00, green: 0.27, blue: 0.23, alpha: 1),
            NSColor(srgbRed: 0.20, green: 0.84, blue: 0.29, alpha: 1),
            NSColor(srgbRed: 0.56, green: 0.56, blue: 0.58, alpha: 1),
        ]
        for color in colors {
            let rect = NSRect(x: penX, y: dotY, width: dot, height: dot)
            let dotShadow = NSShadow()
            dotShadow.shadowColor = color.withAlphaComponent(0.55)
            dotShadow.shadowBlurRadius = 26 * scale
            NSGraphicsContext.current?.saveGraphicsState()
            dotShadow.set()
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            NSGraphicsContext.current?.restoreGraphicsState()
            penX += dot + gap
        }
        return true
    }
}

func writePNG(_ image: NSImage, pixels: Int, to url: URL) throws {
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
            bytesPerRow: 0, bitsPerPixel: 0)
    else { fatalError("bitmap rep") }
    rep.size = image.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(origin: .zero, size: image.size))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("png encode")
    }
    try png.write(to: url)
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: outputDir).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

// (points, scale) pairs iconutil requires.
let variants: [(Int, Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]
for (points, scale) in variants {
    let pixels = points * scale
    let image = drawIcon(canvas: CGFloat(points))
    let suffix = scale == 1 ? "" : "@2x"
    try writePNG(
        image, pixels: pixels,
        to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = [
    "-c", "icns", iconset.path, "-o",
    URL(fileURLWithPath: outputDir).appendingPathComponent("AppIcon.icns").path,
]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
try? fm.removeItem(at: iconset)
print("wrote \(outputDir)/AppIcon.icns")
