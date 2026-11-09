//  tools/icon/icon.swift — DotStudio app icon compositor (macOS 26 "Tahoe" grid).
//
//  The artwork comes from the app's own renderer (tools/gallery renders the scenes at 1024×1024;
//  tools/icon/build.sh drives it), and this file does the rest per pixel: the scene mapped into
//  the motif, the squircle body on Apple's 1024 grid (824 pt body, 100 pt margins), a glass rim +
//  sheen, and the drop shadow. No external art.
//
//  usage: icon render <chrome|orbit|contour|lens> <renderDir> <out.png>
//         icon sizes <icon1024.png> <AppIcon.appiconset dir>   (writes the 10 mac sizes)
//         icon iconset <icon1024.png> <out.iconset dir>          (for iconutil → .icns)
//         icon preview <sheet.png> <dir of <concept>.png> [concepts…]  (sizes, light/dark, Dock mock)

import AppKit
import CoreImage

let S = 1024
let C: Float = 512          // canvas centre (px)
let A: Float = 412          // body half-size (px): 824 / 2
let PX: Float = 1 / A       // one pixel, in body units
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

typealias V2 = SIMD2<Float>
typealias V3 = SIMD3<Float>

// MARK: - small math

@inline(__always) func clamp01(_ x: Float) -> Float { min(max(x, 0), 1) }
@inline(__always) func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
@inline(__always) func mix(_ a: V3, _ b: V3, _ t: Float) -> V3 { a + (b - a) * t }
@inline(__always) func smooth(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let t = clamp01((x - e0) / (e1 - e0)); return t * t * (3 - 2 * t)
}
@inline(__always) func len(_ v: V2) -> Float { (v * v).sum().squareRoot() }
@inline(__always) func norm(_ v: V3) -> V3 { v / max((v * v).sum().squareRoot(), 1e-6) }
@inline(__always) func dot(_ a: V3, _ b: V3) -> Float { (a * b).sum() }
@inline(__always) func dot2(_ a: V2, _ b: V2) -> Float { (a * b).sum() }
@inline(__always) func lum(_ c: V3) -> Float { dot(c, V3(0.2126, 0.7152, 0.0722)) }
func rgb(_ hex: UInt32) -> V3 {
    V3(Float((hex >> 16) & 255) / 255, Float((hex >> 8) & 255) / 255, Float(hex & 255) / 255)
}
/// Pixel centre → body units (x right, y up; the body spans −1…1).
@inline(__always) func unit(_ i: Int, _ j: Int) -> V2 {
    V2((Float(i) + 0.5 - C) / A, (C - (Float(j) + 0.5)) / A)
}
/// Body units → texture pixel coordinates of a 1024 render (y down).
@inline(__always) func texXY(_ p: V2) -> V2 { V2(C + p.x * A, C - p.y * A) }

// Value noise + fbm (deterministic; for the contour terrain and the starfield).
@inline(__always) func hash(_ x: Int32, _ y: Int32, _ s: Int32 = 0) -> Float {
    var h = UInt32(bitPattern: x &* 374761393 &+ y &* 668265263 &+ s &* 2147483647)
    h = (h ^ (h >> 13)) &* 1274126177
    h ^= h >> 16
    return Float(h & 0xFFFFFF) / Float(0xFFFFFF)
}
func vnoise(_ p: V2, _ s: Int32 = 0) -> Float {
    let fx = p.x.rounded(.down), fy = p.y.rounded(.down)
    let ix = Int32(fx), iy = Int32(fy)
    var tx = p.x - fx, ty = p.y - fy
    tx = tx * tx * (3 - 2 * tx); ty = ty * ty * (3 - 2 * ty)
    let a = hash(ix, iy, s), b = hash(ix + 1, iy, s), c = hash(ix, iy + 1, s), d = hash(ix + 1, iy + 1, s)
    return mix(mix(a, b, tx), mix(c, d, tx), ty) * 2 - 1
}
func fbm(_ p: V2, _ s: Int32 = 0) -> Float {
    var f: Float = 0, amp: Float = 0.5, q = p
    for o in 0..<4 { f += amp * vnoise(q, s + Int32(o) * 17); q = V2(q.x * 2.03 + 1.7, q.y * 2.03 - 0.9); amp *= 0.5 }
    return f
}

// MARK: - float image

final class Img {
    let w: Int, h: Int
    var p: [V3]
    init(_ w: Int, _ h: Int, fill: V3 = .zero) { self.w = w; self.h = h; p = Array(repeating: fill, count: w * h) }

