// Draws Decanter's app icon on Apple's macOS icon grid. Run through Scripts/make-icon.sh.
//
// Why: macOS 15 and earlier show an icon exactly as the file is drawn. The old icon was the
// wizard on full-bleed white, so on Sequoia it sat in the Dock as a sharp white square. macOS 26
// and later hide that by putting a mis-shaped icon on a rounded tile of their own, which is why
// it looked right on the Mac it was built on. The tile has to be in the file itself.
//
// Grid: 1024 canvas, 824 tile at (100,100), continuous corners of radius 185.4, a soft shadow
// in the transparent margin. The art is cropped to its own bounds and scaled to 90% of the
// tile's height, the size macOS 26 gives the old icon, so it looks the same on both systems.

import AppKit
import SwiftUI

let canvasSide: CGFloat = 1024
let tileSide: CGFloat = 824
let cornerRadius: CGFloat = 185.4
let artFraction: CGFloat = 0.90
/// A pixel counts as art, not background, when its darkest channel is below this.
let backgroundThreshold: UInt8 = 235

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

/// Bounding box of everything that isn't near-white, in pixels from the top-left corner.
func contentBounds(of image: CGImage) -> CGRect {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail("could not read the source pixels")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            guard min(pixels[i], pixels[i + 1], pixels[i + 2]) < backgroundThreshold else { continue }
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= minX, maxY >= minY else { fail("the source image is blank") }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

func drawIcon(art: CGImage) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: Int(canvasSide), height: Int(canvasSide),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail("could not create the canvas")
    }
    let inset = (canvasSide - tileSide) / 2
    let tile = CGRect(x: inset, y: inset, width: tileSide, height: tileSide)
    let tilePath = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: tile).cgPath

    // Shadow. CG's y axis points up, so a negative offset falls downward.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.32))
    context.addPath(tilePath)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fillPath()
    context.restoreGState()

    // Tile face: white fading to a faint cool grey, like Apple's light icons.
    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let face = CGGradient(colorsSpace: space,
                          colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                                   CGColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1)] as CFArray,
                          locations: [0, 1])!
    context.drawLinearGradient(face, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY),
                               options: [])

    // Multiply keeps the art's colours and lets its white background take on the tile's
    // gradient, instead of showing as a white box on the grey.
    let bounds = contentBounds(of: art)
    guard let cropped = art.cropping(to: bounds) else { fail("could not crop the art") }
    let scale = tileSide * artFraction / max(bounds.width, bounds.height)
    let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    context.setBlendMode(.multiply)
    context.interpolationQuality = .high
    context.draw(cropped, in: CGRect(x: tile.midX - size.width / 2, y: tile.midY - size.height / 2,
                                     width: size.width, height: size.height))
    context.restoreGState()

    guard let icon = context.makeImage() else { fail("could not render the icon") }
    return icon
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fail("usage: make-icon.swift <source-art.png> <out-1024.png>") }
guard let source = NSImage(contentsOfFile: arguments[1]),
      let art = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fail("could not open \(arguments[1])")
}
guard let png = NSBitmapImageRep(cgImage: drawIcon(art: art)).representation(using: .png, properties: [:]) else {
    fail("could not encode the PNG")
}
do {
    try png.write(to: URL(fileURLWithPath: arguments[2]))
} catch {
    fail("could not write \(arguments[2]): \(error.localizedDescription)")
}
