// Original, deterministic illustration for AI-upscaling user-guide captures.
// swift scripts/make-ai-upscaling-fixture.swift [new-output-directory]
// No personal photographs, file lists, or downloaded artwork are used.
import AppKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let defaultDirectory = "/private/tmp/Almaeng-AI-Preview-Demo"
guard CommandLine.arguments.count <= 2 else {
    fatalError("Usage: swift scripts/make-ai-upscaling-fixture.swift [new-output-directory]")
}
let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? defaultDirectory,
               isDirectory: true)
guard !FileManager.default.fileExists(atPath: root.path) else {
    fatalError("Use a new folder; existing directories are never overwritten: \(root.path)")
}
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

let width = 900, height = 620
let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func polygon(_ points: [(CGFloat, CGFloat)], _ fill: UInt32) {
    context.beginPath()
    context.move(to: CGPoint(x: points[0].0, y: points[0].1))
    for point in points.dropFirst() { context.addLine(to: CGPoint(x: point.0, y: point.1)) }
    context.closePath()
    context.setFillColor(color(fill))
    context.fillPath()
}
func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat,
          _ stroke: UInt32, _ thickness: CGFloat = 1, alpha: CGFloat = 1) {
    context.setStrokeColor(color(stroke, alpha: alpha))
    context.setLineWidth(thickness)
    context.move(to: CGPoint(x: x1, y: y1))
    context.addLine(to: CGPoint(x: x2, y: y2))
    context.strokePath()
}
func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ fill: UInt32) {
    context.setFillColor(color(fill))
    context.fill(CGRect(x: x, y: y, width: w, height: h))
}
func ellipse(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ fill: UInt32) {
    context.setFillColor(color(fill))
    context.fillEllipse(in: CGRect(x: x, y: y, width: w, height: h))
}
func label(_ string: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat,
           _ fill: UInt32, weight: NSFont.Weight = .regular) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(cgColor: color(fill))!
    ]
    context.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: string,
        attributes: attributes)), context)
}

// Warm paper and a quiet blue sky keep fine linework legible at every scale.
rect(0, 0, 900, 620, 0xF5F0E4)
let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
    colors: [color(0xD5E5E3), color(0xEDF0E3)] as CFArray, locations: [0, 1])!
context.saveGState()
context.clip(to: CGRect(x: 30, y: 100, width: 840, height: 490))
context.drawLinearGradient(sky, start: CGPoint(x: 0, y: 590),
    end: CGPoint(x: 0, y: 100), options: [])
context.restoreGState()
ellipse(714, 454, 97, 97, 0xEFB57D)
for index in 0..<6 {
    let y = CGFloat(480 + index * 11)
    line(83, y, CGFloat(230 - index * 13), y, 0xFFFFFF, 2, alpha: 0.65)
}
polygon([(30, 147), (266, 167), (562, 139), (870, 196), (870, 100), (30, 100)], 0xAEC5A9)
polygon([(30, 100), (195, 195), (810, 222), (870, 183), (870, 52), (30, 52)], 0xD7D2BE)
for index in 0..<15 {
    let x = CGFloat(20 + index * 69)
    line(x, 55, x + 161, 157, 0xACA997, 0.75)
}
for index in 0..<5 {
    let y = CGFloat(65 + index * 21)
    line(35, y, 865, y + 22, 0xB7B4A2, 0.75)
}

// Main studio: a sloping roof, perspective side wall, and delicate joinery.
polygon([(218, 130), (632, 130), (778, 218), (363, 224)], 0xAFAD99)
polygon([(226, 153), (602, 153), (602, 412), (226, 412)], 0xF9F1D8)
polygon([(602, 153), (740, 237), (740, 497), (602, 412)], 0xDACBB0)
polygon([(211, 413), (606, 413), (755, 505), (350, 505)], 0xB86D4C)
polygon([(211, 413), (606, 413), (606, 402), (211, 402)], 0x4B5147)
polygon([(606, 413), (755, 505), (755, 494), (606, 402)], 0x414B42)
for index in 1..<26 {
    let x = CGFloat(211 + index * 15)
    line(x, 415, x + 139, 502, 0xE6AA7F, 0.9)
}
for index in 1..<12 {
    let t = CGFloat(index) / 12
    line(211 + 139 * t, 413 + 92 * t, 606 + 149 * t, 413 + 92 * t, 0x7E5543, 0.8)
}
rect(238, 381, 350, 11, 0xD9CBAE)
for index in 0..<47 {
    let y = 163 + CGFloat(index) * 4.5
    line(230, y, 599, y, 0xDFD5BF, 0.6)
}
for index in 0..<20 {
    let t = CGFloat(index) / 20
    line(609 + 129 * t, 158 + 79 * t, 609 + 129 * t, 405 + 79 * t, 0xBBAC90, 0.7)
}

