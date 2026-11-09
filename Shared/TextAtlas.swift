//  TextAtlas.swift — signed-distance-field atlas of real system typefaces for the Clocks pack.
//
//  The macOS system families are rasterised with CoreText and turned into exact signed
//  distance fields (Felzenszwalb EDT seeded with anti-aliased coverage), so numerals stay
//  razor sharp at any size, from a 60 px date line to a 1500 px clock face at 5K, and the
//  shaders get bevels, soft shadows and glows from the same field for free.
//
//  Texture (r16Unorm, bound at fragment slot 6 only while a Clocks scene is drawing). Faces:
//      0 = SF Pro Light   1 = SF Pro Bold   2 = New York   3 = SF Pro Rounded Medium
//  Only the faces a scene draws with are built (`faces(for:)`), one plane each, stacked
//  vertically; a plane holds every glyph cell, packed in rows of variable-width cells:
//      glyphs  0–10   "0123456789:"                     big cells (bigH texels tall)
//      glyphs 11–36   A–Z, 37–46 0–9, 47–53 , . ’ · - / &    small cells
//      glyphs 54–79   a–z                               small cells
//  The last two texel rows are metrics, as 2×2 quads read with one gather (quad q covers
//  columns 2q, 2q+1; gather order x = bottom-left, y = bottom-right, z = top-right, w = top-left):
//      quad g        (cellX, cellY, cellW, originX)       texels, cellY inside a plane
//      quad 128 + g  advance of each face (0, 1, 2, 3)    caps × 8192
//      quad 255      plane top row of each face           a face that isn't built points at one that is
//  In every cell the baseline sits at `baseFrac` of the cell height from its top and caps are
//  `capFrac` of the cell height tall (each face is sized to that cap height). A texel's value
//  v encodes distance d (cell heights, positive outside) as v = 0.5 − d / (2·spreadFrac).
//  These constants are mirrored in Scenes/Clocks_funcs.h.
//
//  Memory: one plane is ~6 MB; a screensaver showing one clock holds one or two. The build
//  works through a few glyphs at a time in mmap'd scratch that goes straight back to the
//  system (malloc kept ~300 MB of freed large blocks dirty after the old all-cores build).

import Metal
import AppKit
import CoreText

enum TextAtlas {
    static let width = 4096
    static let bigH = 512
    static let smallH = 128
    static let spreadFrac: CGFloat = 0.125
    static let capFrac: CGFloat = 0.5
    static let baseFrac: CGFloat = 0.72
    static let advScale: CGFloat = 8192            // advances are stored in caps × advScale
    static let allFaces: UInt8 = 0b1111

    static let bigGlyphs = Array("0123456789:")
    static let smallGlyphs = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789,.\u{2019}\u{00B7}-/&abcdefghijklmnopqrstuvwxyz")

    /// Shader ids of the scenes that read the atlas (the Clocks pack).
    private static let users: Set<Int32> = Set(SceneCatalog.clocks.values.map { $0.shaderID })

    // Per GPU (keyed by registryID): a texture only belongs to its own device, and on a
    // multi-GPU Mac (Mac Pro, eGPU) a wallpaper may draw on the GPU driving its display
    // while previews use the default one. On a one-GPU Mac there is exactly one entry.
    // The lock guards the tables only, never a build, so a caller whose faces are already
    // there never waits. A caller that needs a face the atlas lacks rebuilds it with the
    // union of faces (a few tens of ms), or waits for the rebuild already in progress.
    private static let cond = NSCondition()
    private static var cached: [UInt64: (faces: UInt8, tex: MTLTexture)] = [:]
    private static var failed: Set<UInt64> = []
    private static var building: Set<UInt64> = []

    /// The atlas for the scene in `u` (built on first use, then shared), else nil.
    static func texture(_ device: MTLDevice, uniforms u: FXUniforms) -> MTLTexture? {
        guard users.contains(u.effect) else { return nil }
        return texture(device, faces: faces(for: u))
    }

    /// The atlas with every face, when `effect` needs it.
    static func texture(_ device: MTLDevice, effect: Int32) -> MTLTexture? {
        guard users.contains(effect) else { return nil }
        return texture(device, faces: allFaces)
    }

