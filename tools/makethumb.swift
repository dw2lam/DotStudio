// Landscape halftone thumbnail for the screensaver picker. Args: out W H
import AppKit

let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "/tmp/thumb.png"
let W = args.count > 2 ? Int(args[2])! : 480
let H = args.count > 3 ? Int(args[3])! : 300
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                    bytesPerRow: W * 4, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let rect = CGRect(x: 0, y: 0, width: W, height: H)
let bg = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.04, green: 0.06, blue: 0.18, alpha: 1),
    CGColor(red: 0.0, green: 0.15, blue: 0.26, alpha: 1)
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])
func mix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
let cell = CGFloat(H) / 11.0
var cy = cell/2
while cy < CGFloat(H) {
    var cx = cell/2
    while cx < CGFloat(W) {
        let ty = cy / CGFloat(H)
        let r = cell * 0.5 * (0.10 + 0.92 * pow(1 - ty, 1.5))
        let col = CGColor(red: mix(0.20, 0.16, ty), green: mix(1.0, 0.86, ty),
                          blue: mix(0.42, 1.0, ty), alpha: mix(1.0, 0.82, ty))
        ctx.setFillColor(col)
        ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2*r, height: 2*r))
        cx += cell
    }
    cy += cell
}
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out) \(W)x\(H)")
