// tools/perf/imgdiff.swift — mean and max per-channel |Δ| between same-named PNGs in two dirs,
// for the files given (gallery-sample.sh --compare runs it on the ones that aren't byte-identical).
// usage: xcrun swift imgdiff.swift <dirA> <dirB> <file>...
import AppKit

let a = CommandLine.arguments
func pixels(_ path: String) -> (Int, Int, [UInt8])? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    buf.withUnsafeMutableBytes { p in
        let c = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return (w, h, buf)
}
for f in a.dropFirst(3) {
    guard let x = pixels(a[1] + "/" + f), let y = pixels(a[2] + "/" + f), x.0 == y.0, x.1 == y.1 else {
        print("  \(f): size mismatch or unreadable"); continue
    }
    var sum = 0, mx = 0, n = 0
    for i in 0..<x.2.count where i % 4 != 3 {
        let d = abs(Int(x.2[i]) - Int(y.2[i]))
        sum += d; mx = max(mx, d); if d > 0 { n += 1 }
    }
    print(String(format: "  %@: mean |Δ| %.4f, max %d, %.3f%% of channels differ", f,
                 Double(sum) / Double(x.2.count * 3 / 4), mx, Double(n) * 100 / Double(x.2.count * 3 / 4)))
}
