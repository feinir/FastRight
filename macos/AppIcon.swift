import CoreGraphics
import Foundation
import ImageIO

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ rgb: UInt32, opacity: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [
        CGFloat((rgb >> 16) & 0xff) / 255,
        CGFloat((rgb >> 8) & 0xff) / 255,
        CGFloat(rgb & 0xff) / 255,
        opacity
    ])!
}

func fillGradient(_ canvas: CGContext, colors: [CGColor], from start: CGPoint, to end: CGPoint,
                  locations: [CGFloat]? = nil) {
    let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations)!
    canvas.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func fillFacet(_ canvas: CGContext, points: [CGPoint], colors: [CGColor], from start: CGPoint, to end: CGPoint) {
    canvas.saveGState()
    canvas.addLines(between: points)
    canvas.closePath()
    canvas.clip()
    fillGradient(canvas, colors: colors, from: start, to: end)
    canvas.restoreGState()
}

func drawIcon(size: Int) -> CGImage {
    let canvas = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                           bytesPerRow: 0, space: colorSpace,
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(size) / 64
    canvas.translateBy(x: 0, y: CGFloat(size))
    canvas.scaleBy(x: scale, y: -scale)

    // The segmented tile and glass disk come from the FastRemote icon.
    canvas.saveGState()
    canvas.addPath(CGPath(roundedRect: CGRect(x: 3, y: 3, width: 58, height: 58),
                          cornerWidth: 15, cornerHeight: 15, transform: nil))
    canvas.clip()
    fillGradient(canvas, colors: [color(0x93c5fd), color(0xc4b5fd)], from: CGPoint(x: 5, y: 5), to: CGPoint(x: 59, y: 59))
    fillFacet(canvas, points: [CGPoint(x: 3, y: 3), CGPoint(x: 40, y: 3), CGPoint(x: 25, y: 26), CGPoint(x: 3, y: 26)],
              colors: [color(0xf0abfc), color(0xa78bfa)], from: CGPoint(x: 3, y: 12), to: CGPoint(x: 31, y: 43))
    fillFacet(canvas, points: [CGPoint(x: 28, y: 3), CGPoint(x: 61, y: 3), CGPoint(x: 61, y: 34), CGPoint(x: 45, y: 27)],
              colors: [color(0x38bdf8), color(0x6366f1)], from: CGPoint(x: 18, y: 3), to: CGPoint(x: 57, y: 34))
    fillFacet(canvas, points: [CGPoint(x: 3, y: 25), CGPoint(x: 20, y: 14), CGPoint(x: 42, y: 61), CGPoint(x: 3, y: 61)],
              colors: [color(0x67e8f9), color(0x60a5fa)], from: CGPoint(x: 4, y: 58), to: CGPoint(x: 40, y: 27))
    fillFacet(canvas, points: [CGPoint(x: 36, y: 61), CGPoint(x: 61, y: 27), CGPoint(x: 61, y: 61)],
              colors: [color(0xc084fc), color(0xf9a8d4)], from: CGPoint(x: 34, y: 61), to: CGPoint(x: 61, y: 31))
    canvas.restoreGState()

    let disk = CGRect(x: 8.5, y: 8.5, width: 47, height: 47)
    canvas.saveGState()
    canvas.addEllipse(in: disk)
    canvas.clip()
    fillGradient(canvas, colors: [color(0x173b72, opacity: 0.88), color(0x263469, opacity: 0.84), color(0x472967, opacity: 0.8)],
                 from: CGPoint(x: 9, y: 18), to: CGPoint(x: 55, y: 47), locations: [0, 0.52, 1])
    canvas.restoreGState()
    canvas.setStrokeColor(color(0xffffff, opacity: 0.12))
    canvas.setLineWidth(0.75)
    canvas.strokeEllipse(in: disk)

    canvas.setStrokeColor(color(0x6be6bf))
    canvas.setLineWidth(4.5)
    canvas.setLineCap(.round)
    canvas.setLineJoin(.round)
    canvas.move(to: CGPoint(x: 20, y: 22))
    canvas.addLine(to: CGPoint(x: 30, y: 32))
    canvas.addLine(to: CGPoint(x: 20, y: 42))
    canvas.strokePath()

    canvas.setStrokeColor(color(0xd6f0f0))
    for y in [23, 32, 41] {
        canvas.move(to: CGPoint(x: 38, y: y))
        canvas.addLine(to: CGPoint(x: y == 32 ? 46 : 43, y: y))
    }
    canvas.strokePath()
    return canvas.makeImage()!
}

func appendSize(_ value: Int, to data: inout Data) {
    var size = UInt32(value).bigEndian
    withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
}

let sizes = [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128),
             ("ic08", 256), ("ic09", 512), ("ic10", 1024), ("ic11", 32),
             ("ic12", 64), ("ic13", 256), ("ic14", 512)]
var images = Data()
for (type, size) in sizes {
    let png = NSMutableData()
    let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, drawIcon(size: size), nil)
    precondition(CGImageDestinationFinalize(destination))
    images.append(contentsOf: type.utf8)
    appendSize(8 + png.length, to: &images)
    images.append(png as Data)
}

var icon = Data("icns".utf8)
appendSize(8 + images.count, to: &icon)
icon.append(images)
try icon.write(to: output)
