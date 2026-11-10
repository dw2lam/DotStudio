//  Bounce.swift — BOUNCE (Retro pack, shader id 74): the classic bouncing-logo screensaver.
//  A logo glides diagonally, bounces off the screen's edges, takes a new colour at every
//  bounce, and every few minutes lands exactly in a corner.
//
//  Motion is a pure function of t (saver, wallpaper, preview and thumbnails agree; the
//  wall-clock time base works): each axis is a triangle wave over the free room (screen − logo).
//  The two axes' periods are chosen with a rational ratio p : q (gcd 1), so the logo is in a
//  corner exactly at t = tc + k·L, L = p·Ty = q·Tx — about every 2½ minutes at the default
//  speed — and never in between. (The x speed differs from the y speed by at most a few percent
//  to make the ratio exact; the eye reads it as the same diagonal.)
//
//  The CPU works out the frame (BounceLogo.prepare, from MetalRenderer.encodePasses): the logo's
//  rectangle, its tint, the corner flourish and the trail's ghosts go in FXUniforms.scene; the
//  logo itself is a small mipmapped texture bound at fragment slot 6 (the scene-data slot), built
//  once per logo (BounceLogo's cache) — the built-in DotStudio mark (a chrome drop + wordmark),
//  the user's word (CoreText), or the user's image file from the shared media folder (which the
//  sandboxed saver can read). Shader: Retro_funcs.h (retro_bounce) + Retro_cases.h (case 74).
//
//  FXUniforms.scene for 74:
//    [0] (centre x, centre y, half width, half height)   px, y down
//    [1] (tint rgb (display sRGB), colour mode)          mode: 0 shift, 1 rainbow, 2 fixed, 3 original
//    [2] (luma lo, luma hi (< 0: one-tone logo), card corner radius px (0 = drawn bare), mip level)
//    [3] (hit corner x, y px, seconds since that corner hit, flourish 0…1)
//    [4] (rainbow hue (turns), ghost count, the texture's clear margin in uv (x, y))
//    [5 + 2k], [6 + 2k]  ghost k (oldest last): (centre x, y, weight, rainbow hue), (tint rgb, 0)

import Foundation
import Metal
import AppKit
import CoreText
import ImageIO
import simd

/// Which logo Bounce draws (EffectInstance.logoKind; nil = .builtIn).
enum BounceLogoKind: String, Codable, CaseIterable {
    case builtIn, text, image

    /// A kind from a newer build decodes as the built-in mark instead of failing the library.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BounceLogoKind(rawValue: raw) ?? .builtIn
    }
}

enum BounceLogo {
    // MARK: Motion

    /// Corner-to-corner time at speed 1, roughly (the exact period depends on the screen and
    /// the logo; `timing` prints the same for any t).
    static let cornerSeconds = 150.0
    /// Speed 1 in screen heights a second.
    static let speedScale = 0.11
    /// The first corner after t = 0 comes this far into a period (an instance-time preview,
    /// or a screensaver that just started, waits about a minute for it).
    static let firstCorner = 0.45

    /// The shift-on-bounce palette (display sRGB), visited 3 steps at a time so neighbours differ.
    static let palette: [SIMD3<Float>] = [
        SIMD3(1.00, 0.27, 0.30), SIMD3(1.00, 0.58, 0.16), SIMD3(1.00, 0.88, 0.22), SIMD3(0.36, 0.95, 0.40),
        SIMD3(0.20, 0.88, 0.98), SIMD3(0.32, 0.50, 1.00), SIMD3(0.68, 0.40, 1.00), SIMD3(1.00, 0.38, 0.80),
    ]

    struct Timing: Equatable {
        var lw = 0.0, lh = 0.0          // logo size, px
        var rx = 0.0, ry = 0.0          // free room on each axis, px
        var tx = 0.0, ty = 0.0          // seconds per wall-to-wall crossing
        var period = 0.0                // seconds between corner hits (p·ty = q·tx)
        var p = 1, q = 1                // y and x crossings per period
        var tc = 0.0                    // a corner hit
    }

