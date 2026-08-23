#!/usr/bin/env swift
// Regenerate AppIcon.icns from scratch by rendering a simple rounded-rect
// "M↓" mark at every macOS icon size and passing the iconset through
// iconutil. No external assets required.
//
// Usage: swift scripts/make-icon.swift [output.icns]
//        Defaults to $ROOT/AppIcon.icns

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// One entry per PNG in an .iconset. macOS auto-picks by @1x/@2x + size.
let iconsetEntries: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func renderIcon(px: Int) -> CGImage {
    let size = CGFloat(px)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: px, height: px,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("CGContext failed") }
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Big Sur / Sequoia rounded-square silhouette. Icon guidelines put the
    // corner radius at ~22.5% of the side; a hair below squircle-ideal but
    // close enough for a code icon.
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let inset = size * 0.06                 // safe area so the mark isn't clipped in tiny Dock crops
    let bg = rect.insetBy(dx: inset, dy: inset)
    let radius = bg.width * 0.225
    let path = CGPath(roundedRect: bg, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    let colors = [
        CGColor(red: 0.34, green: 0.42, blue: 0.95, alpha: 1),   // top: indigo-blue
        CGColor(red: 0.13, green: 0.19, blue: 0.55, alpha: 1),   // bottom: deep navy
    ] as CFArray
    guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) else {
        fatalError("CGGradient failed")
    }
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: bg.maxY),
                           end: CGPoint(x: 0, y: bg.minY),
                           options: [])

    // Subtle inner highlight on the top edge — hints at the physical bezel.
    let highlight = CGColor(red: 1, green: 1, blue: 1, alpha: 0.18)
    ctx.setFillColor(highlight)
    let highlightRect = CGRect(x: bg.minX, y: bg.maxY - bg.height * 0.35,
                               width: bg.width, height: bg.height * 0.35)
    ctx.addRect(highlightRect)
    ctx.fillPath()
    ctx.restoreGState()

    // Draw the "M↓" mark via NSGraphicsContext so we get NSFont layout for free.
    let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns

    let text = "M↓" as NSString
    let fontSize = size * 0.48
    let font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.01)
    shadow.shadowBlurRadius = size * 0.02
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
        .shadow: shadow,
        .kern: -size * 0.02,
    ]
    let textSize = text.size(withAttributes: attrs)
    // Nudge up slightly — the descender on ↓ makes the visual center sit low.
    let textRect = NSRect(
        x: (size - textSize.width) / 2,
        y: (size - textSize.height) / 2 - size * 0.02,
        width: textSize.width,
        height: textSize.height
    )
    text.draw(in: textRect, withAttributes: attrs)

    NSGraphicsContext.restoreGraphicsState()

    guard let cg = ctx.makeImage() else { fatalError("makeImage failed") }
    return cg
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                     UTType.png.identifier as CFString,
                                                     1, nil) else {
        fatalError("CGImageDestinationCreateWithURL failed for \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        fatalError("CGImageDestinationFinalize failed for \(url.path)")
    }
}

// -- main --------------------------------------------------------------------

let args = CommandLine.arguments
let scriptDir = URL(fileURLWithPath: args[0]).deletingLastPathComponent()
let repoRoot = scriptDir.deletingLastPathComponent()
let outputURL = args.count >= 2
    ? URL(fileURLWithPath: args[1])
    : repoRoot.appendingPathComponent("AppIcon.icns")

let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for entry in iconsetEntries {
    let image = renderIcon(px: entry.px)
    writePNG(image, to: iconset.appendingPathComponent(entry.name))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(2)
}

try? FileManager.default.removeItem(at: iconset)
print("Wrote \(outputURL.path)")