    static func load(_ path: String) -> Img {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("can't read \(path)") }
        return Img(cg)
    }
    init(_ cg: CGImage) {
        w = cg.width; h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        p = (0..<(w * h)).map { V3(Float(bytes[$0 * 4]), Float(bytes[$0 * 4 + 1]), Float(bytes[$0 * 4 + 2])) / 255 }
    }
    /// Bilinear sample at pixel coordinates (y down), clamped at the edges.
    func sample(_ q: V2) -> V3 {
        let x = min(max(q.x - 0.5, 0), Float(w - 1)), y = min(max(q.y - 0.5, 0), Float(h - 1))
        let x0 = Int(x), y0 = Int(y), x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
        let tx = x - Float(x0), ty = y - Float(y0)
        return mix(mix(p[y0 * w + x0], p[y0 * w + x1], tx), mix(p[y1 * w + x0], p[y1 * w + x1], tx), ty)
    }
    func cgImage(alpha: [Float]? = nil) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for k in 0..<(w * h) {
            let a = alpha?[k] ?? 1
            let c = p[k]
            bytes[k * 4 + 0] = UInt8(clamp01(c.x) * a * 255 + 0.5)
            bytes[k * 4 + 1] = UInt8(clamp01(c.y) * a * 255 + 0.5)
            bytes[k * 4 + 2] = UInt8(clamp01(c.z) * a * 255 + 0.5)
            bytes[k * 4 + 3] = UInt8(a * 255 + 0.5)
        }
        let data = CFDataCreate(nil, bytes, bytes.count)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: sRGB,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
    func blurred(_ sigma: Double) -> Img {
        let ci = CIImage(cgImage: cgImage()).clampedToExtent().applyingGaussianBlur(sigma: sigma)
            .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        return Img(ciContext.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: sRGB)!)
    }
    /// Runs f over every pixel (rows in parallel); f gets the body-unit position.
    func shade(_ f: (V2, Int, Int) -> V3) {
        p.withUnsafeMutableBufferPointer { buf in
            let b = buf
            DispatchQueue.concurrentPerform(iterations: h) { j in
                for i in 0..<w { b[j * w + i] = f(unit(i, j), i, j) }
            }
        }
    }
}
let ciContext = CIContext(options: [.workingColorSpace: sRGB])

func writePNG(_ cg: CGImage, _ path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cg, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("can't write \(path)") }
}

// MARK: - body: squircle, glass finish, shadow

/// The body is a rounded square with continuous (superellipse) corners — Apple's icon shape:
/// a 185/824 corner radius whose curvature eases in over ~1.5× that length.
let RC: Float = 0.69      // where the corner curve leaves the straight edge (body units)
let NC: Float = 3.1       // corner superellipse exponent (puts the 45° point where a 185 pt radius would)
/// Signed distance to the body edge in body units (negative inside), plus the outward normal.
@inline(__always) func bodySD(_ p: V2) -> (Float, V2) {
    let sgn = V2(p.x < 0 ? -1 : 1, p.y < 0 ? -1 : 1)
    let q = V2(abs(p.x), abs(p.y)) - V2(repeating: 1 - RC)
    if q.x <= 0 || q.y <= 0 {
        return q.x > q.y ? (q.x - RC, V2(sgn.x, 0)) : (q.y - RC, V2(0, sgn.y))
    }
    let c = q / RC
    let ax = max(c.x, 1e-5), ay = max(c.y, 1e-5)
    let F = pow(pow(ax, NC) + pow(ay, NC), 1 / NC)
    let k = pow(F, 1 - NC)
    let g = V2(pow(ax, NC - 1) * k, pow(ay, NC - 1) * k)
    let gl = max(len(g), 1e-5)
    return ((F - 1) * RC / gl, g / gl * sgn)
}

/// Glass finish over the body: specular rim (strongest facing the top-left light, a weaker
/// counter-glint bottom-right), a soft inner edge glow, a top sheen and a little bottom shading.
func finish(_ img: Img, rim: Float = 1, sheen: Float = 1) -> [Float] {
    var alpha = [Float](repeating: 0, count: S * S)
    let light = V2(-0.45, 0.89)
    img.p.withUnsafeMutableBufferPointer { buf in
        let b = buf
        alpha.withUnsafeMutableBufferPointer { abuf in
            let ab = abuf
            DispatchQueue.concurrentPerform(iterations: S) { j in
                for i in 0..<S {
                    let u = unit(i, j)
                    let (d, n) = bodySD(u)
                    let dpx = d * A                                   // px, negative inside
                    ab[j * S + i] = clamp01(0.5 - dpx)
                    if dpx > 1 { continue }
                    var c = b[j * S + i]
                    let inside = max(-dpx, 0)
                    let facing = dot2(n, light)                        // −1…1
                    // Thin specular rim (≈3 px) + wider soft band (≈18 px).
                    let thin = exp(-pow(inside / 2.6, 2))
                    let wide = exp(-inside / 16)
                    let spec = max(facing, 0) * 0.62 + max(-facing, 0) * 0.30 + 0.10
                    c = c + (V3(repeating: 1) - c) * clamp01(thin * spec * rim + wide * 0.07 * (0.4 + max(facing, 0)) * rim)
                    // Top sheen: a broad, very soft lift on the upper half.
                    let sh = smooth(-0.1, 0.95, u.y) * 0.075 * sheen
                    c = c + (V3(repeating: 1) - c) * sh
                    // Bottom edge: slight darkening for thickness.
                    c *= 1 - 0.12 * smooth(-0.55, -1.0, u.y) * exp(-inside / 40)
                    b[j * S + i] = c
                }
            }
        }
    }
    return alpha
}

