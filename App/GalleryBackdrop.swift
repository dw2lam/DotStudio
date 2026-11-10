//  GalleryBackdrop.swift — the blurred, colour-washed backdrop behind the gallery and the
//  editor (the look of SwiftUI's `blur(radius: 70, opaque: true)` over the still), with the
//  blur baked into a bitmap once per still and window size instead of a live blur filter: the
//  window server re-ran that full-window blur for every frame the page above it changed —
//  every frame of a scroll.

import SwiftUI
import CoreImage

struct GalleryBackdrop: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    let presetID: UUID?
    /// The blur, in points of the window.
    static let radius: CGFloat = 70

    var body: some View {
        GeometryReader { g in
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                if let p = presetID.flatMap(model.preset),
                   let img = model.thumbnailer.image(for: p, source: model.library.source, music: model.library.musicSettings),
                   let blurred = BlurCache.shared.blurred(img, fill: g.size, radius: Self.radius) {
                    Image(nsImage: blurred)
                        .resizable()
                        .scaledToFill()
                        .frame(width: g.size.width, height: g.size.height)
                        .clipped()
                        .saturation(1.35)
                        .opacity(scheme == .dark ? 0.8 : 0.6)
                        .id(p.id)
                        .transition(.opacity)
                }
                // Keep the top calm under the toolbar and fade the wash out down the page.
                LinearGradient(stops: [
                    .init(color: Color(nsColor: .windowBackgroundColor).opacity(0.05), location: 0),
                    .init(color: Color(nsColor: .windowBackgroundColor).opacity(scheme == .dark ? 0.45 : 0.5), location: 0.45),
                    .init(color: Color(nsColor: .windowBackgroundColor).opacity(0.88), location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: presetID)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Pre-blurred stills, keyed by the still (its identity: a new still is a new image) and the
/// size it fills (rounded, so a live resize re-blurs every ~32 pt, not every pixel). Tiny:
/// the blur runs at the still's own resolution (≤ 448×280), and the wash is that soft anyway.
final class BlurCache {
    static let shared = BlurCache()
    // Blurred in sRGB-encoded values, as SwiftUI blurs (a linear-light blur reads brighter).
    private let context = CIContext(options: [.cacheIntermediates: false,
                                              .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    private var entries: [(key: Key, image: NSImage)] = []
    private static let capacity = 4
    /// CIGaussianBlur's radius (a sigma) per point of SwiftUI's `blur(radius:)`.
    /// Checked with DOTSTUDIO_PERF_PROBE=backdrop: mean 0.7/255, max 6/255 vs the live blur.
    static let sigmaPerRadius: CGFloat = 1

    private struct Key: Equatable {
        let image: ObjectIdentifier
        let width: Int
        let height: Int
    }

    func blurred(_ image: NSImage, fill size: CGSize, radius: CGFloat) -> NSImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let key = Key(image: ObjectIdentifier(image), width: Int((size.width / 32).rounded()),
                      height: Int((size.height / 32).rounded()))
        if let hit = entries.first(where: { $0.key == key }) { return hit.image }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        // scaledToFill: points of the window per pixel of the still.
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let fillScale = max(size.width / w, size.height / h)
        let r = radius * Self.sigmaPerRadius / fillScale
        let input = CIImage(cgImage: cg)
        // Edges extended, then cropped back: as SwiftUI's blur(opaque: true).
        guard let blur = CIFilter(name: "CIGaussianBlur", parameters: [
            kCIInputImageKey: input.clampedToExtent(), kCIInputRadiusKey: r,
        ])?.outputImage?.cropped(to: input.extent),
              let out = context.createCGImage(blur, from: input.extent) else { return nil }
        let img = NSImage(cgImage: out, size: image.size)
        // Keep the original alive with its entry: the key is its identity.
        entries.append((key, img))
        retained.append(image)
        if entries.count > Self.capacity { entries.removeFirst(); retained.removeFirst() }
        return img
    }

    private var retained: [NSImage] = []

    func removeAll() { entries.removeAll(); retained.removeAll() }
}
