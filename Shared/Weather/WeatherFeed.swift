//  WeatherFeed.swift — the reader side of weather.json (WeatherState.swift), and WeatherLink:
//  what each renderer uses to put the weather into Ocean Horizon's, Shallows' and Meadow's uniforms.
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
    private let filePath: String
    private(set) var state: WeatherState?
    /// Bumps whenever `state` changes.
    private(set) var revision = 0
    private var lastModified: FileStamp?
    private var checked = false

    init(baseDir: URL) {
        if let fake = ProcessInfo.processInfo.environment["DOTSTUDIO_WEATHER_FAKE"], !fake.isEmpty {
            fileURL = URL(fileURLWithPath: fake)
        } else {
            fileURL = baseDir.appendingPathComponent(WeatherState.fileName)
        }
        filePath = fileURL.path
    }

    /// Re-reads weather.json if its mtime changed. Returns true when the state changed.
    @discardableResult
    func poll() -> Bool {
        let mod = FileStamp(path: filePath)
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
    /// Cloud drift accumulated per effect instance per chain (see `fill`).
    private struct DriftKey: Hashable { let id: UUID; let chain: Int }
    private var drift: [DriftKey: (t: Float, d: Double)] = [:]

    init(baseDir: URL) { feed = WeatherFeed(baseDir: baseDir) }

    /// Scenes with a Weather menu (param "weather": 0 = Live, else WeatherMix.menuConditions).
    static func usesWeather(_ kind: EffectKind) -> Bool { kind == .oceanHorizon || kind == .shallows || kind == .meadow }

    /// The scene's fixed condition, or nil for Live.
    static func fixedCondition(_ inst: EffectInstance) -> WeatherCondition? {
        let i = Int(saturating: inst.params["weather"] ?? 0, .toNearestOrAwayFromZero)
        guard i >= 1, i <= WeatherMix.menuConditions.count else { return nil }
        return WeatherMix.menuConditions[i - 1]
    }

    /// Whether this style follows the live weather (the app fetches only while one does).
    static func followsLive(_ preset: Preset) -> Bool {
        preset.effects.contains { $0.enabled && usesWeather($0.kind) && fixedCondition($0) == nil }
            || preset.customUses("weather")        // a Custom Scene whose manifest "uses" the weather
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

    /// Fills u.weather / weather2 / weather3 for a scene with a Weather menu (zero otherwise) and
    /// binds the scene's own pipeline on `encoder` (Weather_fragment.h: its clear sky or its
    /// weather, fixed or live — `functionName`) in place of fx_fragment. Call it after
    /// MetalRenderer.fillLiveSky (Follow the Sun picks the live copy). `time` is the scene time the
    /// pass draws at (cloud drift is integrated against it); `chain`: which of the renderer's
    /// chains draws it (the outgoing and incoming chains of a crossfade — the hourly wrap's
    /// share their effect instances — each keep their own drift); `format`: the pass's target format.
    func fill(_ u: inout FXUniforms, inst: EffectInstance, time: Float, wall: Date, chain: Int = 0,
              encoder: MTLRenderCommandEncoder? = nil, format: MTLPixelFormat? = nil) {
        guard WeatherLink.usesWeather(inst.kind) else { return }
        defer {
            if let encoder, let format,
               let pso = cachedPipeline(for: inst.kind, uniforms: u, device: encoder.device, format: format) {
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
        let key = DriftKey(id: inst.id, chain: chain)
        if let s = drift[key], time >= s.t, time - s.t < 1 { d = s.d + rate * Double(time - s.t) }
        if drift.count > 32 { drift.removeAll() }
        drift[key] = (time, d)
        lock.unlock()
        WeatherLink.pack(&u, mix: mix, inst: inst, drift: Float(d))
    }

    // MARK: Pipelines

    /// This link's pipelines once built (one renderer draws on one GPU, in one format), by
    /// fragment function name: the shared table below keys them by a string built per lookup
    /// (GPU + format + name), which every weather frame would otherwise pay.
    private var built: [String: MTLRenderPipelineState] = [:]

    private func cachedPipeline(for kind: EffectKind, uniforms u: FXUniforms, device: MTLDevice,
                                format: MTLPixelFormat) -> MTLRenderPipelineState? {
        guard let name = WeatherLink.functionName(for: kind, uniforms: u) else { return nil }
        lock.lock()
        let hit = built[name]
        lock.unlock()
        if let hit { return hit }
        guard let p = WeatherLink.pipeline(named: name, device: device, format: format) else { return nil }
        lock.lock(); built[name] = p; lock.unlock()
        return p
    }

    // Per GPU and format, process-wide (a saver host keeps them past its views: see purge()).
    // The lock guards the tables only, never a compile: a pipeline is built outside it, and a
    // caller wanting one already being built (a prewarm) waits for that build, not a second.
    private enum Slot {
        case ready(MTLRenderPipelineState)
        case failed                                      // not retried until purge()
        case building(DispatchGroup)
    }
    private static let psoLock = NSLock()
    private static var slots: [String: Slot] = [:]
    private static var libraries: [UInt64: MTLLibrary] = [:]
    /// The saver's pipeline archive (PipelineArchive.swift), which holds these pipelines too.
    private static var archives: [UInt64: MTLBinaryArchive] = [:]
    /// Every function these pipelines are built from (PipelineArchive harvests them all).
    static let functionNames = ["fx_ocean", "fx_ocean_live", "fx_wx_ocean", "fx_wx_ocean_live",
                                "fx_wx_ocean_cu", "fx_wx_ocean_cu_live", "fx_shallows", "fx_wx_shallows",
                                "fx_meadow_0", "fx_wx_meadow_0", "fx_meadow_1", "fx_wx_meadow_1",
                                "fx_meadow_2", "fx_wx_meadow_2", "fx_meadow_3", "fx_wx_meadow_3"]

    private static let meadowClear = ["fx_meadow_0", "fx_meadow_1", "fx_meadow_2", "fx_meadow_3"]
    private static let meadowWx = ["fx_wx_meadow_0", "fx_wx_meadow_1", "fx_wx_meadow_2", "fx_wx_meadow_3"]

    /// The fragment function a pass of `kind` draws with, from its packed uniforms (nil: not one
    /// of these scenes — fx_fragment draws it). Weather (u.weather2.w) or the scene's clear sky;
    /// for Ocean Horizon also the cumulus copy (`cumulus`) and the live sky (nature_live: Follow
    /// the Sun on, and fillLiveSky's sky filled in) — each its own function: Weather_fragment.h.
    static func functionName(for kind: EffectKind, uniforms u: FXUniforms) -> String? {
        let wx = u.weather2.w > 0.5
        switch kind {
        case .oceanHorizon:
            let name = wx ? (cumulus(u) ? "fx_wx_ocean_cu" : "fx_wx_ocean") : "fx_ocean"
            return u.p1.y > 0.5 && u.sky.y > 0.5 ? name + "_live" : name
        case .shallows:
            return wx ? "fx_wx_shallows" : "fx_shallows"
        case .meadow:                                    // (one per landscape: p2.x)
            let land = min(max(Int(saturating: u.p2.x, .toNearestOrAwayFromZero), 0), 3)
            return wx ? meadowWx[land] : meadowClear[land]
        default:
            return nil
        }
    }

    /// Meadow's pipelines' GPU cost, ns per drawn pixel on an Apple GPU — the screensaver's cost
    /// cap (MetalRenderer.costCapScale). Measured with tools/gallery --gpubench --solo at
    /// 5120×2880 on an M5 Pro (2026-11-11), the median of the Meadow style (Wildflowers 0.8 — the
    /// heaviest of the four presets' settings) per landscape; a weather pipeline at its worst
    /// condition (heavy snow): Meadow 7.6 / 12.7 ms, Rolling Hills 4.4 / 9.0, Tall Grass 9.2 /
    /// 16.0, Hillside 4.2 / 9.1. nil: not one of these (no cap).
    static func costNsPerPixel(_ functionName: String) -> Double? {
        let px = 5120.0 * 2880.0 / 1e6                  // ms at 5K → ns a pixel
        switch functionName {
        case "fx_meadow_0": return 7.6 / px
        case "fx_meadow_1": return 4.4 / px
        case "fx_meadow_2": return 9.2 / px
        case "fx_meadow_3": return 4.2 / px
        case "fx_wx_meadow_0": return 12.7 / px
        case "fx_wx_meadow_1": return 9.0 / px
        case "fx_wx_meadow_2": return 16.0 / px
        case "fx_wx_meadow_3": return 9.1 / px
        default: return nil
        }
    }

    /// The functions `preset`'s scenes can switch between mid-animation: for a fixed Weather pick
    /// just its own; following the live weather, the clear sky, the weather and (Ocean Horizon)
    /// the cumulus copy — of the fixed or the live sky, as Follow the Sun is set.
    static func functionNames(for preset: Preset) -> Set<String> {
        var names = Set<String>()
        for inst in preset.effects where inst.enabled && usesWeather(inst.kind) {
            var u = FXUniforms()
            inst.pack(into: &u)
            if (inst.params["live"] ?? 0) > 0.5 { u.sky.y = 1 }      // (as fillLiveSky fills it)
            let mixes = fixedCondition(inst).map { [WeatherMix.preset($0)] }
                ?? [.clear, .preset(.rain), .preset(.partlyCloudy)]  // (clear sky, weather, cumulus)
            for m in mixes {
                pack(&u, mix: m, inst: inst, drift: 0)
                if let n = functionName(for: inst.kind, uniforms: u) { names.insert(n) }
            }
        }
        return names
    }

    /// Hands over a renderer's library (the same metallib), so the pipelines don't load a
    /// second copy of it, and its pipeline archive if it has one.
    static func adopt(_ library: MTLLibrary, device: MTLDevice, archive: MTLBinaryArchive? = nil) {
        psoLock.lock(); defer { psoLock.unlock() }
        if libraries[device.registryID] == nil { libraries[device.registryID] = library }
        if let archive, archives[device.registryID] == nil { archives[device.registryID] = archive }
    }

    /// Whether every pipeline `preset` can switch to (what prewarm builds) is built — or can't be.
    /// A renderer that never waits on a compile (the screensaver's) holds its first frame for
    /// them, so neither the scene nor its weather waits on a compile once it is showing.
    static func pipelinesReady(for preset: Preset, device: MTLDevice, format: MTLPixelFormat) -> Bool {
        var ready = true
        for name in functionNames(for: preset) {
            // Starts the build if nothing has (a style not applied yet, after a purge).
            if pipeline(named: name, device: device, format: format, wait: false) != nil { continue }
            psoLock.lock()
            if case .failed? = slots["\(device.registryID)/\(format.rawValue)/\(name)"] {} else { ready = false }
            psoLock.unlock()
        }
        return ready
    }

    /// Builds, off the calling thread, the pipelines `preset`'s scenes can switch to mid-animation
    /// (functionNames(for:)), so no frame waits on a compile when the weather turns.
    static func prewarm(for preset: Preset, device: MTLDevice, format: MTLPixelFormat) {
        for name in functionNames(for: preset) { _ = pipeline(named: name, device: device, format: format, wait: false) }
    }

    /// Frees the pipelines and libraries (the screensaver's teardown: its host process
    /// outlives the views). The next use builds them again.
    static func purge() {
        psoLock.lock(); defer { psoLock.unlock() }
        slots = slots.filter { if case .building = $0.value { return true } else { return false } }
        libraries = [:]
        archives = [:]
    }

    /// Ocean Horizon's cover is in the fair-weather cumulus' range (partly cloudy, no fog): draw it
    /// with fx_wx_ocean_cu, the copy that carries them (Weather_fragment.h). Matches nature_wxCu's
    /// support (cover 0.30…0.95, fog under 0.6), outside which the heaps are nothing.
    static func cumulus(_ u: FXUniforms) -> Bool {
        u.weather.x > 0.30 && u.weather.x < 0.95 && u.weather2.y < 0.6
    }

    /// The pipeline a pass of `kind` with these (packed) uniforms draws with (functionName), or
    /// nil: fx_fragment draws it (any other scene, or a pipeline that failed to build — its own
    /// case of fx_fragment then draws the same frame).
    static func pipeline(for kind: EffectKind, uniforms u: FXUniforms, device: MTLDevice,
                         format: MTLPixelFormat) -> MTLRenderPipelineState? {
        functionName(for: kind, uniforms: u).flatMap { pipeline(named: $0, device: device, format: format) }
    }

    /// The pipeline for one of `functionNames`, built on first use (then cached per GPU and
    /// format; a failure is cached too). nil: no such function in the library. `wait: false`
    /// (prewarm) starts the build on a background queue and returns nil unless it's already there.
    static func pipeline(named name: String, device: MTLDevice, format: MTLPixelFormat,
                         wait: Bool = true) -> MTLRenderPipelineState? {
        let key = "\(device.registryID)/\(format.rawValue)/\(name)"
        psoLock.lock()
        switch slots[key] {
        case .ready(let p)?:
            psoLock.unlock(); return p
        case .failed?:
            psoLock.unlock(); return nil
        case .building(let g)?:
            psoLock.unlock()
            guard wait else { return nil }
            g.wait()                                     // the build already under way
            psoLock.lock(); defer { psoLock.unlock() }
            if case .ready(let p)? = slots[key] { return p }
            return nil
        case nil:
            break
        }
        let g = DispatchGroup()
        g.enter()
        slots[key] = .building(g)
        let cachedLib = libraries[device.registryID]
        let archive = archives[device.registryID]
        psoLock.unlock()

        func build() -> MTLRenderPipelineState? {
            // The metallib in this code's own bundle (the app, or the .saver — not the host's),
            // unless a renderer handed over its own (adopt).
            let lib = cachedLib ?? (try? device.makeDefaultLibrary(bundle: Bundle(for: WeatherLink.self))) ?? device.makeDefaultLibrary()
            let pso = lib.flatMap { FXPipelines.renderDescriptor($0, fragment: name, format: format, archive: archive) }
                .flatMap { FXPipelines.makeRender($0, device: device) }
            psoLock.lock()
            if cachedLib == nil, let lib, libraries[device.registryID] == nil { libraries[device.registryID] = lib }
            slots[key] = pso.map(Slot.ready) ?? .failed
            psoLock.unlock()
            g.leave()
            return pso
        }
        if wait { return build() }
        DispatchQueue.global(qos: .utility).async { _ = build() }
        return nil
    }

    /// Stateless packing (tools/gallery's GPU bench): `drift` = the clouds' clock offset, s.
    static func pack(_ u: inout FXUniforms, mix: WeatherMix, inst: EffectInstance, drift: Float) {
        (u.weather, u.weather2) = mix.packed
        let lightning: Float = (inst.params["lightning"] ?? 1) > 0.5 ? 1 : 0
        u.weather3 = simd_float4(drift, lightning, 0, 0)
    }
}