    private static func texture(_ device: MTLDevice, faces need: UInt8) -> MTLTexture? {
        let key = device.registryID
        cond.lock()
        while true {
            if let c = cached[key], c.faces & need == need { cond.unlock(); return c.tex }
            if failed.contains(key) { cond.unlock(); return nil }
            if !building.contains(key) { break }
            cond.wait()
        }
        let old = cached[key]
        let faces = need | (old?.faces ?? 0)
        building.insert(key)
        cond.unlock()

        let t = build(device: device, faces: faces, reuse: old)

        cond.lock()
        building.remove(key)
        if let t { cached[key] = (faces, t) } else { failed.insert(key) }
        cond.broadcast()
        cond.unlock()
        return t
    }

    /// The faces the scene in `u` sets type in (bit f = face f). Mirrors clocks_face() and the
    /// typeface choices in Scenes/Clocks_cases.h — keep the two in step. (A face missing here
    /// isn't fatal: the shader then draws with a face that is built.)
    static func faces(for u: FXUniforms) -> UInt8 {
        func menu(_ v: Float) -> Int { Int((v + 0.5).rounded(.down)) }
        func face(_ sel: Int, _ w: Float) -> UInt8 {
            switch sel {
            case 1: return 1 << 2                                    // New York
            case 2: return 1 << 3                                    // Rounded
            case 3: return 1 << 1                                    // Bold
            default: return min(max(w, 0), 1) < 0.5 ? 1 << 0 : 1 << 1   // Light, or thinned Bold
            }
        }
        switch u.effect {
        case 50:                                                     // Type Clock: time + date
            let sel = menu(u.p0.y)
            return face(sel, u.p0.z) | face(sel, u.p0.z + 0.3)
        case 51:                                                     // Flip Clock
            switch menu(u.p0.x) {
            case 1: return 1 << 2
            case 2: return 1 << 3
            default: return 1 << 1
            }
        case 52:                                                     // Word Clock
            return face(menu(u.p0.x), u.p0.y)
        case 53:                                                     // Window Light
            switch menu(u.p0.x) {
            case 1: return 1 << 0
            case 2: return 1 << 3
            default: return 1 << 2
            }
        default:
            return allFaces
        }
    }

    // MARK: - Build

    private struct Cell { var x = 0, y = 0, w = 0, h = 0, originX = 0 }

    private static func faceFonts(capPx: CGFloat) -> [CTFont] {
        func sized(_ make: (CGFloat) -> NSFont) -> CTFont {
            let probe = make(100) as CTFont
            let cap = max(CTFontGetCapHeight(probe), 1)
            return make(100 * capPx / cap) as CTFont
        }
        func design(_ d: NSFontDescriptor.SystemDesign, _ w: NSFont.Weight) -> (CGFloat) -> NSFont {
            { size in
                let base = NSFont.systemFont(ofSize: size, weight: w)
                guard let desc = base.fontDescriptor.withDesign(d) else { return base }
                return NSFont(descriptor: desc, size: size) ?? base
            }
        }
        return [
            sized { NSFont.systemFont(ofSize: $0, weight: .light) },
            sized { NSFont.systemFont(ofSize: $0, weight: .bold) },
            sized(design(.serif, .regular)),
            sized(design(.rounded, .medium)),
        ]
    }

    private static func glyph(_ font: CTFont, _ ch: Character) -> CGGlyph {
        var units = Array(String(ch).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count)
        return glyphs[0]
    }

    /// Anonymous memory that goes back to the system the moment it's released (malloc keeps
    /// big freed blocks dirty in its cache, which is what used to pin ~300 MB after a build).
    private final class Scratch {
        let base: UnsafeMutableRawPointer
        let size: Int
        init?(bytes: Int) {
            let n = max(bytes, 1)
            guard let p = mmap(nil, n, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
                  p != MAP_FAILED else { return nil }
            base = p; size = n
        }
        deinit { munmap(base, size) }
    }

