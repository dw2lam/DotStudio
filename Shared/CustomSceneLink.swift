//  CustomSceneLink.swift — what a MetalRenderer uses to draw a Custom Scene (EffectKind.custom).
//
//  Every renderer owns one (like WeatherLink). For each Custom Scene pass it:
//    • finds the package (re-checking its files at most once a second, so an edit — a reinstall
//      from the MCP server — shows up live) and its prepared source (CustomSceneCompiler);
//    • fills the uniforms the engine's DSContext reads (params in manifest order, colours, sun,
//      weather, seed, stepped time; the renderer adds music) — layout in Engines/metal/1/Runtime.h;
//    • binds the package's own pipeline over the pass's stand-in (fx_scene_90, a calm gradient of
//      colour A) once it's built; until then, or if it can't be, the stand-in draws and the scene
//      is flagged (CustomSceneLink.status).

import Foundation
import Metal
import MetalKit
import QuartzCore
import simd

final class CustomSceneLink {
    let store: URL
    private let lock = NSLock()

    init(store: URL) { self.store = store }

    /// A package as last seen: its files' stamps, and what they prepared into.
    private final class Entry {
        var stamps: [FileStamp?] = []
        var checked: CFTimeInterval = -.infinity
        var prepared: PreparedScene?
        var assetsTex: [MTLTexture]?
        var film: CustomFilm?
    }
    private var entries: [String: Entry] = [:]

    /// Params packed per effect instance (id → (params it was packed from, vector)).
    private var packed: [UUID: (params: [String: Double], p: [Float], e: simd_float4)] = [:]

    // MARK: Resolving

    private func stamps(_ dir: URL, _ m: CustomSceneManifest?) -> [FileStamp?] {
        var paths = ["scene.json"]
        if let e = m?.entry { paths.append(e) }
        paths += (m?.assets ?? [])
        // (other sources a package includes: the folder's own stamp moves when one is replaced)
        var out = paths.map { FileStamp(path: dir.appendingPathComponent($0).path) }
        out.append(FileStamp(path: dir.path))
        out.append(FileStamp(path: dir.appendingPathComponent(".gpu-fault.json").path))
        return out
    }

    /// The prepared package `id` (nil: not installed). Re-reads it when its files changed.
    func prepared(_ id: String, now: CFTimeInterval = CACurrentMediaTime()) -> PreparedScene? {
        guard CustomScenes.isValidID(id) else { return nil }
        lock.lock()
        let e = entries[id] ?? Entry()
        entries[id] = e
        if now - e.checked < 1, e.checked > -.infinity { lock.unlock(); return e.prepared }
        e.checked = now
        lock.unlock()
        let dir = CustomScenes.packageDir(id: id, store: store)
        let m = CustomScenes.manifest(id: id, store: store)
        let st = stamps(dir, m)
        lock.lock()
        let unchanged = st == e.stamps && e.prepared != nil
        lock.unlock()
        if unchanged { return e.prepared }
        let p: PreparedScene? = m == nil ? nil : CustomSceneCompiler.prepare(packageAt: dir, store: store)
        if let p, !p.hash.isEmpty, let reason = CustomScenePipelines.faultNoted(hash: p.hash, packageDir: dir) {
            CustomScenePipelines.markDisabled(hash: p.hash, reason: reason)
        }
        lock.lock()
        e.stamps = st
        if e.prepared?.hash != p?.hash { e.assetsTex = nil; e.film = nil }
        e.prepared = p
        lock.unlock()
        return p
    }

    /// Where a Custom Scene stands (the Inspector's flag, the MCP server's preview).
    enum Status: Equatable {
        case ready
        case compiling
        case missing                       // no such package installed
        case failed([Diagnostic])          // the stand-in draws
        case disabled(String)              // faulted on the GPU: off until edited
    }

    /// One link per store for status queries outside a renderer (the Inspector).
    private static let sharedLock = NSLock()
    private static var sharedLinks: [String: CustomSceneLink] = [:]
    static func shared(store: URL) -> CustomSceneLink {
        sharedLock.lock(); defer { sharedLock.unlock() }
        if let l = sharedLinks[store.path] { return l }
        let l = CustomSceneLink(store: store)
        sharedLinks[store.path] = l
        return l
    }