/// Final 1024 PNG: body with the macOS-style drop shadow on a transparent canvas.
func compose(_ img: Img, _ alpha: [Float]) -> CGImage {
    let body = img.cgImage(alpha: alpha)
    let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let r = CGRect(x: 0, y: 0, width: S, height: S)
    // Ambient + contact shadow, as Apple's template (offset down, ~28 px blur, ~30 %).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.32))
    ctx.draw(body, in: r)
    ctx.restoreGState()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 4, color: CGColor(gray: 0, alpha: 0.18))
    ctx.draw(body, in: r)
    ctx.restoreGState()
    return ctx.makeImage()!
}

// MARK: - concept 1: Chrome Drop — a liquid-chrome sphere (the Liquid Chrome scene, reflected)

func chrome(_ dir: String) -> Img {
    let tex = Img.load(dir + "/chrome.png")
    let env = tex.blurred(30)
    let out = Img(S, S)
    let cen = V2(0, 0.03), R: Float = 0.58
    let L = norm(V3(-0.42, 0.62, 0.66)), H = norm(L + V3(0, 0, 1))
    out.shade { u, _, _ in
        // Backdrop: graphite, lit from the top, faintly tinted by the scene's own colours.
        var bg = mix(rgb(0x0a0b14), rgb(0x2a2f44), smooth(-1.1, 1.1, u.y))
        bg = bg * 0.80 + env.sample(texXY(V2(-u.x, u.y) * 0.9)) * 0.20 * (0.4 + 0.6 * smooth(-1, 1, u.y))
        bg += V3(0.9, 0.92, 1.0) * 0.05 * exp(-pow(len(u - V2(-0.3, 0.75)) / 0.7, 2))
        // Contact shadow + soft occlusion under the sphere.
        let sp = (u - V2(cen.x, cen.y - R * 0.93)) / V2(R * 0.95, R * 0.22)
        bg *= 1 - 0.62 * exp(-dot2(sp, sp) * 1.4)
        let ds = len(u - V2(cen.x, cen.y - 0.07))
        bg *= 1 - 0.45 * exp(-pow(max(ds - R * 0.92, 0) / 0.16, 2)) * smooth(R * 0.5, R, ds)
        let dist = len(u - cen)
        if dist > R + 2 * PX { return bg }
        let d = (u - cen) / R
        let r2 = min(dot2(d, d), 1), r = r2.squareRoot(), z = (1 - r2).squareRoot()
        let n = V3(d.x, d.y, z)
        // Reflection-style mapping: centre magnified, rim compressed.
        let k: Float = 0.80 / (0.36 + 0.64 * z)
        var c = tex.sample(V2(C + d.x * k * 470, C - d.y * k * 470))
        c = mix(c, V3(repeating: lum(c)), 0.12)                  // keep it metal, not paint
        // Body shading: darker toward the bottom edge, bright environment rim on top.
        c *= 1 - 0.55 * smooth(0.70, 1.0, r) * clamp01(0.55 - 0.65 * d.y)
        let fr = pow(1 - z, 3)
        c = mix(c, V3(0.86, 0.89, 0.97), fr * 0.45 * clamp01(0.6 + d.y))
        let rimLight = smooth(0.90, 1.0, r) * clamp01(0.35 + dot2(d / max(r, 1e-4), V2(-0.45, 0.89)))
        c += V3(repeating: rimLight * 0.35)
        // Specular: hard highlight + broad bloom.
        let nh = max(dot(n, H), 0)
        c += V3(repeating: pow(nh, 160) * 1.2 + pow(nh, 18) * 0.14)
        let cov = clamp01((R - dist) * A + 0.5)
        return mix(bg, c, cov)
    }
    return out
}

// MARK: - concept 2: Orbit — the Universe scene's sun, with two glass orbit rings