    /// Builds the atlas with the faces in `mask`; planes already in `reuse` (an atlas this
    /// build replaces — same layout) are copied rather than recomputed.
    static func build(device: MTLDevice, faces mask: UInt8,
                      reuse: (faces: UInt8, tex: MTLTexture)? = nil) -> MTLTexture? {
        let planes = (0..<4).filter { mask & (1 << $0) != 0 }
        guard !planes.isEmpty else { return nil }
        let groups: [(chars: [Character], h: Int)] = [(bigGlyphs, bigH), (smallGlyphs, smallH)]
        let fontSets = groups.map { faceFonts(capPx: CGFloat($0.h) * capFrac) }

        // Pack: cells sized to the widest face's ink/advance plus the SDF spread on each side
        // (every face, so the layout never depends on which faces are built).
        var cells: [Cell] = []
        var advances: [[CGFloat]] = []            // [glyph][face] in texels
        var glyphIDs: [[CGGlyph]] = []
        var chars: [Character] = []
        var groupOf: [Int] = []
        var x = 0, y = 0, rowH = 0
        for (gi, group) in groups.enumerated() {
            let pad = Int((CGFloat(group.h) * spreadFrac).rounded(.up)) + 2
            if x > 0 { x = 0; y += rowH; rowH = 0 }
            for ch in group.chars {
                var left: CGFloat = 0, right: CGFloat = 0
                var adv: [CGFloat] = [], ids: [CGGlyph] = []
                for f in fontSets[gi] {
                    var g = glyph(f, ch)
                    var r = CGRect.zero, a = CGSize.zero
                    CTFontGetBoundingRectsForGlyphs(f, .horizontal, &g, &r, 1)
                    CTFontGetAdvancesForGlyphs(f, .horizontal, &g, &a, 1)
                    left = min(left, r.minX); right = max(right, max(r.maxX, a.width))
                    adv.append(a.width); ids.append(g)
                }
                let w = Int((right - left).rounded(.up)) + 2 * pad
                if x + w > width { x = 0; y += rowH; rowH = 0 }
                cells.append(Cell(x: x, y: y, w: w, h: group.h, originX: pad + Int((-left).rounded(.up))))
                advances.append(adv); glyphIDs.append(ids); chars.append(ch); groupOf.append(gi)
                x += w; rowH = max(rowH, group.h)
            }
        }
        let planeH = y + rowH
        let height = planes.count * planeH + 2
        let n = cells.count

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Unorm,
                                                            width: width, height: height, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.label = "Clocks text atlas"

        // Distance fields, one job per (plane, glyph): render the glyph supersampled into
        // scratch, run the EDT there, filter back down to texels (kills the stair-step error a
        // 1× coverage-seeded EDT leaves along edges — visible in lit bevels). A few workers
        // pull jobs in turn, each reusing one scratch sized for the biggest cell.
        func ssOf(_ c: Cell) -> Int { c.h >= bigH ? 3 : 2 }
        var maxPix = 0, maxCell = 0, maxLen = 0
        for c in cells {
            let ss = ssOf(c)
            maxPix = max(maxPix, c.w * ss * c.h * ss)
            maxCell = max(maxCell, c.w * c.h)
            maxLen = max(maxLen, max(c.w, c.h) * ss)
        }
        // Planes the old atlas already has: copy them across (a few ms) instead of rebuilding.
        var todo = Array(planes.indices)
        if let reuse, reuse.tex.width == width, reuse.tex.pixelFormat == .r16Unorm,
           let rows = Scratch(bytes: width * planeH * 2) {
            let oldPlanes = (0..<4).filter { reuse.faces & (1 << $0) != 0 }
            if reuse.tex.height == oldPlanes.count * planeH + 2 {
                todo = []
                for (pi, face) in planes.enumerated() {
                    guard let oi = oldPlanes.firstIndex(of: face) else { todo.append(pi); continue }
                    reuse.tex.getBytes(rows.base, bytesPerRow: width * 2,
                                       from: MTLRegionMake2D(0, oi * planeH, width, planeH), mipmapLevel: 0)
                    tex.replace(region: MTLRegionMake2D(0, pi * planeH, width, planeH), mipmapLevel: 0,
                                withBytes: rows.base, bytesPerRow: width * 2)
                }
            }
        }
        let jobs = todo.count * n
        let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 6, jobs))
        let lock = NSLock()
        var nextJob = 0
        var ok = true
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            let coverBytes = maxPix, distBytes = maxPix * 4, sumBytes = maxCell * 4, outBytes = maxCell * 2
            let lineBytes = (maxLen + 1) * 4 * 2 + maxLen * MemoryLayout<Int>.stride
            guard let scratch = Scratch(bytes: coverBytes + distBytes + sumBytes + outBytes + lineBytes + 64) else {
                lock.lock(); ok = false; lock.unlock(); return
            }
            let raw = scratch.base
            let cover = raw.bindMemory(to: UInt8.self, capacity: coverBytes)
            let dist = (raw + coverBytes).bindMemory(to: Float.self, capacity: maxPix)
            let sum = (raw + coverBytes + distBytes).bindMemory(to: Float.self, capacity: maxCell)
            let out = (raw + coverBytes + distBytes + sumBytes).bindMemory(to: UInt16.self, capacity: maxCell)
            let lineBase = raw + coverBytes + distBytes + sumBytes + outBytes
            let f = lineBase.bindMemory(to: Float.self, capacity: maxLen + 1)
            let z = (lineBase + (maxLen + 1) * 4).bindMemory(to: Float.self, capacity: maxLen + 1)
            let v = (lineBase + (maxLen + 1) * 8).alignedUp(for: Int.self).bindMemory(to: Int.self, capacity: maxLen)
            while true {
                lock.lock(); let job = nextJob; nextJob += 1; lock.unlock()
                if job >= jobs { break }
                let pi = todo[job / n], gi = job % n  // big glyphs (the slow ones) go first
                let face = planes[pi]
                let c = cells[gi]
                let ss = ssOf(c)
                let W = c.w * ss, H = c.h * ss
                memset(cover, 0, W * H)
                let font = fontSets[groupOf[gi]][face]
                var g = glyphIDs[gi][face]
                if let ctx = CGContext(data: cover, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W,
                                       space: CGColorSpaceCreateDeviceGray(),
                                       bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                    ctx.setAllowsAntialiasing(true); ctx.setShouldAntialias(true)
                    ctx.setAllowsFontSmoothing(false); ctx.setShouldSmoothFonts(false)
                    ctx.setAllowsFontSubpixelPositioning(true); ctx.setShouldSubpixelPositionFonts(true)
                    ctx.setFillColor(gray: 1, alpha: 1)
                    ctx.scaleBy(x: CGFloat(ss), y: CGFloat(ss))
                    // Time colons sit centred on the figures' cap height, not on the x-height.
                    var lift: CGFloat = 0
                    if chars[gi] == ":" {
                        var r = CGRect.zero
                        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &g, &r, 1)
                        lift = CGFloat(c.h) * capFrac / 2 - r.midY
                    }
                    var p = CGPoint(x: CGFloat(c.originX), y: CGFloat(c.h) * (1 - baseFrac) + lift)
                    CTFontDrawGlyphs(font, &g, &p, 1, ctx)
                }
                sdfCell(cover, cell: c, ss: ss, spread: Float(spreadFrac) * Float(c.h),
                        dist: dist, sum: sum, out: out, f: f, z: z, v: v)
                lock.lock()
                tex.replace(region: MTLRegionMake2D(c.x, pi * planeH + c.y, c.w, c.h), mipmapLevel: 0,
                            withBytes: out, bytesPerRow: c.w * 2)
                lock.unlock()
            }
        }
        guard ok else { return nil }

        // Metrics: two rows of 2×2 quads (see the header).
        var metrics = [UInt16](repeating: 0, count: width * 2)
        func quad(_ q: Int, _ v: [Int]) {
            let c = 2 * q, top = 0, bottom = width
            metrics[bottom + c] = UInt16(clamping: v[0]); metrics[bottom + c + 1] = UInt16(clamping: v[1])
            metrics[top + c + 1] = UInt16(clamping: v[2]); metrics[top + c] = UInt16(clamping: v[3])
        }
        for g in 0..<n {
            let c = cells[g]
            quad(g, [c.x, c.y, c.w, c.originX])
            let tpc = CGFloat(c.h) * capFrac
            quad(128 + g, advances[g].map { Int(($0 / tpc * advScale).rounded()) })
        }
        quad(255, (0..<4).map { face in (planes.firstIndex(of: face) ?? 0) * planeH })
        metrics.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, height - 2, width, 2), mipmapLevel: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: width * 2)
        }
        malloc_zone_pressure_relief(nil, 0)       // CoreGraphics' small buffers, back to the system
        return tex
    }

    /// TinySDF-style signed distance for one cell rendered at `ss`× into `src` (W×H = cell·ss):
    /// the anti-aliased coverage seeds sub-pixel edge offsets, an exact 2D squared EDT runs for
    /// the outside, then the inside (reusing `dist`), and each texel takes a tent-weighted mean
    /// of the hi-res distances around it (2 texels wide: smooths the faint ripple a box filter
    /// left along curves, which lit bevels and glass picked out).
    private static func sdfCell(_ src: UnsafePointer<UInt8>, cell c: Cell, ss: Int, spread: Float,
                                dist: UnsafeMutablePointer<Float>, sum: UnsafeMutablePointer<Float>,
                                out: UnsafeMutablePointer<UInt16>, f: UnsafeMutablePointer<Float>,
                                z: UnsafeMutablePointer<Float>, v: UnsafeMutablePointer<Int>) {
        let w = c.w * ss, h = c.h * ss, count = w * h
        let inf: Float = 1e20
        for i in 0..<(c.w * c.h) { sum[i] = 0 }
        // Filter weights along one axis for hi-res pixel (texel·ss − ss + k), o = offset of its
        // centre from the texel centre; they sum to ss² per axis. Big cells (the clock faces,
        // lit and refracted) take a tent ss − |o|; small cells (dates, letters) keep a box over
        // the texel's own pixels, which holds their corners crisper.
        let taps = 3 * ss
        var tw = [Float](repeating: 0, count: taps)
        for k in 0..<taps {
            let o = Float(k - ss) + 0.5 - Float(ss) * 0.5
            tw[k] = c.h >= bigH ? max(Float(ss) - abs(o), 0) : (abs(o) < Float(ss) * 0.5 ? Float(ss) : 0)
        }
        let k0 = tw.firstIndex { $0 > 0 } ?? 0, k1 = (tw.lastIndex { $0 > 0 } ?? taps - 1) + 1
        for pass in 0..<2 {
            let outside = pass == 0
            for i in 0..<count {
                let a = Float(src[i]) / 255
                if a >= 1 { dist[i] = outside ? 0 : inf }
                else if a <= 0 { dist[i] = outside ? inf : 0 }
                else {
                    let d = 0.5 - a
                    dist[i] = outside ? (d > 0 ? d * d : 0) : (d < 0 ? d * d : 0)
                }
            }
            edt(dist, w, h, f, z, v)
            for i in 0..<count { dist[i] = dist[i].squareRoot() }
            let norm = (outside ? 1 : -1) / Float(ss * ss * ss * ss * ss)   // Σweights ss⁴; hi-res px → texels
            for ty in 0..<c.h {
                for tx in 0..<c.w {
                    var acc: Float = 0
                    for ky in k0..<k1 {
                        let row = min(max(ty * ss - ss + ky, 0), h - 1) * w
                        var accRow: Float = 0
                        for kx in k0..<k1 {
                            accRow += dist[row + min(max(tx * ss - ss + kx, 0), w - 1)] * tw[kx]
                        }
                        acc += accRow * tw[ky]
                    }
                    sum[ty * c.w + tx] += acc * norm
                }
            }
        }
        for i in 0..<(c.w * c.h) {
            let val = min(max(0.5 - sum[i] / (2 * spread), 0), 1)    // sum: texels, + outside
            out[i] = UInt16(val * 65535 + 0.5)
        }
    }

    private static func edt(_ g: UnsafeMutablePointer<Float>, _ w: Int, _ h: Int,
                            _ f: UnsafeMutablePointer<Float>, _ z: UnsafeMutablePointer<Float>,
                            _ v: UnsafeMutablePointer<Int>) {
        for x in 0..<w { edt1d(g, x, w, h, f, z, v) }
        for y in 0..<h { edt1d(g, y * w, 1, w, f, z, v) }
    }

    /// Felzenszwalb–Huttenlocher 1D squared distance transform, in place along a strided line.
    private static func edt1d(_ g: UnsafeMutablePointer<Float>, _ offset: Int, _ stride: Int, _ n: Int,
                              _ f: UnsafeMutablePointer<Float>, _ z: UnsafeMutablePointer<Float>,
                              _ v: UnsafeMutablePointer<Int>) {
        let inf: Float = 1e20
        v[0] = 0; z[0] = -inf; z[1] = inf
        f[0] = g[offset]
        var k = 0
        if n > 1 {
            for q in 1..<n {
                f[q] = g[offset + q * stride]
                let qf = Float(q), fq = f[q] + qf * qf
                var r = v[k]
                var s = (fq - f[r] - Float(r * r)) / (2 * qf - 2 * Float(r))
                while s <= z[k] {                       // z[0] = -inf stops this at k = 0
                    k -= 1
                    r = v[k]
                    s = (fq - f[r] - Float(r * r)) / (2 * qf - 2 * Float(r))
                }
                k += 1; v[k] = q; z[k] = s; z[k + 1] = inf
            }
        }
        k = 0
        for q in 0..<n {
            let qf = Float(q)
            while z[k + 1] < qf { k += 1 }
            let r = v[k], dq = qf - Float(r)
            g[offset + q * stride] = dq * dq + f[r]
        }
    }
}

private extension UnsafeMutableRawPointer {
    func alignedUp<T>(for: T.Type) -> UnsafeMutableRawPointer {
        let a = MemoryLayout<T>.alignment
        return UnsafeMutableRawPointer(bitPattern: (Int(bitPattern: self) + a - 1) & ~(a - 1))!
    }
}