    /// The status on any GPU / format a renderer built it for (the Inspector's flag).
    func status(_ id: String) -> Status {
        guard let p = prepared(id) else { return .missing }
        if p.source == nil { return .failed(p.diagnostics) }
        switch CustomScenePipelines.anyState(p.hash) {
        case .ready: return .ready
        case .building: return .compiling
        case .failed(let d): return .failed(d)
        case .disabled(let r): return .disabled(r)
        }
    }

    func status(_ id: String, device: MTLDevice, format: MTLPixelFormat) -> Status {
        guard let p = prepared(id) else { return .missing }
        switch CustomScenePipelines.state(p, device: device, format: format) {
        case .ready: return .ready
        case .building: return .compiling
        case .failed(let d): return .failed(d)
        case .disabled(let r): return .disabled(r)
        }
    }

    /// Starts the builds a style needs (apply), and says whether all of them are done — built or
    /// failed (the screensaver's first frame waits for them, as for its own scene pipelines).
    func pipelinesReady(for preset: Preset, device: MTLDevice, format: MTLPixelFormat) -> Bool {
        var ready = true
        for id in preset.customSceneIDs {
            guard let p = prepared(id), p.source != nil else { continue }
            if CustomScenePipelines.pipeline(p, device: device, format: format, wait: false) == nil,
               case .building = CustomScenePipelines.state(p, device: device, format: format) { ready = false }
        }
        return ready
    }

    // MARK: Filling a pass

    /// Fills `u` for a Custom Scene pass and binds its pipeline and assets on `encoder` when
    /// they're there. Returns the hash of the pipeline bound (nil: the stand-in draws) so the
    /// renderer can watch the command buffer for a GPU fault.
    /// - live: a host drawing continuously (a film plays its clips); false = a one-off render
    ///   (thumbnails: a film shows its clips' poster frames).
    func fill(_ u: inout FXUniforms, inst: EffectInstance, wall: Date, location: (lat: Double, lon: Double)?,
              weather: WeatherMix, musicPlaying: Bool, musicLevel: Double,
              encoder: MTLRenderCommandEncoder, format: MTLPixelFormat, wait: Bool, live: Bool = true,
              now: CFTimeInterval = CACurrentMediaTime()) -> String? {
        u.effect = CustomScenes.fallbackShaderID
        guard let id = inst.custom?.id, let p = prepared(id, now: now) else { return nil }
        CustomSceneLink.fillStatic(&u, inst: inst, prepared: p, wall: wall, location: location, weather: weather,
                                   musicPlaying: musicPlaying, musicLevel: musicLevel, cache: self)
        var tex: [MTLTexture]
        if p.isFilm {
            guard let film = film(id),
                  let f = film.frame(device: encoder.device, now: now, wall: wall, location: location, weather: weather, live: live)
            else { return nil }
            u.scene.0 = simd_float4(Float(f.a.width), Float(f.a.height), Float(f.b.width), Float(f.b.height))
            u.scene.1 = simd_float4(f.mix, 0, 0, 0)
            let ph = CustomSceneAssets.placeholder(encoder.device)
            tex = [f.a, f.b, ph, ph]
        } else {
            tex = assets(p, device: encoder.device)
        }
        guard let pso = CustomScenePipelines.pipeline(p, device: encoder.device, format: format, wait: wait) else { return nil }
        encoder.setRenderPipelineState(pso)
        for i in 0..<4 { encoder.setFragmentTexture(tex[i], index: 9 + i) }
        encoder.setFragmentSamplerState(CustomSceneAssets.sampler(encoder.device), index: 0)
        return p.hash
    }

    /// The installed package whose prepared source has `hash` (the GPU fault note's folder).
    func packageDir(forHash hash: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return entries.values.first { $0.prepared?.hash == hash }?.prepared?.packageDir
    }

    /// Pauses (or resumes) every film this link plays (the hosts' media pause).
    func setFilmsPaused(_ paused: Bool) {
        lock.lock(); let films = entries.values.compactMap(\.film); lock.unlock()
        for f in films { f.setPaused(paused) }
    }

