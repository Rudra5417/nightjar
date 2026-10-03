#!/usr/bin/env swift
// Samples a rendered icon to confirm the geometry is what the generator intends:
// background at the corners, three ring crossings and the centre dot along the horizontal axis.
import CoreGraphics
import Foundation
import ImageIO

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write(Data("cannot read \(path)\n".utf8))
    exit(1)
}

let width = image.width
let height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
guard let context = CGContext(data: &pixels, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: width * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    exit(1)
}
context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

func sample(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
    let offset = (y * width + x) * 4
    return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
}

func describe(_ label: String, _ x: Int, _ y: Int) {
    let c = sample(x, y)
    let lit = max(c.r, max(c.g, c.b))
    print(String(format: "%-22@ (%4d,%4d)  rgb(%3d,%3d,%3d)  %@",
                 label as NSString, x, y, c.r, c.g, c.b,
                 (lit > 90 ? "lit" : "background") as NSString))
}

let mid = height / 2
print("image \(width)x\(height)")
describe("top-left corner", 20, 20)
describe("bottom-right corner", width - 20, height - 20)
describe("centre dot", width / 2, mid)
for (index, radius) in [0.155, 0.265, 0.375].enumerated() {
    describe("ring \(index + 1) crossing", width / 2 + Int(Double(width) * radius), mid)
}
describe("outside the mark", width / 2 + Int(Double(width) * 0.47), mid)