func orbit(_ dir: String) -> Img {
    let tex = Img.load(dir + "/universe.png")
    // Find the sun: centroid of the brightest pixels.
    var sx: Float = 0, sy: Float = 0, sw: Float = 0
    for j in stride(from: 0, to: tex.h, by: 2) { for i in stride(from: 0, to: tex.w, by: 2) {
        let l = lum(tex.p[j * tex.w + i]); if l > 0.92 { sx += Float(i); sy += Float(j); sw += 1 } } }
    let sun = sw > 0 ? V2(sx / sw, sy / sw) : V2(512, 480)
    let out = Img(S, S)
    let cen = V2(0, 0.02)
    let zoom: Float = 1.35                                  // sun magnification
    let theta: Float = -0.30                                // ring tilt (rad)
    let ct = cos(theta), st = sin(theta)
    let rings: [(a: Float, b: Float, w: Float)] = [(0.86, 0.33, 7.5), (0.56, 0.215, 6.0)]
    let planet = V2(0.86 * cos(-0.95), 0.33 * sin(-0.95))      // on the outer ring, front right
    let moon = V2(0.56 * cos(2.35), 0.215 * sin(2.35))         // inner ring, back left
    func toWorld(_ q: V2) -> V2 { V2(q.x * ct - q.y * st, q.x * st + q.y * ct) + cen }
    let P = toWorld(planet), M = toWorld(moon)
    out.shade { u, i, j in
        // Deep space.
        let rr = len(u - cen)
        var c = mix(rgb(0x11163a), rgb(0x020309), smooth(0.0, 1.35, rr))
        c += rgb(0x3a1d5c) * 0.18 * exp(-pow(len(u - V2(0.65, -0.7)) / 0.6, 2))
        // Stars: deterministic sparse field, small and sharp.
        let g: Float = 0.055
        let cell = (u / g).rounded(.down)
        let h1 = hash(Int32(cell.x), Int32(cell.y), 7)
        if h1 > 0.80 {
            let sp = (cell + V2(hash(Int32(cell.x), Int32(cell.y), 11), hash(Int32(cell.x), Int32(cell.y), 13)) * 0.8 + 0.1) * g
            let sd = len(u - sp) * A
            let b = pow(hash(Int32(cell.x), Int32(cell.y), 19), 3) * 0.9 + 0.15
            c += V3(0.85, 0.9, 1.0) * b * exp(-sd * sd / 1.6)
        }
        // The scene's sun, magnified, screened in.
        let q = sun + (u - cen) * A / zoom * V2(1, -1)
        let s = tex.sample(q)
        let fall = exp(-pow(rr / 0.5, 4))          // just the sun: keeps the scene's planets out
        c = V3(repeating: 1) - (V3(repeating: 1) - c) * (V3(repeating: 1) - s * fall * 1.15)
        c += rgb(0xffa040) * 0.10 * exp(-pow(rr / 0.45, 2))
        // Rings (local frame: x along the ring's major axis, y up; front = y < 0).
        let w = u - cen
        let l = V2(w.x * ct + w.y * st, -w.x * st + w.y * ct)
        let sunCore = smooth(0.17, 0.11, rr)
        for ring in rings {
            let gx = l.x / ring.a, gy = l.y / ring.b
            let gval = gx * gx + gy * gy - 1
            let grad = V2(2 * l.x / (ring.a * ring.a), 2 * l.y / (ring.b * ring.b))
            let dpx = abs(gval) / max(len(grad), 1e-4) * A
            let front = smooth(0.04, -0.04, l.y)
            let cov = clamp01(ring.w / 2 - dpx + 0.5)
            let glow = exp(-pow(dpx / (ring.w * 2.4), 2))
            var a = (0.40 + 0.55 * front) * (1 - sunCore * (1 - front))
            a *= 1
            let ringCol = mix(V3(0.62, 0.78, 1.0), V3(1.0, 0.96, 0.9), front * 0.5)
            c = mix(c, ringCol, cov * a)
            c += ringCol * glow * 0.10 * a
            // Specular glint along the top edge of the tube.
            let edge = clamp01(ring.w / 2 - abs(dpx - ring.w * 0.18) + 0.5) * 0.0
            c += V3(repeating: edge)
        }
        // Planets: glossy spheres lit from the sun.
        for (pc, pr, base, lit) in [(P, Float(0.085), rgb(0x2f7bff), Float(1.0)), (M, Float(0.045), rgb(0xffb46a), Float(0.8))] {
            let dd = len(u - pc)
            if dd < pr + 2 * PX {
                let d = (u - pc) / pr
                let z = max(1 - dot2(d, d), 0).squareRoot()
                let n = V3(d.x, d.y, z)
                let toSun = norm(V3(cen.x - pc.x, cen.y - pc.y, 0.55))
                let diff = max(dot(n, toSun), 0)
                var pcol = base * (0.10 + 1.05 * diff) * lit
                pcol += V3(0.6, 0.85, 1.0) * pow(1 - z, 3) * 0.55 * lit       // atmosphere rim
                pcol += V3(repeating: pow(max(dot(n, norm(toSun + V3(0, 0, 1))), 0), 60) * 0.7)
                let cv = clamp01((pr - dd) * A + 0.5)
                c = mix(c, pcol, cv)
            }
        }
        _ = (i, j)
        return c
    }
    return out
}

// MARK: - concept 3: Contour — topographic lines climbing to a single summit dot

