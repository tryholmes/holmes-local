#!/usr/bin/env swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Run from any directory: swift holmes/scripts/generate-app-icons.swift
// Keep the original mascot unchanged. App-icon slots are square canvases, not
// a request to resize the portrait artwork to a square aspect ratio.
let assets = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../holmes/Resources/Assets.xcassets").standardizedFileURL
let sourceURL = assets.appendingPathComponent("NoirCharacter.imageset/holmes-character-transparent.png")
let iconSet = assets.appendingPathComponent("AppIcon.appiconset")

func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw NSError(domain: "HolmesAppIcon", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: message]) }
    return value
}

func bitmap(width: Int, height: Int) throws -> CGContext {
    try require(CGContext(data: nil, width: width, height: height,
                          bitsPerComponent: 8, bytesPerRow: width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                              CGBitmapInfo.byteOrder32Big.rawValue), "Cannot create icon bitmap")
}

let source = try require(CGImageSourceCreateWithURL(sourceURL as CFURL, nil), "Cannot load mascot")
let image = try require(CGImageSourceCreateImageAtIndex(source, 0, nil), "Cannot decode mascot")
let normalized = try bitmap(width: image.width, height: image.height)
normalized.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
let pixels = try require(normalized.data, "Missing mascot pixels").assumingMemoryBound(to: UInt8.self)

// Trim transparent margins before fitting, so every icon size has the same
// intentional padding and the mascot remains readable in the Dock and Finder.
var minX = image.width, minY = image.height, maxX = -1, maxY = -1
for y in 0..<image.height {
    for x in 0..<image.width where pixels[y * normalized.bytesPerRow + x * 4 + 3] > 0 {
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
    }
}
guard maxX >= minX, maxY >= minY else { fatalError("Mascot is fully transparent") }
let bounds = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
let normalizedImage = try require(normalized.makeImage(), "Cannot normalize mascot")
let artwork = try require(normalizedImage.cropping(to: bounds), "Cannot trim mascot margins")

struct IconManifest: Decodable {
    struct Slot: Decodable {
        let filename: String
        let size: String
        let scale: String
    }
    let images: [Slot]
}
let manifest = try JSONDecoder().decode(IconManifest.self,
    from: Data(contentsOf: iconSet.appendingPathComponent("Contents.json")))

for slot in manifest.images {
    let points = try require(Int(slot.size.split(separator: "x")[0]), "Invalid icon size")
    let density = try require(Int(slot.scale.dropLast()), "Invalid icon scale")
    let side = points * density
    let context = try bitmap(width: side, height: side)
    let scale = CGFloat(side) * 0.84 / max(bounds.width, bounds.height)
    let width = bounds.width * scale
    let height = bounds.height * scale
    let destination = CGRect(x: (CGFloat(side) - width) / 2,
                             y: (CGFloat(side) - height) / 2,
                             width: width, height: height)
    context.interpolationQuality = .high
    context.draw(artwork, in: destination)
    let rendered = try require(context.makeImage(), "Cannot render icon")
    let output = try require(CGImageDestinationCreateWithURL(
        iconSet.appendingPathComponent(slot.filename) as CFURL,
        UTType.png.identifier as CFString, 1, nil), "Cannot create PNG")
    CGImageDestinationAddImage(output, rendered, nil)
    guard CGImageDestinationFinalize(output) else { fatalError("Cannot write \(slot.filename)") }
    print("\(slot.filename): \(side)×\(side), artwork aspect \(bounds.width / bounds.height)")
}
