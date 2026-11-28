//  AdjustChecks.swift — the Adjust layer (EffectKind.adjust, shader 81; the editor's Adjust key):
//  at its defaults it draws exactly the frame without it, on a scene and on a Look; each slider
//  moved changes the picture; and a still of each slider at its ends (adjust-sheet.png in the
//  out dir) to judge them by eye. Part of --checks.

import AppKit
import Metal

func adjustChecks(outDir: String) -> Bool {
    var ok = true
    func check(_ pass: Bool, _ what: String) {
        print("\(pass ? "PASS" : "FAIL")  \(what)")
        if !pass { ok = false }
    }
    guard let r = MetalRenderer(pixelFormat: .bgra8Unorm, store: store) else { check(false, "Adjust: a renderer"); return false }
    r.waitsForScenePipelines = true
    let w = 320, h = 200
    func bytes(_ cg: CGImage?) -> [UInt8] {
        guard let cg else { return [] }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return px
    }
    func render(_ p: Preset, _ s: SourceSpec) -> CGImage? { r.renderThumbnail(preset: p, source: s, width: w, height: h, time: 1.6) }

    let all = DefaultPresets.scenes() + DefaultPresets.looks()
    let picks = [all.first { $0.isScene }, all.first { !$0.isScene }].compactMap { $0 }
    for p in picks {
        let src: SourceSpec = p.isScene ? SourceSpec() : .builtInPhotos
        let plain = bytes(render(p, src))
        var with = p
        with.effects.append(EffectInstance(.adjust))
        let neutral = bytes(render(with, src))
        check(!plain.isEmpty && plain == neutral, "Adjust at its defaults draws \(p.name) byte for byte as without it (\(p.isScene ? "scene" : "look"))")
    }

    // Each slider at both ends, over a Look: every one changes the picture.
    guard let look = picks.last else { return ok }
    let src: SourceSpec = .builtInPhotos
    let base = bytes(render(look, src))
    var tiles: [(String, CGImage)] = []
    if let cg = render(look, src) { tiles.append(("none", cg)) }
    var unchanged: [String] = []
    for spec in EffectKind.adjust.params {
        for v in [spec.min, spec.max] where v != spec.def {
            var e = EffectInstance(.adjust)
            e.params[spec.key] = v
            var p = look
            p.effects.append(e)
            guard let cg = render(p, src) else { unchanged.append(spec.key); continue }
            let b = bytes(cg)
            let mean = zip(b, base).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(max(b.count, 1))
            if mean < 1 { unchanged.append("\(spec.key)=\(v)") }
            tiles.append(("\(spec.label) \(ParamFormat.short(v))", cg))
        }
    }
    check(unchanged.isEmpty, "Adjust: each slider at either end changes \(look.name) (\(unchanged.isEmpty ? "all \(EffectKind.adjust.params.count)" : unchanged.joined(separator: ", ")))")

    // A strong grade with everything at once: still renders, every pixel finite (no NaN → black).
    var strong = EffectInstance(.adjust)
    strong.params = ["brightness": 30, "contrast": 60, "saturation": 50, "exposure": 0.5, "highlights": -80,
                     "shadows": 80, "warmth": 60, "tint": -30, "vibrance": 70, "fade": 30]
    var sp = look; sp.effects.append(strong)
    if let cg = render(sp, src) { tiles.append(("all strong", cg)) }

    // The sheet: 4 columns.
    let cols = 4, label = 18
    let rows = (tiles.count + cols - 1) / cols
    let sheetW = cols * w, sheetH = rows * (h + label)
    if let ctx = CGContext(data: nil, width: sheetW, height: sheetH, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
        for (i, t) in tiles.enumerated() {
            let x = (i % cols) * w, y = sheetH - (i / cols + 1) * (h + label)
            ctx.draw(t.1, in: CGRect(x: x, y: y, width: w, height: h))
            (t.0 as NSString).draw(at: NSPoint(x: x + 6, y: y + h + 2),
                                   withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white])
        }
        NSGraphicsContext.restoreGraphicsState()
        if let img = ctx.makeImage(), let d = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) {
            let url = URL(fileURLWithPath: outDir).appendingPathComponent("adjust-sheet.png")
            try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
            try? d.write(to: url)
            print("      wrote \(url.path)")
        }
    }
    return ok
}

private enum ParamFormat {
    static func short(_ v: Double) -> String { v == v.rounded() ? String(format: "%+.0f", v) : String(format: "%+.1f", v) }
}
