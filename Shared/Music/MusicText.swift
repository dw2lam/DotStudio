//  MusicText.swift — CoreText type for the music overlay: system font (SF Pro, with the
//  system cascade for CJK, emoji and accents), wrapping to a line limit with an ellipsis on
//  the last line, rendered to a bitmap at the display's native scale.

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
    /// A soft dark halo for type over busy imagery (Cover layout).
    var halo: CGFloat = 0
}

/// Text laid out into lines, measured: `width` is the widest line's ink advance, `height` the
/// box from the first line's ascent to the last line's descent.
struct MusicTextBlock {
    var lines: [CTLine]
    var lineWidths: [CGFloat]
    var ascent: CGFloat
    var descent: CGFloat
    var lineStep: CGFloat
    var style: MusicTextStyle

    var width: CGFloat { lineWidths.max() ?? 0 }
    var height: CGFloat { lines.isEmpty ? 0 : ascent + descent + CGFloat(lines.count - 1) * lineStep }
    var isEmpty: Bool { lines.isEmpty }
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

    /// Wrap `text` into at most `style.maxLines` lines of `width`; the last line ends in "…"
    /// when the text doesn't fit. Whitespace and newlines collapse to single spaces (no-break
    /// spaces stay).
    static func layout(_ text: String, _ s: MusicTextStyle, width: CGFloat) -> MusicTextBlock {
        let font = font(s)
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        var block = MusicTextBlock(lines: [], lineWidths: [], ascent: ascent, descent: descent,
                                   lineStep: s.size * s.leading, style: s)
        // No-break spaces survive (Swift counts them as whitespace): they're how copy keeps
        // words together on a line.
        let clean = text.split(whereSeparator: { ($0.isWhitespace || $0.isNewline) && !Self.noBreak.contains($0) })
            .joined(separator: " ")
        guard !clean.isEmpty, width > 1 else { return block }
        let str = attributed(clean, s, font: font)
        let ts = CTTypesetterCreateWithAttributedString(str)
        let token = CTLineCreateWithAttributedString(attributed("…", s, font: font))
        let total = str.length
        var start = 0
        for i in 0..<max(s.maxLines, 1) {
            guard start < total else { break }
            let last = (i == max(s.maxLines, 1) - 1)
            var count = CTTypesetterSuggestLineBreak(ts, start, Double(width))
            if count <= 0 { count = 1 }
            var line: CTLine
            if last && start + count < total {
                // Last allowed line and text remains: set the rest on one line, then truncate.
                let rest = CTTypesetterCreateLine(ts, CFRange(location: start, length: total - start))
                line = CTLineCreateTruncatedLine(rest, Double(width), .end, token) ?? rest
            } else {
                line = CTTypesetterCreateLine(ts, CFRange(location: start, length: count))
            }
            block.lines.append(line)
            let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line))
            block.lineWidths.append(min(max(w, 0), width))
            start += count
            // Skip the spaces a break left at the start of the next line.
            while start < total, (str.string as NSString).character(at: start) == 0x20 { start += 1 }
        }
        return block
    }

    /// Padding baked around the text bitmap (accents above the ascent, the halo).
    static func pad(_ s: MusicTextStyle) -> CGFloat { ceil(s.size * 0.22 + s.halo * s.size * 0.6) }

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
        if b.style.halo > 0 {
            ctx.setShadow(offset: .zero, blur: b.style.size * b.style.halo,
                          color: CGColor(gray: 0, alpha: 0.55))
        }
        for (i, line) in b.lines.enumerated() {
            let lw = b.lineWidths[i]
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
        return ctx.makeImage()
    }
}
