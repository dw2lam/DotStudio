//  MediaSource.swift — turns an image or video file into a Metal texture per frame.

import Metal
import MetalKit
import AVFoundation
import CoreVideo

protocol MediaSource: AnyObject {
    var size: CGSize { get }
    func currentTexture() -> MTLTexture?
}

/// A still image, decoded once.
final class ImageSource: MediaSource {
    private let texture: MTLTexture?
    let size: CGSize

    init?(url: URL, device: MTLDevice) {
        let loader = MTKTextureLoader(device: device)
        let opts: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .origin: MTKTextureLoader.Origin.topLeft.rawValue
        ]
        guard let t = try? loader.newTexture(URL: url, options: opts) else { return nil }
        texture = t
        size = CGSize(width: t.width, height: t.height)
    }

    func currentTexture() -> MTLTexture? { texture }
}

/// A looping, hardware-decoded video.
final class VideoSource: MediaSource {
    private let player: AVQueuePlayer
    private var looper: AVPlayerLooper?
    private let output: AVPlayerItemVideoOutput
    private var cache: CVMetalTextureCache?
    private let device: MTLDevice
    private(set) var size: CGSize = CGSize(width: 1920, height: 1080)

    init?(url: URL, device: MTLDevice) {
        self.device = device
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        item.add(output)
        player = AVQueuePlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .none
        looper = AVPlayerLooper(player: player, templateItem: item)
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)

        if let track = asset.tracks(withMediaType: .video).first {
            let s = track.naturalSize.applying(track.preferredTransform)
            size = CGSize(width: abs(s.width), height: abs(s.height))
        }
        player.play()
    }

    func currentTexture() -> MTLTexture? {
        guard let cache = cache else { return nil }
        let host = CACurrentMediaTime()
        let time = output.itemTime(forHostTime: host)
        guard output.hasNewPixelBuffer(forItemTime: time) || lastTexture == nil,
              let pb = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) ?? lastBuffer
        else { return lastTexture }

        lastBuffer = pb
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        size = CGSize(width: w, height: h)
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pb, nil, .bgra8Unorm, w, h, 0, &cvTex)
        guard status == kCVReturnSuccess, let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else {
            return lastTexture
        }
        lastTexture = tex
        return tex
    }

    private var lastTexture: MTLTexture?
    private var lastBuffer: CVPixelBuffer?
}