func contour(_ dir: String) -> Img {
    // The Topography scene's colours (ink on paper, inverted: cream on near-black).
    let ink = rgb(0x0c0e11), paper = V3(0.93, 0.90, 0.82)
    let accent = rgb(0xff8a3c)
    let cen = V2(-0.02, 0.05)
    let levels: Float = 9
    func elev(_ p: V2) -> Float {
        let w = p - cen
        let r = len(w)
        let ang = atan2(w.y, w.x)
        let warp = fbm(p * 1.35 + V2(3.1, 7.7), 3) * 0.20 + fbm(p * 3.1 + V2(1.3, -4.2), 5) * 0.05
        let skew = 1 + 0.18 * cos(ang + 0.9)                 // steeper face toward the lower right
        return 1 - r * skew / 0.92 * (1 + warp * smooth(0.10, 0.55, r))
    }
    // Elevation field on the pixel grid (for analytic line width via the gradient).
    var E = [Float](repeating: 0, count: S * S)
    E.withUnsafeMutableBufferPointer { buf in
        let b = buf
        DispatchQueue.concurrentPerform(iterations: S) { j in for i in 0..<S { b[j * S + i] = elev(unit(i, j)) } }
    }
    let out = Img(S, S)
    let L = norm(V3(-0.5, 0.7, 0.9))
    out.shade { u, i, j in
        let e = E[j * S + i]
        let ex = (E[j * S + min(i + 1, S - 1)] - E[j * S + max(i - 1, 0)]) * 0.5
        let ey = (E[max(j - 1, 0) * S + i] - E[min(j + 1, S - 1) * S + i]) * 0.5
        let gpx = max((ex * ex + ey * ey).squareRoot(), 1e-6)          // elevation per px
        // Relief: elevation tint + hillshade (the scene's "Relief Shading").
        let n = norm(V3(-ex * 260, -ey * 260, 1))
        let shade = dot(n, L) - L.z
        var c = mix(ink, rgb(0x2a2a2c), smooth(-0.3, 1.0, e) * 0.85)
        c *= 1 + shade * 0.9
        // Contour lines: every level, the 3rd/6th as heavier index contours.
        let k = e * levels
        let nearest = k.rounded()
        let dpx = abs(k - nearest) / (gpx * levels)
        let isIndex = Int(nearest) % 3 == 0
        let width: Float = isIndex ? 5.4 : 3.0
        let fade = smooth(-1.9, 0.2, e)                                  // lines thin out into the corners
        let line = clamp01(width / 2 - dpx + 0.5) * (nearest < levels - 0.5 ? 1 : 0) * fade
        let lineCol = mix(paper * 0.78, paper, smooth(0, 1, e))
        c = mix(c, lineCol, line * (isIndex ? 1 : 0.86))
        // Summit: a solid dot with a soft warm glow.
        let topLevel = (levels - 1.55) / levels
        let dDot = (topLevel - e) / gpx                                  // px outside the dot edge
        let glow = exp(-max(dDot, 0) / 60) * 0.30
        c += accent * glow * smooth(-1, 0.4, e)
        // …a glossy bead: it casts a soft shadow down-right and catches the light top-left.
        let sh = (u - cen - V2(0.025, -0.045)) / 0.17
        c *= 1 - 0.45 * exp(-pow(max(len(sh) - 0.75, 0) / 0.25, 2)) * clamp01(dDot / 6)
        let dotCov = clamp01(0.5 - dDot)
        let dd = (u - cen) / 0.15
        let z = max(1 - dot2(dd, dd), 0).squareRoot()
        let nb = V3(dd.x, dd.y, z)
        let lb = norm(V3(-0.45, 0.65, 0.6))
        var dotCol = mix(rgb(0xff6a26), rgb(0xffc488), clamp01(0.5 + dd.y * 0.45 - dd.x * 0.2))
        dotCol *= 0.78 + 0.32 * max(dot(nb, lb), 0)
        dotCol += V3(1, 0.93, 0.85) * pow(max(dot(nb, norm(lb + V3(0, 0, 1))), 0), 40) * 0.75
        dotCol = mix(dotCol, rgb(0xffe0c0), pow(1 - z, 4) * 0.35)
        c = mix(c, dotCol, dotCov)
        return c
    }
    return out
}

// MARK: - concept 4: Lens — a Liquid Glass lens over a field of dots (Dot + Studio)