    /// Logo size and the axes' periods on a W×H screen (aspect = the logo's width / height).
    static func timing(width W: Double, height H: Double, aspect: Double, size: Double, speed: Double) -> Timing {
        var m = Timing()
        let s = max(size, 0.02) * H
        let a = max(aspect, 0.05)
        var lw = s * a.squareRoot(), lh = s / a.squareRoot()
        let k = min(1, 0.8 * W / lw, 0.8 * H / lh)
        lw *= k; lh *= k
        m.lw = lw; m.lh = lh
        m.rx = max(W - lw, 1); m.ry = max(H - lh, 1)
        let ty1 = m.ry / (speedScale * H)               // a crossing at speed 1
        let r = m.rx / m.ry
        func qFor(_ p: Int) -> Int { max(Int((Double(p) / r).rounded()), 1) }
        func gcd(_ a: Int, _ b: Int) -> Int { var a = a, b = b; while b != 0 { (a, b) = (b, a % b) }; return a }
        let target = max(Int((cornerSeconds / ty1).rounded()), 2)
        var p = target
        for d in 0..<64 {                                // the nearest count with gcd(p, q) = 1
            if gcd(target + d, qFor(target + d)) == 1 { p = target + d; break }
            if target - d >= 2, gcd(target - d, qFor(target - d)) == 1 { p = target - d; break }
        }
        let q = qFor(p)
        let sp = max(speed, 0.01)
        m.p = p; m.q = q
        m.ty = ty1 / sp
        m.tx = m.ty * Double(p) / Double(q)
        m.period = Double(p) * m.ty
        m.tc = firstCorner * m.period
        return m
    }

    struct Pose {
        var center = SIMD2<Double>(0, 0)   // px, y down
        var bounces = 0                    // wall hits since the reference corner (any sign)
    }

    /// Where the logo is at t.
    static func pose(_ m: Timing, at t: Double) -> Pose {
        let fx = (t - m.tc) / m.tx, fy = (t - m.tc) / m.ty
        let nx = fx.rounded(.down), ny = fy.rounded(.down)
        func tri(_ f: Double, _ n: Double) -> Double {
            let fr = f - n
            return Int(n).isMultiple(of: 2) ? fr : 1 - fr
        }
        return Pose(center: SIMD2(m.lw / 2 + m.rx * tri(fx, nx), m.lh / 2 + m.ry * tri(fy, ny)),
                    bounces: Int(nx) + Int(ny))
    }

    /// The latest corner hit at or before t: its time and screen corner (px).
    static func lastCorner(_ m: Timing, at t: Double, width W: Double, height H: Double) -> (time: Double, corner: SIMD2<Double>) {
        // (t is a Float on its way here: a frame a hair before the hit still counts as it)
        let k = ((t - m.tc + 0.002) / m.period).rounded(.down)
        let ki = Int(k)
        let right = !(ki * m.q).isMultiple(of: 2), bottom = !(ki * m.p).isMultiple(of: 2)
        return (m.tc + k * m.period, SIMD2(right ? W : 0, bottom ? H : 0))
    }

    static func shiftColor(_ bounces: Int) -> SIMD3<Float> {
        let n = palette.count
        return palette[((bounces * 3) % n + n) % n]
    }

