//  WeatherFeed.swift — the reader side of weather.json (WeatherState.swift), and WeatherLink:
//  what each renderer uses to put the weather into Ocean Horizon's and Shallows' uniforms.
//
//  Every MetalRenderer owns one WeatherLink (one per host: saver, wallpaper displays, previews,
//  thumbnails), so no host needs any weather code of its own. It stats weather.json at most every
//  few seconds, and only while it draws a scene with a Weather param. A new reading eases in
//  over `blendSeconds` (CPU-side), so conditions never pop.
//
//  Test hooks: DOTSTUDIO_WEATHER_FAKE=<path to a WeatherState JSON> reads that file instead;
//  `WeatherLink.forced` (tools/gallery --weather) replaces the live feed outright.

import Foundation
import Metal
import QuartzCore
import simd

final class WeatherFeed {
    let fileURL: URL
    private(set) var state: WeatherState?
    /// Bumps whenever `state` changes.
    private(set) var revision = 0
    private var lastModified: Date?
    private var checked = false

    init(baseDir: URL) {
        if let fake = ProcessInfo.processInfo.environment["DOTSTUDIO_WEATHER_FAKE"], !fake.isEmpty {
            fileURL = URL(fileURLWithPath: fake)
        } else {
            fileURL = baseDir.appendingPathComponent(WeatherState.fileName)
        }
    }

    /// Re-reads weather.json if its mtime changed. Returns true when the state changed.
    @discardableResult
    func poll() -> Bool {
        let mod = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date
        guard !checked || mod != lastModified else { return false }
        checked = true
        lastModified = mod
        let new: WeatherState? = mod == nil ? nil
            : (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(WeatherState.self, from: $0) }
        guard new != state else { return false }
        state = new
        revision &+= 1
        return true
    }
}

/// The weather a renderer draws: the live feed eased between readings, or a scene's fixed pick.
final class WeatherLink {
    /// tools/gallery --weather: every "Live" scene shows this instead of the feed.
    static var forced: WeatherMix?
    static let blendSeconds: Double = 90
    static let pollSeconds: Double = 5

    private let feed: WeatherFeed
    private let lock = NSLock()
    private var lastPoll: CFTimeInterval = -.infinity
    private var started = false
    private var from = WeatherMix.clear
    private var blendStart: CFTimeInterval = -.infinity
    /// Cloud drift accumulated per effect instance (see `fill`).
    private var drift: [UUID: (t: Float, d: Double)] = [:]

    init(baseDir: URL) { feed = WeatherFeed(baseDir: baseDir) }

    /// Scenes with a Weather menu (param "weather": 0 = Live, else WeatherMix.menuConditions).
    static func usesWeather(_ kind: EffectKind) -> Bool { kind == .oceanHorizon || kind == .shallows }

    /// The scene's fixed condition, or nil for Live.
    static func fixedCondition(_ inst: EffectInstance) -> WeatherCondition? {
        let i = Int((inst.params["weather"] ?? 0).rounded())
        guard i >= 1, i <= WeatherMix.menuConditions.count else { return nil }
        return WeatherMix.menuConditions[i - 1]
    }

    /// Whether this style follows the live weather (the app fetches only while one does).
    static func followsLive(_ preset: Preset) -> Bool {
        preset.effects.contains { $0.enabled && usesWeather($0.kind) && fixedCondition($0) == nil }
    }

    /// The live weather right now (eased), polling the feed when due.
    func live(now: CFTimeInterval = CACurrentMediaTime(), wall: Date = Date()) -> WeatherMix {
        if let f = WeatherLink.forced { return f }
        lock.lock(); defer { lock.unlock() }
        if now - lastPoll >= WeatherLink.pollSeconds || !started {
            lastPoll = now
            let before = current(now, wall)
            if feed.poll(), started {
                from = before                  // ease from wherever the sky is now
                blendStart = now
            }                                  // (the first reading just is)
            started = true
        }
        return current(now, wall)
    }

    private func current(_ now: CFTimeInterval, _ wall: Date) -> WeatherMix {
        let target = feed.state.map { WeatherMix($0, at: wall) } ?? .clear
        let k = min(max((now - blendStart) / WeatherLink.blendSeconds, 0), 1)
        return WeatherMix.lerp(from, target, k * k * (3 - 2 * k))
    }