func lens(_ dir: String) -> Img {
    let tex = Img.load(dir + "/afterglow.png").blurred(10)
    let bgCol = rgb(0x120d24)
    let g: Float = 2 / 9.0                                         // dot pitch (9 across the body)
    func dots(_ q: V2, _ px: Float) -> V3 {
        let idx = (q / g + V2(0.5, 0.5)).rounded(.down)
        let cc = idx * g
        var col = tex.sample(texXY(cc))
        let l = lum(col)
        col = mix(V3(repeating: l), col, 1.35)                      // a touch more saturated
        col = col * (0.85 + 0.45 * l)
        let r = g * 0.5 * (0.22 + 0.62 * pow(l, 0.85))
        let dist = len(q - cc)
        let cov = clamp01((r - dist) / px + 0.5)
        // Each dot: a gentle top-left lift, like an emissive bead.
        let hl = clamp01(1 - len(q - cc - V2(-0.3, 0.35) * r) / r) * 0.22
        return mix(bgCol + col * 0.06, col + V3(repeating: hl), cov)
    }
    let out = Img(S, S)
    let Lc = V2(0.10, 0.10), RL: Float = 0.54
    let mag: Float = 1.6
    out.shade { u, _, _ in
        let w = u - Lc
        let dist = len(w)
        if dist > RL + 2 * PX {
            var c = dots(u, PX)
            // Lens shadow on the field, offset down.
            let ds = len(u - (Lc + V2(0.0, -0.06)))
            c *= 1 - 0.55 * exp(-pow(max(ds - RL * 0.94, 0) / 0.09, 2))
            return c
        }
        let rn = dist / RL
        // Refraction: magnified centre, the image bending hard in the last 20 % (Liquid Glass edge).
        // Flat magnifier in the middle; the outer ~14 % is the glass edge, squeezing the field back
        // to 1:1 at the rim (the Liquid Glass bend).
        let edgeT = pow(smooth(0.84, 1.0, rn), 1.4)
        var c = V3.zero
        for (ch, ca) in [(0, Float(-0.022)), (1, Float(0)), (2, Float(0.022))] {
            let s = mix(1 / mag, 1.0, edgeT) * (1 + ca * edgeT)
            let q = Lc + w * s
            let v = dots(q, PX * s)
            c[ch] = v[ch]
        }
        // Glass body: slight lift + cool tint, brighter toward the top.
        c = c * 0.94 + V3(0.10, 0.11, 0.16) * (0.5 + 0.5 * clamp01(w.y / RL + 0.5))
        // Rim: bright top-left specular arc, softer counter-glint bottom-right, thin outline.
        let dirn = w / max(dist, 1e-5)
        let facing = dot2(dirn, V2(-0.5, 0.86))
        let rimBand = exp(-pow((RL - dist) * A / 4.0, 2))
        let innerBand = exp(-max(RL - dist, 0) * A / 22)
        c += V3(repeating: rimBand * (0.30 + 0.55 * max(facing, 0) + 0.35 * max(-facing, 0)))
        c += V3(repeating: innerBand * 0.10 * (0.3 + max(facing, 0)))
        // Interior specular: a soft crescent near the top-left.
        let hp = (w - V2(-0.20, 0.25) * RL) / V2(RL * 0.55, RL * 0.32)
        c += V3(repeating: 0.10 * exp(-dot2(hp, hp) * 2.2) * smooth(0.3, 0.9, rn))
        let cov = clamp01((RL - dist) * A + 0.5)
        var outside = dots(u, PX)
        let ds = len(u - (Lc + V2(0.0, -0.06)))
        outside *= 1 - 0.55 * exp(-pow(max(ds - RL * 0.94, 0) / 0.09, 2))
        return mix(outside, c, cov)
    }
    return out
}

// MARK: - sizes

func resized(_ cg: CGImage, _ px: Int) -> CGImage {
    let ci = CIImage(cgImage: cg)
    let scale = CGFloat(px) / CGFloat(cg.width)
    let f = CIFilter(name: "CILanczosScaleTransform")!
    f.setValue(ci, forKey: kCIInputImageKey)
    f.setValue(scale, forKey: kCIInputScaleKey)
    f.setValue(1.0, forKey: kCIInputAspectRatioKey)
    var out = f.outputImage!
    // Small sizes: a light unsharp mask keeps the motif crisp.
    if px <= 64 {
        out = out.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 0.8, kCIInputIntensityKey: 0.35])
    }
    return ciContext.createCGImage(out, from: CGRect(x: 0, y: 0, width: px, height: px), format: .RGBA8, colorSpace: sRGB)!
}

