#!/usr/bin/env swift
//
// Renders the Nightjar app icon. Run with a size and an output path:
//
//   swift scripts/make-app-icon.swift 1024 App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
//   swift scripts/make-app-icon.swift 180 /tmp/icon-preview.png
//
// The mark is a source at the centre of three rings: a radio being listened to, with the
// concentric rings standing for the waves arriving from it. Drawn in Core Graphics so the icon is
// reproducible from source rather than being an opaque binary, and written without an alpha
// channel because App Store and device icon pipelines reject icons that have one.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
let size = arguments.count > 1 ? (Int(arguments[1]) ?? 1024) : 1024
let outputPath = arguments.count > 2 ? arguments[2] : "AppIcon-1024.png"

let side = CGFloat(size)
let space = CGColorSpaceCreateDeviceRGB()

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r / 255, g / 255, b / 255, a])!
}

let cyan = rgb(45, 212, 247)
let backgroundTop = rgb(18, 26, 41)
let backgroundBottom = rgb(6, 9, 14)

guard let context = CGContext(data: nil,
                              width: size,
                              height: size,
                              bitsPerComponent: 8,
                              bytesPerRow: 0,
                              space: space,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    FileHandle.standardError.write(Data("could not create a bitmap context\n".utf8))
    exit(1)
}

// Background: a diagonal gradient dark enough that the mark carries the whole icon.
context.setFillColor(backgroundBottom)
context.fill(CGRect(x: 0, y: 0, width: side, height: side))
if let gradient = CGGradient(colorsSpace: space,
                             colors: [backgroundTop, backgroundBottom] as CFArray,
                             locations: [0, 1]) {
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: side),
                               end: CGPoint(x: side, y: 0),
                               options: [])
}

let centre = CGPoint(x: side * 0.5, y: side * 0.5)

// A soft halo so the source reads as emitting rather than as a flat dot.
if let halo = CGGradient(colorsSpace: space,
                         colors: [rgb(45, 212, 247, 0.30), rgb(45, 212, 247, 0)] as CFArray,
                         locations: [0, 1]) {
    context.drawRadialGradient(halo,
                               startCenter: centre, startRadius: 0,
                               endCenter: centre, endRadius: side * 0.30,
                               options: [])
}

// radius, stroke width, colour, opacity — cyan at the source grading to violet at the edge.
let rings: [(radius: CGFloat, width: CGFloat, colour: CGColor, opacity: CGFloat)] = [
    (0.155, 0.050, cyan, 1.00),
    (0.265, 0.046, rgb(96, 152, 246), 0.80),
    (0.375, 0.040, rgb(139, 92, 246), 0.55),
]

context.setLineCap(.round)
for ring in rings {
    context.setStrokeColor(ring.colour.copy(alpha: ring.opacity) ?? ring.colour)
    context.setLineWidth(side * ring.width)
    context.strokeEllipse(in: CGRect(x: centre.x - side * ring.radius,
                                     y: centre.y - side * ring.radius,
                                     width: side * ring.radius * 2,
                                     height: side * ring.radius * 2))
}

let dotRadius = side * 0.060
context.setFillColor(cyan)
context.fillEllipse(in: CGRect(x: centre.x - dotRadius,
                               y: centre.y - dotRadius,
                               width: dotRadius * 2,
                               height: dotRadius * 2))

guard let image = context.makeImage() else {
    FileHandle.standardError.write(Data("could not render the icon\n".utf8))
    exit(1)
}

let url = URL(fileURLWithPath: outputPath)
guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                        UTType.png.identifier as CFString,
                                                        1, nil) else {
    FileHandle.standardError.write(Data("could not open \(outputPath)\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("could not write \(outputPath)\n".utf8))
    exit(1)
}
print("wrote \(outputPath) at \(size)x\(size), no alpha channel")
