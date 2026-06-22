//  GlyphAtlas.swift — bakes a density-ordered strip of monospace glyphs into a
//  texture used by the ASCII and Matrix Rain shaders.

import Metal
import CoreText
import CoreGraphics

enum GlyphAtlas {
    // Dense -> sparse, so brighter source pixels pick lighter glyphs.
    static let characters = Array("@#W$9876543210?!abc;:+=-,._ ")
    static var count: Int { characters.count }

    static func make(device: MTLDevice) -> MTLTexture? {
        let cellW = 28, cellH = 40
        let n = characters.count
        let width = cellW * n, height = cellH
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Menlo-Bold" as CFString, CGFloat(cellH) * 0.72, nil)
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        for (i, ch) in characters.enumerated() {
            let attrs: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: white
            ]
            let attr = CFAttributedStringCreate(nil, String(ch) as CFString, attrs as CFDictionary)!
            let line = CTLineCreateWithAttributedString(attr)
            let bounds = CTLineGetImageBounds(line, ctx)
            let x = CGFloat(i * cellW) + (CGFloat(cellW) - bounds.width) / 2 - bounds.minX
            let y = (CGFloat(cellH) - bounds.height) / 2 - bounds.minY
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, ctx)
        }

        guard let img = ctx.makeImage() else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                            width: width, height: height, mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }

        // Copy CGImage pixels into the texture.
        let bytesPerRow = width * 4
        guard let data = ctx.data else { return tex }
        tex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                    withBytes: data, bytesPerRow: bytesPerRow)
        _ = img
        return tex
    }
}