    private func assets(_ p: PreparedScene, device: MTLDevice) -> [MTLTexture] {
        lock.lock()
        if let t = entries[p.id]?.assetsTex { lock.unlock(); return t }
        lock.unlock()
        let t = CustomSceneAssets.textures(for: p, device: device)
        lock.lock(); entries[p.id]?.assetsTex = t; lock.unlock()
        return t
    }

    /// The film player for a film package (made on first use).
    func film(_ id: String) -> CustomFilm? {
        guard let p = prepared(id), p.isFilm, !p.hasErrors else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[id] else { return nil }
        if e.film == nil { e.film = CustomFilm(prepared: p) }
        return e.film
    }

    private func cachedPack(_ inst: EffectInstance, _ p: PreparedScene) -> (p: [Float], e: simd_float4) {
        lock.lock()
        if let c = packed[inst.id], c.params == inst.params { lock.unlock(); return (c.p, c.e) }
        lock.unlock()
        let v = CustomSceneLink.pack(inst, p)
        lock.lock()
        if packed.count > 64 { packed.removeAll() }
        packed[inst.id] = (inst.params, v.p, v.e)
        lock.unlock()
        return v
    }

    /// The manifest's params from the instance (clamped to their ranges, missing → default), in
    /// manifest order; and the engine's own params (cells: Render, Cell Size, Glow).
    static func pack(_ inst: EffectInstance, _ p: PreparedScene) -> (p: [Float], e: simd_float4) {
        var v = [Float](repeating: 0, count: 16)
        for (i, s) in p.manifest.paramSpecs.enumerated() where i < 16 {
            v[i] = Float(s.sanitize(inst.params[s.key] ?? s.def))
        }
        var e = simd_float4(0, 0, 0, 0)
        for (i, s) in (p.engine?.engineParamSpecs ?? []).enumerated() where i < 4 {
            e[i] = Float(s.sanitize(inst.params[s.key] ?? s.def))
        }
        return (v, e)
    }

    /// The uniforms DSContext is built from (Engines/metal/1/Runtime.h).
    static func fillStatic(_ u: inout FXUniforms, inst: EffectInstance, prepared p: PreparedScene, wall: Date,
                           location: (lat: Double, lon: Double)?, weather: WeatherMix, musicPlaying: Bool,
                           musicLevel: Double, cache: CustomSceneLink? = nil) {
        let m = p.manifest
        u.effect = CustomScenes.fallbackShaderID
        u.colorA = (inst.colorA ?? m.defaultColorA).simd
        u.colorB = (inst.colorB ?? m.defaultColorB).simd
        (u.clock, u.date) = u.clock == .zero ? MetalRenderer.wallClock(wall) : (u.clock, u.date)
        let packed = cache?.cachedPack(inst, p) ?? pack(inst, p)
        withUnsafeMutableBytes(of: &u.scene) { raw in
            let f = raw.bindMemory(to: Float.self)
            for i in 0..<16 { f[i] = packed.p[i] }
        }
        let sun = CustomSceneLink.sun(at: wall, location: location)
        u.scene.4 = simd_float4(Float(sun.elevation), Float(sun.azimuth), sun.elevation > -0.833 ? 1 : 0, location != nil ? 1 : 0)
        let rain = weather.precip * (1 - weather.snow), snow = weather.precip * weather.snow
        u.scene.5 = simd_float4(Float(weather.cover), Float(rain), Float(snow), Float(weather.fog))
        u.scene.6 = simd_float4(Float(min(max(weather.wind / 20, 0), 1)), seed(inst.id), Float(m.steppedFPS ?? 0), 0)
        u.scene.7 = simd_float4(musicPlaying ? 1 : 0, Float(min(max(musicLevel, 0), 1)), 0, 0)
        u.scene.8 = packed.e
    }

    /// 0…1, fixed per style instance.
    static func seed(_ id: UUID) -> Float {
        var h: UInt64 = 0xcbf29ce484222325
        for b in id.uuidString.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return Float(h >> 40) / Float(1 << 24)
    }

    // MARK: The sun