let macSizes: [(pt: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
func iconName(_ s: (pt: Int, scale: Int)) -> String { "icon_\(s.pt)x\(s.pt)\(s.scale == 2 ? "@2x" : "").png" }

// MARK: - preview sheet (all concepts at 1024 / 128 / 32 / 16 on light + dark, and in a Dock mock)

/// The body outline as a CGPath (canvas px, y up), traced from the same continuous-corner shape.
func bodyPath(in r: CGRect) -> CGPath {
    let path = CGMutablePath()
    let half = r.width / 2, cx = r.midX, cy = r.midY
    func pt(_ x: Float, _ y: Float) -> CGPoint { CGPoint(x: cx + CGFloat(x) * half, y: cy + CGFloat(y) * half) }
    let quads: [(Float, Float)] = [(1, 1), (-1, 1), (-1, -1), (1, -1)]
    var first = true
    for (qi, q) in quads.enumerated() {
        // Corner arc from the edge leaving at angle 0 → 90° (rotated per quadrant, counter-clockwise).
        for k in 0...48 {
            let t = Float(k) / 48 * .pi / 2
            var a = pow(cos(t), 2 / NC), b = pow(sin(t), 2 / NC)
            if qi % 2 == 1 { swap(&a, &b) }
            let x = q.0 * ((1 - RC) + RC * a), y = q.1 * ((1 - RC) + RC * b)
            if first { path.move(to: pt(x, y)); first = false } else { path.addLine(to: pt(x, y)) }
        }
    }
    path.closeSubpath()
    return path
}

func loadCG(_ path: String) -> CGImage {
    guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(s, 0, nil) else { fatalError("can't read \(path)") }
    return cg
}

/// A generic stand-in app icon for the Dock mock: gradient body + an SF Symbol glyph.
func mockIcon(_ symbol: String, _ top: NSColor, _ bottom: NSColor, _ glyph: NSColor) -> CGImage {
    let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.32))
    ctx.addPath(bodyPath(in: body)); ctx.setFillColor(bottom.cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bodyPath(in: body)); ctx.clip()
    let g = CGGradient(colorsSpace: sRGB, colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()
    let cfg = NSImage.SymbolConfiguration(pointSize: 400, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [glyph]))
    if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let sz = img.size, k = min(440 / sz.width, 440 / sz.height)
        let w = sz.width * k, h = sz.height * k
        img.draw(in: NSRect(x: 512 - w / 2, y: 512 - h / 2, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
    }
    return ctx.makeImage()!
}

func preview(_ out: String, _ dir: String, _ names: [String]) {
    let icons = names.map { loadCG(dir + "/\($0).png") }
    let titles = ["chrome": "Chrome Drop", "orbit": "Orbit", "contour": "Contour", "lens": "Glass Lens"]
    let gut: CGFloat = 80, col: CGFloat = 1024
    let Wd = Int(CGFloat(icons.count) * col + CGFloat(icons.count + 1) * gut)
    let headH: CGFloat = 200, bigH: CGFloat = 1104, stripH: CGFloat = 380, dockH: CGFloat = 420
    let Ht = Int(headH + bigH + 2 * stripH + 2 * dockH + gut)
    let ctx = CGContext(data: nil, width: Wd, height: Ht, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .none
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    func fill(_ r: CGRect, _ c: NSColor) { ctx.setFillColor(c.cgColor); ctx.fill(r) }
    func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ c: NSColor, _ w: NSFont.Weight = .semibold) {
        NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: w), .foregroundColor: c])
            .draw(at: NSPoint(x: x, y: y))
    }
    let H = CGFloat(Ht)
    fill(CGRect(x: 0, y: 0, width: Wd, height: Ht), NSColor(white: 0.92, alpha: 1))
    text("DotStudio — icon concepts", gut, H - 130, 72, NSColor(white: 0.1, alpha: 1), .bold)
    var y = H - headH - bigH
    for (k, icon) in icons.enumerated() {
        let x = gut + CGFloat(k) * (col + gut)
        text(titles[names[k]] ?? names[k], x + 40, y + bigH - 70, 52, NSColor(white: 0.2, alpha: 1))
        ctx.interpolationQuality = .high
        ctx.draw(icon, in: CGRect(x: x, y: y, width: col, height: col))
    }
    // Small sizes, at true pixel size plus an 8× pixel-zoom of the 16 px, on light and dark.
    let small = icons.map { (resized($0, 128), resized($0, 32), resized($0, 16)) }
    for (dark, bg, fg) in [(false, NSColor(white: 0.97, alpha: 1), NSColor(white: 0.35, alpha: 1)),
                           (true, NSColor(white: 0.12, alpha: 1), NSColor(white: 0.7, alpha: 1))] {
        y -= stripH
        fill(CGRect(x: 0, y: y, width: CGFloat(Wd), height: stripH), bg)
        text(dark ? "dark" : "light", 16, y + stripH - 44, 28, fg)
        for (k, s) in small.enumerated() {
            let x = gut + CGFloat(k) * (col + gut)
            let base = y + 110
            ctx.interpolationQuality = .none
            ctx.draw(s.0, in: CGRect(x: x, y: base, width: 128, height: 128))
            ctx.draw(s.1, in: CGRect(x: x + 180, y: base, width: 32, height: 32))
            ctx.draw(s.2, in: CGRect(x: x + 260, y: base, width: 16, height: 16))
            ctx.draw(s.1, in: CGRect(x: x + 330, y: base, width: 256, height: 256))      // 32 px ×8
            ctx.draw(s.2, in: CGRect(x: x + 640, y: base, width: 256, height: 256))      // 16 px ×16
            for (lbl, lx) in [("128", x), ("32", x + 180), ("16", x + 260), ("32 ×8", x + 330), ("16 ×16", x + 640)] {
                text(lbl, lx, base - 50, 26, fg, .regular)
            }
        }
    }
    // Dock mocks: each concept between generic stand-ins, at 64 pt @2x, on a light and a dark desktop.
    let mocks = [mockIcon("folder.fill", NSColor(red: 0.62, green: 0.84, blue: 1, alpha: 1), NSColor(red: 0.22, green: 0.55, blue: 0.98, alpha: 1), .white),
                 mockIcon("message.fill", NSColor(red: 0.45, green: 0.95, blue: 0.5, alpha: 1), NSColor(red: 0.1, green: 0.72, blue: 0.25, alpha: 1), .white),
                 mockIcon("music.note", NSColor(red: 1, green: 0.45, blue: 0.55, alpha: 1), NSColor(red: 0.95, green: 0.18, blue: 0.32, alpha: 1), .white),
                 mockIcon("gearshape.fill", NSColor(white: 0.78, alpha: 1), NSColor(white: 0.48, alpha: 1), NSColor(white: 0.2, alpha: 1))]
        .map { resized($0, 128) }
    for dark in [false, true] {
        y -= dockH
        let top = dark ? NSColor(red: 0.10, green: 0.11, blue: 0.20, alpha: 1) : NSColor(red: 0.78, green: 0.86, blue: 0.98, alpha: 1)
        let bot = dark ? NSColor(red: 0.20, green: 0.10, blue: 0.22, alpha: 1) : NSColor(red: 0.98, green: 0.86, blue: 0.80, alpha: 1)
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: y, width: CGFloat(Wd), height: dockH))
        let g = CGGradient(colorsSpace: sRGB, colors: [top.cgColor, bot.cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: y + dockH), end: CGPoint(x: CGFloat(Wd), y: y), options: [])
        ctx.restoreGState()
        for k in icons.indices {
            let x0 = gut + CGFloat(k) * (col + gut)
            let row = [mocks[0], mocks[1], small[k].0, mocks[2], mocks[3]]
            let pad: CGFloat = 14, step: CGFloat = 128 + 8
            let dw = CGFloat(row.count) * step - 8 + 2 * pad
            let dx = x0 + (col - dw) / 2, dy = y + 120
            let dock = CGPath(roundedRect: CGRect(x: dx, y: dy, width: dw, height: 128 + 2 * pad), cornerWidth: 44, cornerHeight: 44, transform: nil)
            ctx.addPath(dock)
            ctx.setFillColor(dark ? NSColor(white: 0.16, alpha: 0.55).cgColor : NSColor(white: 1, alpha: 0.45).cgColor)
            ctx.fillPath()
            ctx.addPath(dock)
            ctx.setStrokeColor(NSColor(white: 1, alpha: dark ? 0.18 : 0.6).cgColor); ctx.setLineWidth(2); ctx.strokePath()
            ctx.interpolationQuality = .none
            for (n, ic) in row.enumerated() {
                ctx.draw(ic, in: CGRect(x: dx + pad + CGFloat(n) * step, y: dy + pad, width: 128, height: 128))
            }
            // Running-app dot under the concept.
            ctx.setFillColor(NSColor(white: dark ? 0.9 : 0.15, alpha: 0.8).cgColor)
            ctx.fillEllipse(in: CGRect(x: dx + pad + 2 * step + 64 - 5, y: dy + 2, width: 10, height: 10))
        }
        text(dark ? "Dock — dark" : "Dock — light", 16, y + dockH - 44, 28, dark ? NSColor(white: 0.8, alpha: 1) : NSColor(white: 0.25, alpha: 1))
    }
    writePNG(ctx.makeImage()!, out)
    print("wrote \(out)")
}

