#!/usr/bin/env swift
// Renders the DMG window background: 660x440 points at 2x, dark noir ground,
// gold accent, an arrow from the app slot to the Applications slot, and the
// version. Positions match the Finder layout in build-dmg.sh.
//
//   swift make-dmg-background.swift out.png 0.1.0

import AppKit

let args = CommandLine.arguments
guard args.count >= 2 else { fputs("usage: make-dmg-background.swift <out.png> [version]\n", stderr); exit(2) }
let outPath = args[1]
let version = args.count >= 3 ? args[2] : ""

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

let ink = NSColor(calibratedRed: 0.043, green: 0.059, blue: 0.078, alpha: 1)      // #0B0F14
let ink2 = NSColor(calibratedRed: 0.067, green: 0.094, blue: 0.125, alpha: 1)     // #111820
let gold = NSColor(calibratedRed: 0.722, green: 0.533, blue: 0.110, alpha: 1)     // #B8881C
let mist = NSColor(calibratedRed: 0.741, green: 0.816, blue: 0.847, alpha: 1)     // #BDD0D8
let dim = NSColor(calibratedRed: 0.353, green: 0.478, blue: 0.541, alpha: 1)      // #5A7A8A

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
let title = "HOLMES"
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 26, weight: .semibold),
    .foregroundColor: mist,
    .kern: 6
]
let titleSize = (title as NSString).size(withAttributes: titleAttrs)
(title as NSString).draw(at: NSPoint(x: (size.width - titleSize.width) / 2, y: size.height - 82), withAttributes: titleAttrs)

let sub = "Drag Holmes into Applications, then open it once."
let subAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12.5, weight: .regular), .foregroundColor: dim]
let subSize = (sub as NSString).size(withAttributes: subAttrs)
(sub as NSString).draw(at: NSPoint(x: (size.width - subSize.width) / 2, y: size.height - 106), withAttributes: subAttrs)

// Gold rule under the title.
gold.withAlphaComponent(0.6).setFill()
NSBezierPath(rect: NSRect(x: size.width / 2 - 28, y: size.height - 118, width: 56, height: 1.5)).fill()

// Arrow between the two icon slots (Finder y is top-down; slots at y=210 → 440-210).
let y = size.height - 210
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 262, y: y))
arrow.line(to: NSPoint(x: 398, y: y))
arrow.lineWidth = 2.5
arrow.lineCapStyle = .round
gold.setStroke()
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
let footAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular), .foregroundColor: dim]
let footSize = (foot as NSString).size(withAttributes: footAttrs)
(foot as NSString).draw(at: NSPoint(x: (size.width - footSize.width) / 2, y: 26), withAttributes: footAttrs)

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
do { try png.write(to: URL(fileURLWithPath: outPath)) } catch { fputs("write failed: \(error)\n", stderr); exit(1) }
