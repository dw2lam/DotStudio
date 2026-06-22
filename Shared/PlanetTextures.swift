//  PlanetTextures.swift — loads real Earth + planet maps for the Universe effect.
//  Earth day/night are 2D textures; the 8 planets are packed into a 2D array
//  (same 1024×512 size) so the shader can sample any planet by layer index.

import Metal
import MetalKit

final class PlanetTextures {
    static let order = ["mercury", "venus", "mars", "jupiter", "saturn", "uranus", "neptune", "moon"]

    let earthDay: MTLTexture
    let earthNight: MTLTexture
    let planets: MTLTexture          // texture2d_array, one layer per `order`
    let loaded: Bool

    init(device: MTLDevice, queue: MTLCommandQueue) {
        let loader = MTKTextureLoader(device: device)
        let bundle = Bundle(for: PlanetTextures.self)
        let opts: [MTKTextureLoader.Option: Any] = [
            .SRGB: true,
            .origin: MTKTextureLoader.Origin.topLeft.rawValue,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue)
        ]
        func load2D(_ name: String) -> MTLTexture? {
            guard let url = bundle.url(forResource: name, withExtension: "jpg") else { return nil }
            return try? loader.newTexture(URL: url, options: opts)
        }
        func dummy2D() -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
            d.usage = .shaderRead
            return device.makeTexture(descriptor: d)!
        }

        let day = load2D("earth_day"), night = load2D("earth_night")
        earthDay = day ?? dummy2D()
        earthNight = night ?? dummy2D()

        let layers = PlanetTextures.order.compactMap { load2D($0) }
        var array: MTLTexture?
        if layers.count == PlanetTextures.order.count, let first = layers.first,
           let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() {
            let d = MTLTextureDescriptor()
            d.textureType = .type2DArray
            d.pixelFormat = first.pixelFormat
            d.width = first.width; d.height = first.height
            d.arrayLength = layers.count
            d.usage = .shaderRead
            d.storageMode = .private
            if let arr = device.makeTexture(descriptor: d) {
                for (i, t) in layers.enumerated() where t.width == first.width && t.height == first.height {
                    blit.copy(from: t, sourceSlice: 0, sourceLevel: 0,
                              sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                              sourceSize: MTLSize(width: t.width, height: t.height, depth: 1),
                              to: arr, destinationSlice: i, destinationLevel: 0,
                              destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                }
                array = arr
            }
            blit.endEncoding(); cmd.commit(); cmd.waitUntilCompleted()
        }

        if let array = array {
            planets = array
            loaded = (day != nil && night != nil)
        } else {
            let d = MTLTextureDescriptor()
            d.textureType = .type2DArray; d.pixelFormat = .rgba8Unorm
            d.width = 1; d.height = 1; d.arrayLength = 1; d.usage = .shaderRead
            planets = device.makeTexture(descriptor: d)!
            loaded = false
        }
    }
}
