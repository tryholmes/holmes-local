#!/usr/bin/env swift
// Renders the DMG window background: 660x440 points at 2x, Holmes typography,
// charcoal and cream, an arrow from the app slot to the Applications slot, and the
// version. Positions match the Finder layout in build-dmg.sh.
//
//   swift make-dmg-background.swift out.png 0.1.0

import AppKit
import CoreText

let args = CommandLine.arguments
guard args.count >= 2 else { fputs("usage: make-dmg-background.swift <out.png> [version]\n", stderr); exit(2) }
let outPath = args[1]
let version = args.count >= 3 ? args[2] : ""

// Use the same bundled fonts as the app, without installing them on the Mac.
let fontDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../holmes/Resources/Fonts").standardizedFileURL
for name in ["LTRemark-Regular.otf", "Geist-Regular.ttf", "GeistMono-Regular.ttf"] {
    CTFontManagerRegisterFontsForURL(fontDirectory.appendingPathComponent(name) as CFURL, .process, nil)
}
guard let titleFont = NSFont(name: "LTRemark-Regular", size: 38),
      let bodyFont = NSFont(name: "Geist-Regular", size: 12.5),
      let footerFont = NSFont(name: "GeistMono-Regular", size: 10.5) else {
    fputs("Missing bundled Holmes fonts\n", stderr)
    exit(1)
}

let size = NSSize(width: 660, height: 440)
let scale: CGFloat = 2
let pixel = NSSize(width: size.width * scale, height: size.height * scale)

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixel.width), pixelsHigh: Int(pixel.height),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
rep.size = size
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
// rep.size (points) vs pixelsWide (pixels) already gives this context a 2x CTM;
// do NOT scale again or everything lands at 4x and off the canvas.

let ink = NSColor(srgbRed: 6 / 255, green: 6 / 255, blue: 6 / 255, alpha: 1)
let ink2 = NSColor(srgbRed: 18 / 255, green: 18 / 255, blue: 18 / 255, alpha: 1)
let cream = NSColor(srgbRed: 235 / 255, green: 226 / 255, blue: 209 / 255, alpha: 1)
let text = NSColor(srgbRed: 246 / 255, green: 240 / 255, blue: 233 / 255, alpha: 1)
let dim = text.withAlphaComponent(0.65)

// Ground: vertical gradient + faint vignette.
let rect = NSRect(origin: .zero, size: size)
NSGradient(colors: [ink2, ink])!.draw(in: rect, angle: -90)
let vignette = NSGradient(colorsAndLocations: (NSColor.black.withAlphaComponent(0), 0.55), (NSColor.black.withAlphaComponent(0.55), 1))!
vignette.draw(in: NSBezierPath(rect: rect), relativeCenterPosition: .zero)

// Hairline grain: sparse dots, deterministic.
var seed: UInt64 = 0x9E3779B97F4A7C15
func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat((seed >> 33) % 10_000) / 10_000 }
NSColor.white.withAlphaComponent(0.035).setFill()
for _ in 0..<900 { NSBezierPath(rect: NSRect(x: rnd() * size.width, y: rnd() * size.height, width: 1, height: 1)).fill() }

// Title.
let title = "holmes"
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: titleFont,
    .foregroundColor: text
]
let titleSize = (title as NSString).size(withAttributes: titleAttrs)
(title as NSString).draw(at: NSPoint(x: (size.width - titleSize.width) / 2, y: size.height - 82), withAttributes: titleAttrs)

let sub = "Drag Holmes into Applications, then open it once."
let subAttrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: dim]
let subSize = (sub as NSString).size(withAttributes: subAttrs)
(sub as NSString).draw(at: NSPoint(x: (size.width - subSize.width) / 2, y: size.height - 106), withAttributes: subAttrs)

// Cream rule under the title.
cream.withAlphaComponent(0.6).setFill()
NSBezierPath(rect: NSRect(x: size.width / 2 - 28, y: size.height - 118, width: 56, height: 1.5)).fill()

// Arrow between the two icon slots (Finder y is top-down; slots at y=210 → 440-210).
let y = size.height - 210
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 262, y: y))
arrow.line(to: NSPoint(x: 398, y: y))
arrow.lineWidth = 2.5
arrow.lineCapStyle = .round
cream.setStroke()
arrow.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 398, y: y))
head.line(to: NSPoint(x: 384, y: y + 9))
head.move(to: NSPoint(x: 398, y: y))
head.line(to: NSPoint(x: 384, y: y - 9))
head.lineWidth = 2.5
head.lineCapStyle = .round
head.stroke()

// Footer: version + the promise.
let foot = version.isEmpty ? "Local first. Draft, never send." : "v\(version)  ·  Local first. Draft, never send."
let footAttrs: [NSAttributedString.Key: Any] = [.font: footerFont, .foregroundColor: dim]
let footSize = (foot as NSString).size(withAttributes: footAttrs)
(foot as NSString).draw(at: NSPoint(x: (size.width - footSize.width) / 2, y: 26), withAttributes: footAttrs)

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
do { try png.write(to: URL(fileURLWithPath: outPath)) } catch { fputs("write failed: \(error)\n", stderr); exit(1) }
