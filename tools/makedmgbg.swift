// DMG installer background: dark dither field, wordmark, and a drag arrow.
import AppKit

let W = 660, H = 420
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                    bytesPerRow: W * 4, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Background gradient
let bg = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.03, green: 0.05, blue: 0.13, alpha: 1),
    CGColor(red: 0.02, green: 0.10, blue: 0.18, alpha: 1)
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])

// Subtle halftone dots (denser/brighter toward the bottom)
func mix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
let cell: CGFloat = 22
var cy: CGFloat = 0
while cy < CGFloat(H) {
    var cx: CGFloat = 0
    while cx < CGFloat(W) {
        let ty = cy / CGFloat(H)
        let r = cell * 0.5 * (0.05 + 0.4 * pow(1 - ty, 2.0))
        let alpha = mix(0.10, 0.45, pow(1 - ty, 1.5))
        ctx.setFillColor(CGColor(red: mix(0.2, 0.16, ty), green: mix(1.0, 0.9, ty),
                                 blue: mix(0.5, 1.0, ty), alpha: alpha))
        ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2*r, height: 2*r))
        cx += cell
    }
    cy += cell
}

func draw(_ s: String, _ size: CGFloat, _ x: CGFloat, _ y: CGFloat, _ color: CGColor, weight: String = "Medium") {
    let font = CTFontCreateWithName("HelveticaNeue-\(weight)" as CFString, size, nil)
    let attr = CFAttributedStringCreate(nil, s as CFString,
        [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color] as CFDictionary)!
    let line = CTLineCreateWithAttributedString(attr)
    let b = CTLineGetImageBounds(line, ctx)
    ctx.textPosition = CGPoint(x: x - b.width/2, y: y)
    CTLineDraw(line, ctx)
}

// Wordmark + subtitle (CG origin bottom-left, so high y = top)
draw("DotStudio", 40, CGFloat(W)/2, CGFloat(H) - 78, CGColor(red: 1, green: 1, blue: 1, alpha: 0.96), weight: "Bold")
draw("dither · halftone · matrix screensavers", 15, CGFloat(W)/2, CGFloat(H) - 105,
     CGColor(red: 0.55, green: 0.9, blue: 1.0, alpha: 0.85))

// Drag arrow between the two icon slots (icons sit ~y=200 from top → CG y ≈ H-200-... )
let arrowY = CGFloat(H) - 218
ctx.setStrokeColor(CGColor(red: 0.55, green: 0.9, blue: 1.0, alpha: 0.7))
ctx.setLineWidth(4); ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: 268, y: arrowY)); ctx.addLine(to: CGPoint(x: 392, y: arrowY)); ctx.strokePath()
ctx.beginPath()
ctx.move(to: CGPoint(x: 392, y: arrowY))
ctx.addLine(to: CGPoint(x: 376, y: arrowY + 10))
ctx.addLine(to: CGPoint(x: 376, y: arrowY - 10))
ctx.closePath()
ctx.setFillColor(CGColor(red: 0.55, green: 0.9, blue: 1.0, alpha: 0.7)); ctx.fillPath()
draw("drag to install", 13, CGFloat(W)/2, CGFloat(H) - 250, CGColor(red: 0.8, green: 0.85, blue: 0.95, alpha: 0.7))

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/dmgbg.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
// also @2x for retina
print("wrote \(out)")
