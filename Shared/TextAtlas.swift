//  TextAtlas.swift — signed-distance-field atlas of real system typefaces for the Clocks pack.
//
//  The macOS system families are rasterised with CoreText and turned into exact signed
//  distance fields (Felzenszwalb EDT seeded with anti-aliased coverage), so numerals stay
//  razor sharp at any size, from a 60 px date line to a 1500 px clock face at 5K, and the
//  shaders get bevels, soft shadows and glows from the same field for free.
//
//  Texture (rgba16Unorm, bound at fragment slot 6 only while a Clocks scene is drawing):
//    one typeface per channel   R = SF Pro Light   G = SF Pro Bold
//                               B = New York       A = SF Pro Rounded Medium
//    glyph cells, packed in rows of variable-width cells:
//      glyphs  0–10   "0123456789:"                     big cells (bigH texels tall)
//      glyphs 11–36   A–Z, 37–46 0–9, 47–53 , . ’ · - / &    small cells
//      glyphs 54–79   a–z                               small cells
//    the last three texel rows are metrics, one texel per glyph g:
//      row H-3: (cellX, cellY, cellW, cellH)             integers / 65535
//      row H-2: (originX, 0, 0, 0)                       pen origin inside the cell, texels
//      row H-1: advance of each typeface (RGBA)          in 1/8 texels / 65535
//  In every cell the baseline sits at `baseFrac` of the cell height from its top and caps are
//  `capFrac` of the cell height tall (each face is sized to that cap height). A texel's value
//  v encodes distance d (cell heights, positive outside) as v = 0.5 − d / (2·spreadFrac).
//  These constants are mirrored in Scenes/Clocks_funcs.h.

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

    static let bigGlyphs = Array("0123456789:")
    static let smallGlyphs = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789,.\u{2019}\u{00B7}-/&abcdefghijklmnopqrstuvwxyz")

    /// Shader ids of the scenes that read the atlas (the Clocks pack).
    private static let users: Set<Int32> = Set(SceneCatalog.clocks.values.map { $0.shaderID })

    private static let lock = NSLock()
    private static var cached: MTLTexture?
    private static var failed = false

    /// The atlas when `effect` needs it (built on first use, ~0.1 s, then shared), else nil.
    static func texture(_ device: MTLDevice, effect: Int32) -> MTLTexture? {
        guard users.contains(effect) else { return nil }
        lock.lock(); defer { lock.unlock() }
        if cached == nil && !failed {
            cached = build(device: device)
            failed = (cached == nil)
        }
        return cached
    }

    // MARK: - Build

    private struct Cell { var x = 0, y = 0, w = 0, h = 0, originX = 0 }

    private static func faces(capPx: CGFloat) -> [CTFont] {
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

    static func build(device: MTLDevice) -> MTLTexture? {
        let groups: [(chars: [Character], h: Int)] = [(bigGlyphs, bigH), (smallGlyphs, smallH)]
        let fontSets = groups.map { faces(capPx: CGFloat($0.h) * capFrac) }

        // Pack: cells sized to the widest face's ink/advance plus the SDF spread on each side.
        var cells: [Cell] = []
        var advances: [[CGFloat]] = []            // [glyph][face] in texels
        var glyphIDs: [[CGGlyph]] = []
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
                advances.append(adv); glyphIDs.append(ids)
                x += w; rowH = max(rowH, group.h)
            }
        }
        let metricsY = y + rowH
        let height = metricsY + 3

        // Distance fields, one job per (face, glyph): render the glyph supersampled into its own
        // bitmap, run the EDT there, box-filter back down to texels (kills the stair-step error
        // a 1× coverage-seeded EDT leaves along edges — visible in lit bevels).
        let n = cells.count
        var chars: [Character] = []
        var groupOf: [Int] = []
        for (k, group) in groups.enumerated() { chars += group.chars; groupOf += Array(repeating: k, count: group.chars.count) }
        var texels = [UInt16](repeating: 0, count: width * height * 4)
        texels.withUnsafeMutableBufferPointer { out in
            let outPtr = out.baseAddress!
            DispatchQueue.concurrentPerform(iterations: 4 * n) { job in
                let face = job / n, gi = job % n
                let c = cells[gi]
                let font = fontSets[groupOf[gi]][face]
                var g = glyphIDs[gi][face]
                let ss = c.h >= bigH ? 3 : 2
                let W = c.w * ss, H = c.h * ss
                var buf = [UInt8](repeating: 0, count: W * H)
                buf.withUnsafeMutableBytes { raw in
                    guard let ctx = CGContext(data: raw.baseAddress, width: W, height: H,
                                              bitsPerComponent: 8, bytesPerRow: W,
                                              space: CGColorSpaceCreateDeviceGray(),
                                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
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
                let spread = Float(spreadFrac) * Float(c.h)
                buf.withUnsafeBufferPointer { src in
                    sdfCell(src.baseAddress!, cell: c, ss: ss, spread: spread, face: face, out: outPtr)
                }
            }
        }

        // Metrics rows.
        func put(_ px: Int, _ row: Int, _ v: [Int]) {
            for ch in 0..<4 { texels[(row * width + px) * 4 + ch] = UInt16(clamping: v[ch]) }
        }
        for g in 0..<n {
            let c = cells[g]
            put(g, metricsY, [c.x, c.y, c.w, c.h])
            put(g, metricsY + 1, [c.originX, 0, 0, 0])
            put(g, metricsY + 2, advances[g].map { Int(($0 * 8).rounded()) })
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Unorm,
                                                            width: width, height: height, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        texels.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: width * 8)
        }
        tex.label = "Clocks text atlas"
        return tex
    }

    /// TinySDF-style signed distance for one cell rendered at `ss`× into `src` (W×H = cell·ss):
    /// the anti-aliased coverage seeds sub-pixel edge offsets, an exact 2D squared EDT runs for
    /// the outside and the inside, then each texel averages its ss×ss block.
    private static func sdfCell(_ src: UnsafePointer<UInt8>, cell c: Cell, ss: Int, spread: Float,
                                face: Int, out: UnsafeMutablePointer<UInt16>) {
        let w = c.w * ss, h = c.h * ss, count = w * h
        let inf: Float = 1e20
        let outer = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let inner = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let len = max(w, h)
        let f = UnsafeMutablePointer<Float>.allocate(capacity: len)
        let z = UnsafeMutablePointer<Float>.allocate(capacity: len + 1)
        let v = UnsafeMutablePointer<Int>.allocate(capacity: len)
        defer { outer.deallocate(); inner.deallocate(); f.deallocate(); z.deallocate(); v.deallocate() }

        for i in 0..<count {
            let a = Float(src[i]) / 255
            if a >= 1 { outer[i] = 0; inner[i] = inf }
            else if a <= 0 { outer[i] = inf; inner[i] = 0 }
            else {
                let d = 0.5 - a
                outer[i] = d > 0 ? d * d : 0
                inner[i] = d < 0 ? d * d : 0
            }
        }
        edt(outer, w, h, f, z, v)
        edt(inner, w, h, f, z, v)
        let norm = 1 / Float(ss * ss * ss)                    // average, and hi-res px → texels
        for yy in 0..<c.h {
            let orow = out + ((c.y + yy) * width + c.x) * 4 + face
            for xx in 0..<c.w {
                var sum: Float = 0
                for sy in 0..<ss {
                    let row = (yy * ss + sy) * w + xx * ss
                    for sx in 0..<ss { sum += outer[row + sx].squareRoot() - inner[row + sx].squareRoot() }
                }
                let d = sum * norm                             // texels, + outside
                let val = min(max(0.5 - d / (2 * spread), 0), 1)
                orow[xx * 4] = UInt16(val * 65535 + 0.5)
            }
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