    /// Fills u.scene for this frame (u.p0 = speed, size, colour mode, flourish; u.p1.x = trail)
    /// and returns the logo texture (slot 6). nil: no logo could be made (nothing to draw).
    static func prepare(_ u: inout FXUniforms, inst: EffectInstance, mediaDir: URL, device: MTLDevice) -> MTLTexture? {
        guard let e = entry(for: inst, mediaDir: mediaDir, device: device) else { return nil }
        let W = Double(u.resolution.x), H = Double(u.resolution.y)
        guard W > 0, H > 0 else { return nil }
        let speed = Double(u.p0.x), mode = Int((u.p0.z + 0.5).rounded(.down))
        let flourishOn = u.p0.w > 0.5, trail = Double(min(max(u.p1.x, 0), 1))
        let m = timing(width: W, height: H, aspect: e.aspect, size: Double(u.p0.y), speed: speed)
        let t = Double(u.time)
        let fixed = SIMD3<Float>(u.colorB.x, u.colorB.y, u.colorB.z)
        func tint(_ b: Int) -> SIMD3<Float> {
            switch mode {
            case 0: return shiftColor(b)
            case 2: return fixed
            default: return SIMD3(1, 1, 1)               // rainbow: the shader's hue; original: the image
            }
        }
        func hue(_ t: Double) -> Float { Float((t * 0.045).truncatingRemainder(dividingBy: 1)) }
        let now = pose(m, at: t)
        u.scene.0 = SIMD4(Float(now.center.x), Float(now.center.y), Float(m.lw / 2), Float(m.lh / 2))
        let c = tint(now.bounces)
        u.scene.1 = SIMD4(c.x, c.y, c.z, Float(mode))
        let lod = max(log2(Double(e.height) / max(m.lh, 1)), 0)
        u.scene.2 = SIMD4(e.lumLo, e.lumHi, e.card ? Float(0.07 * min(m.lw, m.lh)) : 0, Float(lod))
        let hit = lastCorner(m, at: t, width: W, height: H)
        let since = t - hit.time
        let flash: Float = flourishOn && since < 3 ? 1 : 0
        u.scene.3 = SIMD4(Float(hit.corner.x), Float(hit.corner.y), Float(since), flash)
        // the trail: up to 4 faint ghosts, ~two thirds of a logo height apart at any speed
        let ghosts = trail > 0.01 ? 4 : 0
        u.scene.4 = SIMD4(hue(t), Float(ghosts), e.inset.x, e.inset.y)
        let dt = 0.6 / max(speed, 0.05)
        withUnsafeMutableBytes(of: &u.scene) { raw in
            let s = raw.bindMemory(to: SIMD4<Float>.self)
            for k in 0..<4 {
                guard k < ghosts else { s[5 + 2 * k] = .zero; s[6 + 2 * k] = .zero; continue }
                let tg = t - Double(k + 1) * dt
                let g = pose(m, at: tg)
                let w = Float(trail * 0.3 * (1 - Double(k + 1) / 5))
                let gc = tint(g.bounces)
                s[5 + 2 * k] = SIMD4(Float(g.center.x), Float(g.center.y), w, hue(tg))
                s[6 + 2 * k] = SIMD4(gc.x, gc.y, gc.z, 0)
            }
        }
        return e.tex
    }

    // MARK: Logo textures

    /// One logo, ready to draw.
    final class Entry {
        let tex: MTLTexture
        let aspect: Double          // width / height of the (trimmed) logo
        let height: Int             // texels the logo is tall (without the margin)
        let inset: SIMD2<Float>     // the clear margin round it, in texture uv
        let lumLo: Float, lumHi: Float   // luma spread of its opaque pixels (lumHi < 0: one tone)
        let card: Bool              // an opaque image: drawn as a rounded card
        init(tex: MTLTexture, aspect: Double, height: Int, inset: SIMD2<Float>, lumLo: Float, lumHi: Float, card: Bool) {
            self.tex = tex; self.aspect = aspect; self.height = height; self.inset = inset
            self.lumLo = lumLo; self.lumHi = lumHi; self.card = card
        }
    }

    private struct Key: Hashable {
        let device: UInt64
        let kind: BounceLogoKind
        let text: String
        let file: String
    }

    private static let lock = NSLock()
    private static var cache: [Key: Entry] = [:]
    private static var order: [Key] = []
    private static var last: (key: Key, entry: Entry)?
    private static var queues: [UInt64: MTLCommandQueue] = [:]

    /// Frees every logo texture (the screensaver's teardown).
    static func purge() {
        lock.lock(); defer { lock.unlock() }
        cache = [:]; order = []; last = nil; queues = [:]
    }

    /// The logo `inst` asks for — built on first use (a few ms; an image decodes once), then
    /// shared by every renderer on the device. Frames after the first are a lookup: no
    /// allocation, no file access. A logo that can't be made (a missing or unreadable file, an
    /// empty word) is the built-in mark, remembered under its own key so it isn't retried.
    static func entry(for inst: EffectInstance, mediaDir: URL, device: MTLDevice) -> Entry? {
        let kind = inst.logoKind ?? .builtIn
        let key = Key(device: device.registryID, kind: kind,
                      text: kind == .text ? (inst.logoText ?? "") : "",
                      file: kind == .image ? (inst.logoFile ?? "") : "")
        lock.lock()
        if let l = last, l.key == key { lock.unlock(); return l.entry }
        if let e = cache[key] { last = (key, e); lock.unlock(); return e }
        lock.unlock()

        let img = makeImage(kind: kind, text: key.text, file: key.file, mediaDir: mediaDir)
            ?? (kind == .builtIn ? nil : makeImage(kind: .builtIn, text: "", file: "", mediaDir: mediaDir))
        guard let img, let e = upload(img, device: device) else { return nil }

        lock.lock(); defer { lock.unlock() }
        cache[key] = e
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > 6 { cache[order.removeFirst()] = nil }
        last = (key, e)
        return e
    }

