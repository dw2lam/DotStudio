// Generates a 1024×1024 app icon: navy→teal squircle with a halftone dot field.
import AppKit

let S = 1024
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8,
                    bytesPerRow: S * 4, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.clear(CGRect(x: 0, y: 0, width: S, height: S))

// Rounded-square (macOS continuous-corner look)
let margin: CGFloat = 76
let rect = CGRect(x: margin, y: margin, width: CGFloat(S) - 2*margin, height: CGFloat(S) - 2*margin)
let radius = rect.width * 0.225
let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.saveGState()
ctx.addPath(path); ctx.clip()

// Background gradient
let bg = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.04, green: 0.06, blue: 0.18, alpha: 1),
    CGColor(red: 0.0,  green: 0.15, blue: 0.26, alpha: 1)
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: rect.minX, y: rect.maxY),
                       end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

func mix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

// Halftone dot field: dots shrink and shift cyan→green along the diagonal.
let cell: CGFloat = 58
var cy = rect.minY + cell/2
while cy < rect.maxY {
    var cx = rect.minX + cell/2
    while cx < rect.maxX {
        let ty = (cy - rect.minY) / rect.height     // 0 bottom → 1 top
        // Big green dots at the bottom shrinking to small cyan dots at the top.
        let r = cell * 0.5 * (0.10 + 0.92 * pow(1 - ty, 1.5))
        let g = ty                                  // 0 bottom → 1 top
        let col = CGColor(red: mix(0.20, 0.16, g), green: mix(1.0, 0.86, g),
                          blue: mix(0.42, 1.0, g), alpha: mix(1.0, 0.82, g))
        ctx.setFillColor(col)
        ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2*r, height: 2*r))
        cx += cell
    }
    cy += cell
}

// Soft top-left sheen
let sheen = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 1, green: 1, blue: 1, alpha: 0.16),
    CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)
] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(sheen, startCenter: CGPoint(x: rect.minX + rect.width*0.28, y: rect.maxY - rect.height*0.22),
                       startRadius: 0,
                       endCenter: CGPoint(x: rect.minX + rect.width*0.28, y: rect.maxY - rect.height*0.22),
                       endRadius: rect.width*0.7, options: [])
ctx.restoreGState()

// Subtle inner border for definition
ctx.addPath(path)
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.08))
ctx.setLineWidth(4)
ctx.strokePath()

let cg = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: cg)
let data = rep.representation(using: .png, properties: [:])!
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/icon_1024.png"
try! data.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