    private static let sunLock = NSLock()
    private static var sunCache: (key: Int, loc: String, v: (elevation: Double, azimuth: Double))?

    /// The sun's apparent elevation and azimuth (degrees; azimuth clockwise from north) at `date`
    /// where the Mac is (40° N on the time zone's meridian without a location, like liveSky).
    /// Cached per second.
    static func sun(at date: Date, location: (lat: Double, lon: Double)?) -> (elevation: Double, azimuth: Double) {
        let key = Int(date.timeIntervalSince1970.rounded(.down))
        let loc = location.map { "\($0.lat),\($0.lon)" } ?? "tz"
        sunLock.lock()
        if let c = sunCache, c.key == key, c.loc == loc { sunLock.unlock(); return c.v }
        sunLock.unlock()
        let d2r = Double.pi / 180
        let latDeg = location?.lat ?? 40
        let lonDeg = location?.lon ?? (Double(TimeZone.current.secondsFromGMT(for: date)) / 3600 * 15)
        let lat = latDeg * d2r
        let n = date.timeIntervalSince1970 / 86400 - 10957.5
        let eps = (23.439 - 4e-7 * n) * d2r
        let lst = (280.46061837 + 360.98564736629 * n + lonDeg) * d2r
        let L = (280.460 + 0.9856474 * n) * d2r, g = (357.528 + 0.9856003 * n) * d2r
        let lam = L + (1.915 * sin(g) + 0.020 * sin(2 * g)) * d2r
        let ra = atan2(cos(eps) * sin(lam), cos(lam)), dec = asin(sin(eps) * sin(lam))
        let H = lst - ra
        var h = asin(sin(lat) * sin(dec) + cos(lat) * cos(dec) * cos(H))
        let hd = max(h / d2r, -1)
        h += 1.02 / tan((hd + 10.3 / (hd + 5.11)) * d2r) / 60 * d2r * max(0, min(1, 1 + (h / d2r + 1) / 2))
        // azimuth from the south, westward → from the north, clockwise
        let az = atan2(sin(H), cos(H) * sin(lat) - tan(dec) * cos(lat)) / d2r + 180
        let v = (h / d2r, az.truncatingRemainder(dividingBy: 360))
        sunLock.lock(); sunCache = (key, loc, v); sunLock.unlock()
        return v
    }
}

// MARK: - Assets

enum CustomSceneAssets {
    private static let lock = NSLock()
    private static var placeholders: [UInt64: MTLTexture] = [:]
    private static var samplers: [UInt64: MTLSamplerState] = [:]

    /// Transparent black, for asset slots a package doesn't fill.
    static func placeholder(_ device: MTLDevice) -> MTLTexture {
        lock.lock(); defer { lock.unlock() }
        if let t = placeholders[device.registryID] { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        d.usage = .shaderRead
        let t = device.makeTexture(descriptor: d)!
        var z: UInt32 = 0
        t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &z, bytesPerRow: 4)
        placeholders[device.registryID] = t
        return t
    }

    static func sampler(_ device: MTLDevice) -> MTLSamplerState {
        lock.lock(); defer { lock.unlock() }
        if let s = samplers[device.registryID] { return s }
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear; sd.mipFilter = .linear
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        let s = device.makeSamplerState(descriptor: sd)!
        samplers[device.registryID] = s
        return s
    }

    /// The package's assets as textures (y up, as the scene's uv; colours raw sRGB values), four
    /// slots, placeholders where there's none. Images over 4096 px are refused.
    static func textures(for p: PreparedScene, device: MTLDevice) -> [MTLTexture] {
        let ph = placeholder(device)
        var out = [MTLTexture](repeating: ph, count: 4)
        let loader = MTKTextureLoader(device: device)
        for (i, a) in (p.manifest.assets ?? []).prefix(4).enumerated() {
            let url = p.packageDir.appendingPathComponent(a)
            guard let t = try? loader.newTexture(URL: url, options: [
                .SRGB: false, .origin: MTKTextureLoader.Origin.bottomLeft.rawValue, .generateMipmaps: true,
                .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue)]),
                  t.width <= 4096, t.height <= 4096 else { continue }
            out[i] = t
        }
        return out
    }
}
