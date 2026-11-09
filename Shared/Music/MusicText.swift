//  MusicText.swift — CoreText type for the music overlay: system font (SF Pro, with the
//  system cascade for CJK, emoji and accents), wrapped into lines and rendered to a bitmap
//  at the display's native scale with a soft shadow. The system font picks its optical size
//  from the point size by itself: SF Pro Display for the big titles (20 pt and up), SF Pro
//  Text for the small lines.
//
//  Song text is never cut off (owner, 2026-11-09: "corner mode the text shouldn't cut off").
//  `fit` sets a line of copy by these rules, in order:
//    1. wrap to `lines` (2) lines, balanced — a phrase break ("The Less I Know the Better /
//       (Extended Edition) – Remastered 2015") when one is about as even, else the narrowest
//       even split, so line 2 is never a lone orphan word where that can be avoided;
//    2. if it still needs more lines, shrink it slightly, down to a floor (85 %);
//    3. still too long: the last line holds the rest unbroken and the overlay scrolls it
//       (a slow marquee) — or, with Reduce Motion and in stills, one more line (words break
//       only when a single word is wider than the column), smaller again if it must be.
//  There is no ellipsis anywhere.

import AppKit
import CoreText

struct MusicTextStyle {
    var size: CGFloat
    var weight: NSFont.Weight = .regular
    var color: CGColor = CGColor(gray: 1, alpha: 1)
    /// Extra letter spacing, in ems.
    var tracking: CGFloat = 0
    var maxLines = 1
    var alignment: CTTextAlignment = .left
    /// Distance between baselines, as a multiple of the size (multi-line text).
    var leading: CGFloat = 1.12
    var monospacedDigits = false
    var uppercase = false
    /// The soft shadow under the type, as a strength (0 = none, 1 = the default): a tight,
    /// faint contact shadow inside a wide, low-opacity one, so white type reads over bright
    /// art and scenes without a visible dark halo around the letters.
    var shadow: CGFloat = 1
}

/// Text laid out into lines, measured: `width` is the widest line's ink advance (at most the
/// column), `height` the box from the first line's ascent to the last line's descent.
struct MusicTextBlock {
    var lines: [CTLine]
    var lineWidths: [CGFloat]
    var ascent: CGFloat
    var descent: CGFloat
    var lineStep: CGFloat
    var style: MusicTextStyle
    /// The column the lines were set in.
    var column: CGFloat = .greatestFiniteMagnitude
    /// The last line holds the rest of the text unbroken, wider than the column: the overlay
    /// scrolls it (a marquee). Only `fit(…, marquee: true)` leaves a block like this.
    var overflows = false
    /// A line broke inside a word (a single word wider than the column).
    var brokeWord = false

    var width: CGFloat { min(lineWidths.max() ?? 0, column) }
    var height: CGFloat { lines.isEmpty ? 0 : ascent + descent + CGFloat(lines.count - 1) * lineStep }
    var isEmpty: Bool { lines.isEmpty }
    /// The overflowing last line's full advance (0 when nothing overflows).
    var overflowWidth: CGFloat { overflows ? (lineWidths.last ?? 0) : 0 }

    /// Lines `r` as a block of their own (the first of them on top).
    func slice(_ r: Range<Int>) -> MusicTextBlock {
        var b = self
        b.lines = Array(lines[r]); b.lineWidths = Array(lineWidths[r])
        b.overflows = overflows && r.upperBound == lines.count
        return b
    }
}

enum MusicText {
    static func font(_ s: MusicTextStyle) -> CTFont {
        let f = s.monospacedDigits ? NSFont.monospacedDigitSystemFont(ofSize: s.size, weight: s.weight)
                                   : NSFont.systemFont(ofSize: s.size, weight: s.weight)
        return f as CTFont
    }

