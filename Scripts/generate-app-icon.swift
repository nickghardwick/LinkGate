#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct Representation {
    let filename: String
    let pixels: Int
}

private let representations = [
    Representation(filename: "AppIcon-16x16@1x.png", pixels: 16),
    Representation(filename: "AppIcon-16x16@2x.png", pixels: 32),
    Representation(filename: "AppIcon-32x32@1x.png", pixels: 32),
    Representation(filename: "AppIcon-32x32@2x.png", pixels: 64),
    Representation(filename: "AppIcon-128x128@1x.png", pixels: 128),
    Representation(filename: "AppIcon-128x128@2x.png", pixels: 256),
    Representation(filename: "AppIcon-256x256@1x.png", pixels: 256),
    Representation(filename: "AppIcon-256x256@2x.png", pixels: 512),
    Representation(filename: "AppIcon-512x512@1x.png", pixels: 512),
    Representation(filename: "AppIcon-512x512@2x.png", pixels: 1024),
]

private let outputDirectory = URL(
    fileURLWithPath: CommandLine.arguments.dropFirst().first
        ?? "LinkGate/Assets.xcassets/AppIcon.appiconset",
    isDirectory: true
)

private let statusItemOutput = URL(
    fileURLWithPath: "LinkGate/Assets.xcassets/StatusItemIcon.imageset/StatusItemIcon.pdf"
)

private func iconPoint(_ x: CGFloat, _ y: CGFloat, scale: CGFloat, pixels: CGFloat) -> CGPoint {
    CGPoint(
        x: (137 + (30 * x)) * scale,
        y: pixels - ((137 + (30 * y)) * scale)
    )
}

private func makeGlyph(point: (CGFloat, CGFloat) -> CGPoint) -> CGPath {
    let path = CGMutablePath()

    path.move(to: point(16.633, 13.043))
    path.addLine(to: point(12, 3))
    path.addLine(to: point(4.03, 20.275))
    path.addCurve(
        to: point(4.165, 20.847),
        control1: point(3.96, 20.475),
        control2: point(4.013, 20.699)
    )
    path.addCurve(
        to: point(4.735, 20.963),
        control1: point(4.315, 20.995),
        control2: point(4.539, 21.04)
    )
    path.addLine(to: point(12, 18.5))
    path.addLine(to: point(12.955, 18.824))

    path.move(to: point(16, 22))
    path.addLine(to: point(21, 17))

    path.move(to: point(21, 21.5))
    path.addLine(to: point(21, 17))
    path.addLine(to: point(16.5, 17))

    return path
}

private func renderIcon(pixels: Int, destination: URL) throws {
    let dimension = CGFloat(pixels)
    let scale = dimension / 1024
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }

    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.clear(CGRect(x: 0, y: 0, width: dimension, height: dimension))

    let background = CGPath(
        roundedRect: CGRect(x: 64 * scale, y: 64 * scale, width: 896 * scale, height: 896 * scale),
        cornerWidth: 200 * scale,
        cornerHeight: 200 * scale,
        transform: nil
    )
    context.addPath(background)
    context.setFillColor(red: 49 / 255, green: 46 / 255, blue: 129 / 255, alpha: 1)
    context.fillPath()

    context.addPath(makeGlyph { x, y in
        iconPoint(x, y, scale: scale, pixels: dimension)
    })
    context.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.setLineWidth(60 * scale)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()

    guard let image = context.makeImage(),
          let destinationWriter = CGImageDestinationCreateWithURL(
              destination as CFURL,
              UTType.png.identifier as CFString,
              1,
              nil
          ) else {
        throw CocoaError(.fileWriteUnknown)
    }

    CGImageDestinationAddImage(destinationWriter, image, nil)
    guard CGImageDestinationFinalize(destinationWriter) else {
        throw CocoaError(.fileWriteUnknown)
    }
}

private func renderStatusItemIcon(destination: URL) throws {
    // Fit the original 24-point SVG glyph into a transparent 18-point menu-bar canvas.
    let dimension: CGFloat = 18
    let glyphScale: CGFloat = 0.9
    var mediaBox = CGRect(x: 0, y: 0, width: dimension, height: dimension)
    guard let context = CGContext(destination as CFURL, mediaBox: &mediaBox, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }

    context.beginPDFPage(nil)
    context.addPath(makeGlyph { x, y in
        CGPoint(x: (x - 2) * glyphScale, y: dimension - (y - 3) * glyphScale)
    })
    context.setStrokeColor(gray: 0, alpha: 1)
    context.setLineWidth(2 * glyphScale)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()
    context.endPDFPage()
    context.closePDF()
}

if CommandLine.arguments.dropFirst().first == "--status-item" {
    try FileManager.default.createDirectory(
        at: statusItemOutput.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try renderStatusItemIcon(destination: statusItemOutput)
    print("Generated \(statusItemOutput.path)")
    exit(0)
}

try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

for representation in representations {
    let destination = outputDirectory.appendingPathComponent(representation.filename)
    try renderIcon(pixels: representation.pixels, destination: destination)
    print("Generated \(destination.path) (\(representation.pixels)x\(representation.pixels))")
}