// Front windows: narrow mullions and repeating blinds reveal resampling detail.
for index in 0..<4 {
    let x = CGFloat(246 + index * 82)
    rect(x, 202, 63, 122, 0x344E4C)
    rect(x + 5, 208, 53, 110, 0xA4BDB2)
    for slat in 0..<24 {
        let y = CGFloat(211 + slat * 4)
        line(x + 6, y, x + 56, y, 0x617F75, 0.75)
    }
    polygon([(x + 6, 254), (x + 56, 283), (x + 56, 310), (x + 6, 281)], 0xC3D1BD)
    line(x + 31, 208, x + 31, 318, 0x344E4C, 2)
    line(x + 5, 262, x + 58, 262, 0x344E4C, 2)
    rect(x - 3, 197, 69, 5, 0xAD8460)
}
rect(248, 343, 321, 25, 0xF2E8CD)
label("ATELIER  /  02", 259, 349, 17, 0x344E4C, weight: .semibold)
label("LIGHT  -  SPACE  -  DETAIL", 253, 334, 7.5, 0x6E7766)

// Tall side windows follow the same perspective as the side wall.
for index in 0..<3 {
    let x = CGFloat(622 + index * 37)
    let base = CGFloat(187 + index * 22)
    polygon([(x, base), (x + 24, base + 14), (x + 24, base + 140), (x, base + 126)], 0x365454)
    for bar in 0..<15 {
        let y = base + CGFloat(bar * 8 + 5)
        line(x + 3, y, x + 21, y + 11, 0x91B4A5, 0.8)
    }
    line(x + 12, base + 9, x + 12, base + 130, 0xE9DCBE, 1.1)
}

// Terrace deck and thin railing in front of the studio.
polygon([(207, 140), (610, 140), (638, 166), (232, 166)], 0xA78160)
for index in 0..<34 {
    let x = CGFloat(210 + index * 12)
    line(x, 141, x + 26, 165, 0xDBB894, 0.8)
}
for index in 0..<36 {
    let x = CGFloat(216 + index * 11)
    line(x, 141, x, 184, 0x3B554A, index % 5 == 0 ? 2 : 0.8)
}
line(213, 184, 605, 184, 0x304E44, 2)
line(214, 175, 605, 175, 0x304E44, 0.8)

// A deterministic canopy: hundreds of tiny leaves, with no random seed or assets.
func tree(_ cx: CGFloat, _ cy: CGFloat, _ scale: CGFloat) {
    line(cx, cy - 82 * scale, cx + 4 * scale, cy + 38 * scale, 0x6D6550, 7 * scale)
    for branch in 0..<11 {
        let angle = CGFloat(branch) * 2.399963
        let reach = CGFloat(25 + (branch * 13) % 46) * scale
        line(cx, cy - 17 * scale, cx + cos(angle) * reach,
             cy + 37 * scale + sin(angle) * reach * 0.7, 0x716A52, 1.5 * scale)
    }
    for leaf in 0..<520 {
        let angle = CGFloat(leaf) * 2.399963
        let radius = sqrt(CGFloat(leaf) / 520) * 79 * scale
        let x = cx + cos(angle) * radius
        let y = cy + 40 * scale + sin(angle) * radius * 0.74
        let tones: [UInt32] = [0x648567, 0x8AA174, 0x436D58, 0xA8B37C, 0xB8BF8A]
        ellipse(x, y, CGFloat(3 + leaf % 5) * scale,
                CGFloat(2 + leaf % 3) * scale, tones[(leaf * 7) % tones.count])
    }
}
tree(123, 217, 1.2)
tree(803, 252, 0.8)

// Foreground planters and tiny architectural annotation remain wholly synthetic.
for index in 0..<3 {
    let x = CGFloat(664 + index * 42)
    polygon([(x, 104), (x + 24, 104), (x + 29, 129), (x - 5, 129)], 0xBA7554)
    for leaf in 0..<15 {
        let angle = CGFloat(leaf) * 2.399963
        line(x + 11, 129, x + 11 + cos(angle) * 18,
             147 + sin(angle) * 15, 0x547258, 1.2)
    }
}
label("THE QUIET STUDIO", 46, 571, 16, 0x34544E, weight: .semibold)
label("ORIGINAL DEMO ARTWORK  /  900 x 620", 47, 554, 8, 0x6B8379)
label("LINE / TEXTURE / LIGHT", 48, 28, 10, 0x4C665D)
label("ALMAENG RE  -  AI DETAIL STUDY", 629, 28, 8, 0x63756C)
for index in 0..<36 {
    line(CGFloat(302 + index * 4), 27, CGFloat(302 + index * 4),
         CGFloat(35 + index % 3 * 3), 0x4C665D, 0.65)
}

let destinationURL = root.appendingPathComponent("AI-Detail-Demo.png")
let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL,
    UTType.png.identifier as CFString, 1, nil)!
let properties: [CFString: Any] = [kCGImagePropertyTIFFDictionary: [
    kCGImagePropertyTIFFArtist: "AlmaengRe Demo",
    kCGImagePropertyTIFFImageDescription: "Original synthetic architectural illustration for AI-upscaling previews"
]]
CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
precondition(CGImageDestinationFinalize(destination))
print(destinationURL.path)