    private static func attributed(_ text: String, _ s: MusicTextStyle, font: CTFont) -> NSAttributedString {
        NSAttributedString(string: s.uppercase ? text.uppercased() : text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): s.color,
            NSAttributedString.Key(kCTKernAttributeName as String): s.tracking * s.size,
        ])
    }

    private static let noBreak: Set<Character> = ["\u{00A0}", "\u{202F}", "\u{2007}"]

    /// Whitespace and newlines collapse to single spaces (no-break spaces stay: they're how
    /// copy keeps words together on a line).
    static func clean(_ text: String) -> String {
        text.split(whereSeparator: { ($0.isWhitespace || $0.isNewline) && !Self.noBreak.contains($0) })
            .joined(separator: " ")
    }

    // MARK: Line breaking

    /// One string in one style, typeset once: every width it is tried at (balancing, finding
    /// the column) reuses the typesetter — building one, with the font cascade for CJK and
    /// emoji, is the expensive part of setting a line. Kept in a small thread-safe cache, so
    /// measuring a column and then setting the text in it typesets it only once.
    private final class Setter {
        let style: MusicTextStyle
        let font: CTFont
        let ns: NSString
        let ts: CTTypesetter?
        var total: Int { ns.length }
        /// The whole text on one line, its ink advance.
        private(set) lazy var naturalWidth: CGFloat = {
            guard let ts, total > 0 else { return 0 }
            return MusicText.advance(CTTypesetterCreateLine(ts, CFRange(location: 0, length: total)))
        }()

        init(_ clean: String, _ s: MusicTextStyle) {
            style = s
            font = MusicText.font(s)
            let str = MusicText.attributed(clean, s, font: font)
            ns = str.string as NSString
            ts = str.length > 0 ? CTTypesetterCreateWithAttributedString(str) : nil
        }

        func empty(column: CGFloat) -> MusicTextBlock {
            MusicTextBlock(lines: [], lineWidths: [], ascent: CTFontGetAscent(font), descent: CTFontGetDescent(font),
                           lineStep: style.size * style.leading, style: style, column: max(column, 1))
        }

        func layout(width: CGFloat, maxLines: Int, wordBreaks: Bool) -> MusicTextBlock {
            var block = empty(column: width)
            block.style.maxLines = maxLines
            guard let ts, total > 0, width > 1 else { return block }
            let maxLines = max(maxLines, 1)
            var start = 0
            while start < total {
                let last = block.lines.count == maxLines - 1
                var count = CTTypesetterSuggestLineBreak(ts, start, Double(width))
                if count <= 0 { count = 1 }
                let forced = start + count < total && MusicText.isInsideWord(ns, at: start + count)
                let rest = (last && start + count < total) || (forced && !wordBreaks)
                let line = CTTypesetterCreateLine(ts, CFRange(location: start, length: rest ? total - start : count))
                block.lines.append(line)
                block.lineWidths.append(MusicText.advance(line))
                if rest { block.overflows = true; break }
                if forced { block.brokeWord = true }
                start += count
                // Skip the spaces a break left at the start of the next line.
                while start < total, ns.character(at: start) == 0x20 { start += 1 }
            }
            return block
        }

        /// Two lines split at a phrase boundary — before a bracket, around a spaced dash, after
        /// a colon or comma — when both fit `c` and the shorter is at least half the longer.
        func phraseSplit(column c: CGFloat) -> MusicTextBlock? {
            guard let ts, total > 3 else { return nil }
            func ch(_ i: Int) -> unichar { i >= 0 && i < total ? ns.character(at: i) : 0x20 }
            let open: Set<unichar> = Set("([{（【「『".utf16), dash: Set<unichar> = Set("–—-".utf16)
            let after: Set<unichar> = Set(",:;，".utf16), longDash: Set<unichar> = Set("–—".utf16)
            var cuts: [Int] = []                          // UTF-16 offset where line 2 starts
            for i in 1..<(total - 1) where ch(i - 1) == 0x20 {
                let c0 = ch(i), prev = ch(i - 2)
                if open.contains(c0) { cuts.append(i) }                            // "Song" / "(Remix)"
                else if dash.contains(c0), ch(i + 1) == 0x20 { cuts.append(i) }   // "Song" / "– Live"
                else if after.contains(prev) { cuts.append(i) }                    // "Episode 4:" / "How…"
                else if longDash.contains(prev), ch(i - 3) == 0x20 { cuts.append(i) }
            }
            var best: (ratio: CGFloat, block: MusicTextBlock)?
            for cut in cuts {
                var end = cut
                while end > 0, ch(end - 1) == 0x20 { end -= 1 }
                guard end > 0 else { continue }
                let la = CTTypesetterCreateLine(ts, CFRange(location: 0, length: end))
                let lb = CTTypesetterCreateLine(ts, CFRange(location: cut, length: total - cut))
                let wa = MusicText.advance(la), wb = MusicText.advance(lb)
                guard wa <= c, wb <= c else { continue }
                let ratio = min(wa, wb) / max(wa, wb, 1)
                guard ratio >= 0.5, ratio > (best?.ratio ?? 0) else { continue }
                var b = empty(column: c)
                b.style.maxLines = max(b.style.maxLines, 2)
                b.lines = [la, lb]; b.lineWidths = [wa, wb]
                best = (ratio, b)
            }
            return best?.block
        }
    }

    private static let setters: NSCache<NSString, Setter> = {
        let c = NSCache<NSString, Setter>()
        c.countLimit = 32
        return c
    }()

    /// Drop the cached typesetters (the saver's teardown; tools timing a cold layout).
    static func purge() { setters.removeAllObjects() }

    private static func setter(_ text: String, _ s: MusicTextStyle) -> Setter {
        let clean = clean(text)
        let rgba = (s.color.components ?? []).map { String(format: "%.3f", $0) }.joined(separator: ",")
        let key = "\(s.size)|\(s.weight.rawValue)|\(s.tracking)|\(s.leading)|\(s.monospacedDigits)|\(s.uppercase)|\(rgba)|\(clean)"
            as NSString
        if let hit = setters.object(forKey: key) { return hit }
        let made = Setter(clean, s)
        setters.setObject(made, forKey: key)
        return made
    }

    /// Wrap `text` into at most `style.maxLines` lines of `width`. When it needs more, the last
    /// line holds the rest unbroken (`overflows`, wider than the column) — never an ellipsis.
    /// `wordBreaks: false` also overflows instead of breaking inside a word that is wider than
    /// the column (CJK and other scripts that wrap between characters still wrap).
    static func layout(_ text: String, _ s: MusicTextStyle, width: CGFloat, wordBreaks: Bool = true) -> MusicTextBlock {
        setter(text, s).layout(width: width, maxLines: s.maxLines, wordBreaks: wordBreaks)
    }

    /// A line's ink advance, without its trailing spaces.
    fileprivate static func advance(_ line: CTLine) -> CGFloat {
        max(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line)), 0)
    }

    /// True when a break at UTF-16 offset `i` falls inside a word of a script that separates
    /// words with spaces (CoreText's emergency break for a word wider than the line). Breaks
    /// between CJK characters, after hyphens and slashes, and around punctuation are fine.
    fileprivate static func isInsideWord(_ s: NSString, at i: Int) -> Bool {
        guard i > 0, i < s.length else { return false }
        func scalar(_ j: Int) -> Unicode.Scalar? {
            let c = s.character(at: j)
            if UTF16.isTrailSurrogate(c), j > 0 {
                let hi = s.character(at: j - 1)
                return Unicode.Scalar(UInt32(0x10000 + ((Int(hi) - 0xD800) << 10) + (Int(c) - 0xDC00)))
            }
            if UTF16.isLeadSurrogate(c), j + 1 < s.length {
                let lo = s.character(at: j + 1)
                return Unicode.Scalar(UInt32(0x10000 + ((Int(c) - 0xD800) << 10) + (Int(lo) - 0xDC00)))
            }
            return Unicode.Scalar(c)
        }
        guard let a = scalar(i - 1), let b = scalar(i) else { return false }
        func wordy(_ u: Unicode.Scalar) -> Bool {
            let p = u.properties
            guard p.isAlphabetic || p.numericType != nil || p.generalCategory == .nonspacingMark else { return false }
            switch u.value {
            case 0x0E00...0x0EFF,                      // Thai, Lao: dictionary breaks
                 0x1100...0x11FF, 0x3040...0x30FF, 0x3130...0x318F, 0x3400...0x4DBF, 0x4E00...0x9FFF,
                 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF66...0xFF9F, 0x20000...0x3FFFF:
                return false                           // CJK wraps between characters
            default:
                return true
            }
        }
        return wordy(a) && wordy(b)
    }

    // MARK: Fitting (never cut off)

    /// Set `text` in `column` without cutting it off: up to `lines` lines, balanced; else
    /// smaller, down to `floor` × its size; else (`marquee`) the last line holds the rest for
    /// the overlay to scroll, or (no marquee: Reduce Motion, stills) one more line and, only
    /// if it must, smaller still. `maxScale` caps the size (a secondary line never outgrows a
    /// title that had to shrink). The block's style carries the size it was set at.
    static func fit(_ text: String, _ base: MusicTextStyle, column c: CGFloat, lines: Int = 2,
                    floor: CGFloat = 0.85, maxScale: CGFloat = 1, marquee: Bool) -> MusicTextBlock {
        var s = base
        s.maxLines = max(lines, 1)
        let top = min(maxScale, 1)
        let lo = min(floor, top)
        // A size whose one-line width can't fit `lines` lines (with half an em of slack per line
        // for the spaces a break removes) is skipped without typesetting it. SF's smaller optical
        // size is wider, so the linear estimate only ever errs toward trying.
        var probe = base
        probe.size = base.size * top
        let natural = setter(text, probe).naturalWidth / max(top, 0.01)
        func hopeless(_ k: CGFloat, _ n: Int) -> Bool {
            natural * k > CGFloat(n) * (c + base.size * k * 0.5)
        }
        var k = top
        while true {
            s.size = base.size * k
            if !hopeless(k, s.maxLines), let b = wrap(text, s, column: c) { return b }
            if k <= lo + 0.0001 { break }
            k = max(k - 0.025, lo)
        }
        s.size = base.size * lo
        if marquee { return layout(text, s, width: c, wordBreaks: false) }
        // Static: one more line of whole words, else the lines broken inside an over-long word,
        // else smaller, else as many lines as it takes. Never an ellipsis.
        var more = s
        more.maxLines = s.maxLines + 1
        if !hopeless(lo, more.maxLines), let b = wrap(text, more, column: c) { return b }
        if !hopeless(lo, s.maxLines), let b = wrap(text, s, column: c, wordBreaks: true) { return b }
        var k2 = lo
        while k2 > 0.6 {
            k2 = max(k2 - 0.05, 0.6)
            more.size = base.size * k2
            if !hopeless(k2, more.maxLines), let b = wrap(text, more, column: c, wordBreaks: true) { return b }
        }
        more.maxLines = 64
        return balanced(layout(text, more, width: c, wordBreaks: true), text, more, column: c, wordBreaks: true)
    }

    /// The narrowest column in `lo…hi` that sets `text` at its size in `lines` lines without
    /// breaking a word (widened a little for a phrase break); nil when even `hi` can't.
    static func neededWidth(_ text: String, _ style: MusicTextStyle, lines: Int = 2,
                            min lo: CGFloat, max hi: CGFloat) -> CGFloat? {
        let n = max(lines, 1)
        let set = setter(text, style)
        func fits(_ w: CGFloat) -> Bool { !set.layout(width: w, maxLines: n, wordBreaks: false).overflows }
        if fits(lo) { return lo }
        guard hi > lo, set.naturalWidth <= CGFloat(n) * (hi + style.size * 0.5), fits(hi) else { return nil }
        var a = lo, b = hi
        for _ in 0..<12 {
            let mid = (a + b) / 2
            if fits(mid) { b = mid } else { a = mid }
        }
        let narrow = min(ceil(b), hi)
        if n >= 2, let p = set.phraseSplit(column: hi), p.width <= min(hi, narrow * 1.25) {
            return max(narrow, min(ceil(p.width), hi))
        }
        return narrow
    }

    /// `text` in at most `style.maxLines` lines of `c` (nil when it needs more), balanced.
    private static func wrap(_ text: String, _ s: MusicTextStyle, column c: CGFloat,
                             wordBreaks: Bool = false) -> MusicTextBlock? {
        let b = layout(text, s, width: c, wordBreaks: wordBreaks)
        guard !b.overflows else { return nil }
        return balanced(b, text, s, column: c, wordBreaks: wordBreaks)
    }

    /// Even lines: a phrase break for two lines when one is about as even, else the narrowest
    /// width that keeps the line count (so the last line isn't a lone word). The block keeps
    /// `column` as its column.
    private static func balanced(_ b: MusicTextBlock, _ text: String, _ s: MusicTextStyle, column c: CGFloat,
                                 wordBreaks: Bool) -> MusicTextBlock {
        guard b.lines.count >= 2, !b.overflows else { return b }
        let set = setter(text, s)
        if b.lines.count == 2, !b.brokeWord, let p = set.phraseSplit(column: c) { return p }
        // No narrower than an even share of the text (a lower bound the search needn't probe).
        var lo = max(set.naturalWidth / CGFloat(b.lines.count) - s.size, 0), hi = c, best = b
        for _ in 0..<10 {
            let mid = (lo + hi) / 2
            let t = set.layout(width: mid, maxLines: s.maxLines, wordBreaks: wordBreaks)
            if !t.overflows && t.lines.count == b.lines.count && (!t.brokeWord || b.brokeWord) {
                hi = mid; best = t
            } else {
                lo = mid
            }
        }
        best.column = c
        return best
    }

    // MARK: Rendering

    /// Padding baked around the text bitmap (accents above the ascent, the shadow's reach).
    static func pad(_ s: MusicTextStyle) -> CGFloat { ceil(s.size * 0.22 + (s.shadow > 0 ? s.size * 0.62 : 0)) }

    /// The shadow's two layers, in points: (offset down, blur, opacity) — tight, then wide.
    static func shadowLayers(_ s: MusicTextStyle) -> [(dy: CGFloat, blur: CGFloat, alpha: CGFloat)] {
        guard s.shadow > 0 else { return [] }
        return [(max(s.size * 0.025, 0.5), s.size * 0.10, 0.20 * s.shadow),
                (s.size * 0.06, s.size * 0.48, 0.26 * s.shadow)]
    }

    /// Render a block into a transparent bitmap `boxWidth` wide (lines aligned within it) at
    /// `scale` pixels per point. The image covers the box plus `pad` on every side.
    static func image(_ b: MusicTextBlock, boxWidth: CGFloat, scale: CGFloat) -> CGImage? {
        guard !b.isEmpty else { return nil }
        let pad = pad(b.style)
        let wPt = boxWidth + pad * 2, hPt = b.height + pad * 2
        let w = max(Int(ceil(wPt * scale)), 1), h = max(Int(ceil(hPt * scale)), 1)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setShouldSmoothFonts(false)
        ctx.setAllowsFontSmoothing(false)
        ctx.setShouldSubpixelPositionFonts(true)
        ctx.textMatrix = .identity
        // Shadows: nested transparency layers — the wide one is cast by the text plus its
        // tight one. CG shadow geometry is in device pixels (unaffected by the CTM), so it's
        // scaled here; a negative height is downward in a bitmap context.
        let layers = MusicText.shadowLayers(b.style)
        for l in layers.reversed() {
            ctx.setShadow(offset: CGSize(width: 0, height: -l.dy * scale), blur: l.blur * scale,
                          color: CGColor(gray: 0, alpha: l.alpha))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        for (i, line) in b.lines.enumerated() {
            let lw = min(b.lineWidths[i], boxWidth)
            var x = pad
            switch b.style.alignment {
            case .center: x += (boxWidth - lw) / 2
            case .right: x += boxWidth - lw
            default: break
            }
            // Bitmap origin is bottom-left; baseline i sits `ascent + i·step` below the top.
            let y = hPt - pad - b.ascent - CGFloat(i) * b.lineStep
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, ctx)
        }
        for _ in layers { ctx.endTransparencyLayer() }   // composite (and cast) the shadows
        return ctx.makeImage()
    }

    /// One frame of a marquee as a still bitmap: the one-line block `b` shifted left by
    /// `offset` points, seen through a viewport `viewport` points wide (the column plus the
    /// text's pad either side) under a horizontal opacity ramp (`stops` 0…1 across it, with
    /// `alphas`) — what the live layer's gradient mask shows at that point of its travel.
    static func marqueeFrame(_ b: MusicTextBlock, viewport: CGFloat, offset: CGFloat, stops: [CGFloat],
                             alphas: [CGFloat], scale: CGFloat) -> CGImage? {
        let lineW = ceil(b.lineWidths.first ?? 0)
        guard let line = image(b, boxWidth: lineW, scale: scale) else { return nil }
        let w = max(Int((viewport * scale).rounded()), 1), h = line.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(line, in: CGRect(x: -(offset * scale).rounded(), y: 0, width: CGFloat(line.width), height: CGFloat(h)))
        let colors = alphas.map { CGColor(gray: 0, alpha: $0) }
        if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray,
                              locations: stops) {
            ctx.setBlendMode(.destinationIn)
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: 0),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        return ctx.makeImage()
    }
}