    /// Fills u.weather / weather2 / weather3 for a scene with a Weather menu (zero otherwise) and,
    /// when the pass draws weather, binds the scene's weather pipeline on `encoder` (fx_wx_ocean /
    /// fx_wx_shallows, Weather_fragment.h) in place of fx_fragment. `time` is the scene time the
    /// pass draws at (cloud drift is integrated against it); `format`: the pass's target format.
    func fill(_ u: inout FXUniforms, inst: EffectInstance, time: Float, wall: Date,
              encoder: MTLRenderCommandEncoder? = nil, format: MTLPixelFormat? = nil) {
        guard WeatherLink.usesWeather(inst.kind) else { return }
        defer {
            if u.weather2.w > 0.5, let encoder, let format,
               let pso = WeatherLink.pipeline(for: inst.kind, device: encoder.device, format: format,
                                              cumulus: WeatherLink.cumulus(u)) {
                encoder.setRenderPipelineState(pso)
            }
        }
        let mix = WeatherLink.fixedCondition(inst).map(WeatherMix.preset) ?? live(wall: wall)
        lock.lock()
        // Wind speeds the clouds up without jumping them: the drift is integrated frame to frame
        // (t + drift is the clouds' clock); a jump in t (a new style, a seek, the hourly wrap)
        // restarts it from the closed form, which is what a steady wind gives anyway.
        let rate = mix.driftRate - 1
        var d = rate * Double(time)
        if let s = drift[inst.id], time >= s.t, time - s.t < 1 { d = s.d + rate * Double(time - s.t) }
        if drift.count > 32 { drift.removeAll() }
        drift[inst.id] = (time, d)
        lock.unlock()
        WeatherLink.pack(&u, mix: mix, inst: inst, drift: Float(d))
    }

    // MARK: Pipelines

    private static let psoLock = NSLock()
    private static var psos: [String: MTLRenderPipelineState] = [:]
    private static var libraries: [UInt64: MTLLibrary] = [:]

    /// Ocean Horizon's cover is in the fair-weather cumulus' range (partly cloudy, no fog): draw it
    /// with fx_wx_ocean_cu, the copy that carries them (Weather_fragment.h). Matches nature_wxCu's
    /// support (cover 0.30…0.95, fog under 0.6), outside which the heaps are nothing.
    static func cumulus(_ u: FXUniforms) -> Bool {
        u.weather.x > 0.30 && u.weather.x < 0.95 && u.weather2.y < 0.6
    }

    /// The weather pipeline for a scene, built on first use (then cached per GPU and format).
    /// nil (no such function in the library) leaves fx_fragment drawing the scene's clear sky.
    static func pipeline(for kind: EffectKind, device: MTLDevice, format: MTLPixelFormat,
                         cumulus: Bool = false) -> MTLRenderPipelineState? {
        let name = kind == .shallows ? "fx_wx_shallows" : (cumulus ? "fx_wx_ocean_cu" : "fx_wx_ocean")
        let key = "\(device.registryID)/\(format.rawValue)/\(name)"
        psoLock.lock(); defer { psoLock.unlock() }
        if let p = psos[key] { return p }
        var lib = libraries[device.registryID]
        if lib == nil {
            // The metallib in this code's own bundle (the app, or the .saver — not the host's).
            lib = (try? device.makeDefaultLibrary(bundle: Bundle(for: WeatherLink.self))) ?? device.makeDefaultLibrary()
            libraries[device.registryID] = lib
        }
        guard let lib, let vfn = lib.makeFunction(name: "fx_vertex"), let ffn = lib.makeFunction(name: name) else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = vfn
        d.fragmentFunction = ffn
        d.colorAttachments[0].pixelFormat = format
        guard let p = try? device.makeRenderPipelineState(descriptor: d) else { return nil }
        psos[key] = p
        return p
    }

    /// Stateless packing (tools/gallery's GPU bench): `drift` = the clouds' clock offset, s.
    static func pack(_ u: inout FXUniforms, mix: WeatherMix, inst: EffectInstance, drift: Float) {
        (u.weather, u.weather2) = mix.packed
        let lightning: Float = (inst.params["lightning"] ?? 1) > 0.5 ? 1 : 0
        u.weather3 = simd_float4(drift, lightning, 0, 0)
    }
}