    /// The logo as a CGImage (nil: this one can't be made).
    static func makeImage(kind: BounceLogoKind, text: String, file: String, mediaDir: URL) -> CGImage? {
        switch kind {
        case .builtIn: return builtInMark()
        case .text:
            let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return word.isEmpty ? nil : wordImage(String(word.prefix(48)))
        case .image:
            return fileURL(file, mediaDir: mediaDir).flatMap(loadImage)
        }
    }

    /// The Image logo's file: a plain name inside the media folder (a shared or hand-edited
    /// library can't point it anywhere else); nil for none.
    static func fileURL(_ file: String?, mediaDir: URL) -> URL? {
        guard let file else { return nil }
        let name = (file as NSString).lastPathComponent
        guard !name.isEmpty, !name.hasPrefix("."), name == file else { return nil }
        return mediaDir.appendingPathComponent(name)
    }

    // MARK: Building

    private static let maxSide = 2048
    private static var sRGB: CGColorSpace { CGColorSpace(name: CGColorSpace.sRGB)! }

    private static func context(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: sRGB,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// An image file: bitmaps through ImageIO (≤ 2048 px a side, EXIF orientation applied);
    /// vector files (PDF, SVG) and anything ImageIO can't read through NSImage, drawn at 2048.
    static func loadImage(_ url: URL) -> CGImage? {
        let ext = url.pathExtension.lowercased()
        if ext != "pdf", ext != "svg", let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           CGImageSourceGetCount(src) > 0 {
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: maxSide,
                                         kCGImageSourceShouldCacheImmediately: true]
            if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) { return cg }
        }
        guard let ns = NSImage(contentsOf: url), ns.size.width > 0, ns.size.height > 0 else { return nil }
        let k = Double(maxSide) / Double(max(ns.size.width, ns.size.height))
        let w = max(Int((ns.size.width * k).rounded()), 1), h = max(Int((ns.size.height * k).rounded()), 1)
        guard let ctx = context(w, h) else { return nil }
        let prev = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ns.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.current = prev
        return ctx.makeImage()
    }

    /// A line of type, white on clear: the Text logo.
    static func wordImage(_ word: String, capHeight: CGFloat = 240) -> CGImage? {
        let probe = NSFont.systemFont(ofSize: 100, weight: .heavy)
        var size = 100 * capHeight / max(probe.capHeight, 1)
        func line(_ size: CGFloat) -> CTLine {
            let font = NSFont.systemFont(ofSize: size, weight: .heavy)
            let attr = NSAttributedString(string: word, attributes: [
                .font: font, .kern: -0.012 * size,
                .foregroundColor: NSColor.white])
            return CTLineCreateWithAttributedString(attr)
        }
        var ln = line(size)
        var b = CTLineGetBoundsWithOptions(ln, .useGlyphPathBounds)
        let maxW: CGFloat = 4000
        if b.width > maxW {                                   // a long word: smaller type, same texture cap
            size *= maxW / b.width
            ln = line(size); b = CTLineGetBoundsWithOptions(ln, .useGlyphPathBounds)
        }
        let pad: CGFloat = 8
        let w = Int(ceil(b.width + 2 * pad)), h = Int(ceil(b.height + 2 * pad))
        guard w > 2 * Int(pad), h > 2 * Int(pad), let ctx = context(w, h) else { return nil }
        ctx.setShouldSmoothFonts(false)
        ctx.textPosition = CGPoint(x: pad - b.minX, y: pad - b.minY)
        CTLineDraw(ln, ctx)
        return ctx.makeImage()
    }

    /// The built-in DotStudio mark: the app icon's Chrome Drop (a liquid-chrome sphere, drawn
    /// here per pixel against a soft studio) beside the "DotStudio" wordmark, white on clear.
    /// No artwork ships for it, and nothing is anyone else's.
    static func builtInMark() -> CGImage? {
        let D = 400                                         // sphere diameter, px
        let cap: CGFloat = 0.50 * CGFloat(D)
        let font = NSFont.systemFont(ofSize: 100 * cap / max(NSFont.systemFont(ofSize: 100, weight: .bold).capHeight, 1),
                                     weight: .bold)
        let attr = NSAttributedString(string: "DotStudio", attributes: [
            .font: font, .kern: -0.02 * font.pointSize, .foregroundColor: NSColor.white])
        let ln = CTLineCreateWithAttributedString(attr)
        let b = CTLineGetBoundsWithOptions(ln, .useGlyphPathBounds)
        let gap = Int(0.24 * Double(D)), pad = 6
        let w = pad + D + gap + Int(ceil(b.width)) + pad, h = pad + D + pad
        guard let ctx = context(w, h), let data = ctx.data else { return nil }
        // The sphere, straight into the buffer (row 0 = the top).
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        let R = Double(D) / 2, cx = Double(pad) + R, cy = Double(pad) + R
        let L = simd_normalize(SIMD3<Double>(-0.45, 0.62, 0.64))
        let Hh = simd_normalize(L + SIMD3(0, 0, 1))
        func env(_ r: SIMD3<Double>) -> SIMD3<Double> {
            // liquid chrome: soft warped bands of a bright studio, lighter overhead, a dark floor,
            // and the icon's lilac and mint sheens
            let w = sin(2.1 * r.y - 1.1 * r.x + 0.8) + 0.5 * sin(2.9 * r.x + 1.4 * r.y - 0.4)
            let band = 0.5 + 0.5 * sin(2.3 * r.x + 1.7 * r.y + 1.3 * w)
            let e = min(max((band - 0.1) / 0.8, 0), 1)
            var v = 0.40 + 0.52 * e * e * (3 - 2 * e)
            v = min(max(v + 0.18 * max(r.y, 0) - 0.42 * pow(max(-r.y, 0), 0.8), 0.04), 1)
            var c = SIMD3<Double>(repeating: v)
            let lilac = exp(-pow((band - 0.55) / 0.2, 2)) * (0.5 + 0.5 * sin(1.7 * w + 2))
            let mint = exp(-pow((band - 0.3) / 0.16, 2)) * (0.5 - 0.5 * sin(1.7 * w + 2))
            c = simd_mix(c, SIMD3(0.80, 0.68, 0.98) * v * 1.1, SIMD3(repeating: 0.7 * lilac))
            c = simd_mix(c, SIMD3(0.62, 0.94, 0.84) * v * 1.1, SIMD3(repeating: 0.55 * mint))
            return c
        }
        for j in 0..<h {
            for i in 0..<w where i < pad + D + 2 {
                let dx = (Double(i) + 0.5 - cx) / R, dy = (cy - (Double(j) + 0.5)) / R
                let d2 = dx * dx + dy * dy
                let cov = min(max((1 - d2.squareRoot()) * R + 0.5, 0), 1)
                guard cov > 0 else { continue }
                let z = max(1 - min(d2, 1), 0).squareRoot()
                let n = SIMD3(dx, dy, z)
                let r = 2 * n.z * n - SIMD3(0, 0, 1)
                var c = env(r)
                c *= 1 - 0.5 * pow(max(-dy, 0), 2) * (1 - z)              // darker toward the bottom rim
                let fr = pow(1 - z, 3)
                c = simd_mix(c, SIMD3(0.88, 0.90, 0.98), SIMD3(repeating: fr * 0.35 * min(max(0.6 + dy, 0), 1)))
                let nh = max(simd_dot(n, Hh), 0)
                c += SIMD3(repeating: pow(nh, 150) * 1.1 + pow(nh, 16) * 0.12)
                c = simd_clamp(c, .zero, SIMD3(repeating: 1))
                let o = (j * w + i) * 4
                px[o] = UInt8((c.x * cov * 255).rounded())
                px[o + 1] = UInt8((c.y * cov * 255).rounded())
                px[o + 2] = UInt8((c.z * cov * 255).rounded())
                px[o + 3] = UInt8((cov * 255).rounded())
            }
        }
        ctx.setShouldSmoothFonts(false)
        // the wordmark's caps centred on the sphere (CG's y is up)
        let capH = font.capHeight
        ctx.textPosition = CGPoint(x: CGFloat(pad + D + gap) - b.minX, y: CGFloat(pad) + CGFloat(R) - capH / 2)
        CTLineDraw(ln, ctx)
        return ctx.makeImage()
    }

    /// Trims a logo to what shows, measures it, and uploads it (mipmapped, premultiplied RGBA8,
    /// display sRGB values — sampled as they are, like every other scene's colours).
    ///  • Transparent (≥ 0.5 % of the pixels below full alpha): cropped to the alpha bounding
    ///    box (alpha ≥ 10/255), so it bounces off its visible edges; drawn bare.
    ///  • Opaque: drawn whole, as a rounded card.
    ///  • Luma spread of its solid pixels (5th–95th percentile): under 0.18 it is one tone
    ///    (a white or black logo), tinted flat; else the tint keeps its shading.
    ///  • Uploaded inside a clear margin (Entry.inset) for the flourish's glow.
    static func upload(_ img: CGImage, device: MTLDevice) -> Entry? {
        let W = img.width, H = img.height
        guard W > 0, H > 0, let ctx = context(W, H), let data = ctx.data else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
        let px = data.bindMemory(to: UInt8.self, capacity: W * H * 4)
        let hasAlpha: Bool = {
            switch img.alphaInfo {
            case .none, .noneSkipFirst, .noneSkipLast: return false
            default: return true
            }
        }()
        var see = 0
        var minX = W, minY = H, maxX = -1, maxY = -1
        var hist = [Int](repeating: 0, count: 64)
        var solid = 0
        for j in 0..<H {
            for i in 0..<W {
                let o = (j * W + i) * 4
                let a = Int(px[o + 3])
                if a < 250 { see += 1 }
                if a >= 10 {
                    if i < minX { minX = i }; if i > maxX { maxX = i }
                    if j < minY { minY = j }; if j > maxY { maxY = j }
                }
                if a >= 128 {
                    let k = 1.0 / Double(a)
                    let l = (0.2126 * Double(px[o]) + 0.7152 * Double(px[o + 1]) + 0.0722 * Double(px[o + 2])) * k
                    hist[min(Int(l * 64), 63)] += 1
                    solid += 1
                }
            }
        }
        let transparent = hasAlpha && Double(see) > 0.005 * Double(W * H)
        guard maxX >= minX, maxY >= minY else { return nil }       // nothing visible
        var crop = (x: 0, y: 0, w: W, h: H)
        if transparent {
            let pad = 2
            let x0 = max(minX - pad, 0), y0 = max(minY - pad, 0)
            crop = (x0, y0, min(maxX + pad, W - 1) - x0 + 1, min(maxY + pad, H - 1) - y0 + 1)
        }
        func percentile(_ f: Double) -> Float {
            let target = Int(Double(solid) * f)
            var acc = 0
            for (i, n) in hist.enumerated() { acc += n; if acc > target { return (Float(i) + 0.5) / 64 } }
            return 1
        }
        var lo: Float = 0, hi: Float = 1
        if solid > 0 { lo = percentile(0.05); hi = percentile(0.95) }
        if hi - lo < 0.18 { hi = -1 }                               // one tone: tint it flat

        // A clear margin round the logo (a quarter of its shorter side): room for the corner
        // flourish's glow, which samples the blurry mips just outside the logo.
        let mg = Int(0.25 * Double(min(crop.w, crop.h))) + 4
        let tw = crop.w + 2 * mg, th = crop.h + 2 * mg
        var padded = [UInt8](repeating: 0, count: tw * th * 4)
        padded.withUnsafeMutableBytes { dst in
            for j in 0..<crop.h {
                memcpy(dst.baseAddress! + ((j + mg) * tw + mg) * 4, px + ((crop.y + j) * W + crop.x) * 4, crop.w * 4)
            }
        }
        let levels = Int(log2(Double(max(tw, th)))) + 1
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: tw, height: th,
                                                         mipmapped: true)
        d.mipmapLevelCount = levels
        d.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, tw, th), mipmapLevel: 0, withBytes: padded, bytesPerRow: tw * 4)
        if levels > 1, let q = queue(device), let cmd = q.makeCommandBuffer(), let bl = cmd.makeBlitCommandEncoder() {
            bl.generateMipmaps(for: tex)
            bl.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
        }
        return Entry(tex: tex, aspect: Double(crop.w) / Double(crop.h), height: crop.h,
                     inset: SIMD2(Float(mg) / Float(tw), Float(mg) / Float(th)),
                     lumLo: lo, lumHi: hi, card: !transparent)
    }

    private static func queue(_ device: MTLDevice) -> MTLCommandQueue? {
        lock.lock(); defer { lock.unlock() }
        if let q = queues[device.registryID] { return q }
        let q = device.makeCommandQueue()
        queues[device.registryID] = q
        return q
    }
}