// MARK: - main

let argv = CommandLine.arguments
let concepts = ["chrome", "orbit", "contour", "lens"]
func usage() -> Never {
    print("usage: icon render <chrome|orbit|contour|lens> <renderDir> <out.png> | icon sizes <in.png> <appiconset> | icon iconset <in.png> <dir>")
    exit(2)
}
guard argv.count >= 4 else { usage() }
switch argv[1] {
case "render":
    guard argv.count >= 5 else { usage() }
    let dir = argv[3]
    // "all" renders every concept into the directory argv[4] as <concept>.png.
    let jobs = argv[2] == "all" ? concepts.map { ($0, argv[4] + "/\($0).png") } : [(argv[2], argv[4])]
    for (concept, outPath) in jobs {
        let img: Img
        switch concept {
        case "chrome": img = chrome(dir)
        case "orbit": img = orbit(dir)
        case "contour": img = contour(dir)
        case "lens": img = lens(dir)
        default: usage()
        }
        let alpha = finish(img)
        writePNG(compose(img, alpha), outPath)
        print("wrote \(outPath)")
    }
case "sizes", "iconset":
    guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: argv[2]) as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(s, 0, nil) else { fatalError() }
    for size in macSizes {
        let px = size.pt * size.scale
        writePNG(px == cg.width ? cg : resized(cg, px), argv[3] + "/" + iconName(size))
    }
    print("wrote \(macSizes.count) sizes to \(argv[3])")
case "preview":
    // icon preview <out.png> <dir holding chrome.png, orbit.png, …> [concept …]
    preview(argv[2], argv[3], argv.count > 4 ? Array(argv[4...]) : concepts)
default: usage()
}
