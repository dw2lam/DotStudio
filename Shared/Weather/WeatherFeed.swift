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
    /// pass draws at (cloud drift is integrated against it); `chain`: which of the renderer's
    /// chains draws it (the outgoing and incoming chains of a crossfade — the hourly wrap's
    /// share their effect instances — each keep their own drift); `format`: the pass's target format.
    func fill(_ u: inout FXUniforms, inst: EffectInstance, time: Float, wall: Date, chain: Int = 0,
              encoder: MTLRenderCommandEncoder? = nil, format: MTLPixelFormat? = nil) {
        guard WeatherLink.usesWeather(inst.kind) else { return }
        defer {
            if u.weather2.w > 0.5, let encoder, let format,
               let pso = pipeline(for: inst.kind, device: encoder.device, format: format, cumulus: WeatherLink.cumulus(u)) {
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

    /// This link's pipelines once built (one renderer draws on one GPU, in one format): the shared
    /// table below keys them by a string made per lookup, which every weather frame would pay.
    private var built: [Int: MTLRenderPipelineState] = [:]

    private func pipeline(for kind: EffectKind, device: MTLDevice, format: MTLPixelFormat,
                          cumulus: Bool) -> MTLRenderPipelineState? {
        let key = (kind == .shallows ? 2 : (cumulus ? 1 : 0)) | Int(format.rawValue) << 2
        lock.lock()
        let hit = built[key]
        lock.unlock()
        if let hit { return hit }
        guard let p = WeatherLink.pipeline(for: kind, device: device, format: format, cumulus: cumulus) else { return nil }
        lock.lock(); built[key] = p; lock.unlock()
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
    static let functionNames = ["fx_wx_ocean", "fx_wx_ocean_cu", "fx_wx_shallows"]

    /// Hands over a renderer's library (the same metallib), so the pipelines don't load a
    /// second copy of it, and its pipeline archive if it has one.
    static func adopt(_ library: MTLLibrary, device: MTLDevice, archive: MTLBinaryArchive? = nil) {
        psoLock.lock(); defer { psoLock.unlock() }
        if libraries[device.registryID] == nil { libraries[device.registryID] = library }
        if let archive, archives[device.registryID] == nil { archives[device.registryID] = archive }
    }

    /// Whether every weather pipeline `preset` can switch to (what prewarm builds) is built — or
    /// can't be. A renderer that never waits on a compile (the screensaver's) holds its first
    /// frame for them, so the weather never pops in a moment after the scene.
    static func pipelinesReady(for preset: Preset, device: MTLDevice, format: MTLPixelFormat) -> Bool {
        let kinds = Set(preset.effects.filter { $0.enabled && usesWeather($0.kind) }.map(\.kind))
        var ready = true
        for k in kinds {
            for cumulus in k == .oceanHorizon ? [false, true] : [false] {
                // Starts the build if nothing has (a style not applied yet, after a purge).
                if pipeline(for: k, device: device, format: format, cumulus: cumulus, wait: false) != nil { continue }
                let name = k == .shallows ? functionNames[2] : (cumulus ? functionNames[1] : functionNames[0])
                psoLock.lock()
                if case .failed? = slots["\(device.registryID)/\(format.rawValue)/\(name)"] {} else { ready = false }
                psoLock.unlock()
            }
        }
        return ready
    }

    /// Builds, off the calling thread, the weather pipelines `preset`'s scenes can switch to
    /// mid-animation (Ocean Horizon both its skies, Shallows its one), so no frame waits on a
    /// compile when the weather turns.
    static func prewarm(for preset: Preset, device: MTLDevice, format: MTLPixelFormat) {
        let kinds = Set(preset.effects.filter { $0.enabled && usesWeather($0.kind) }.map(\.kind))
        for k in kinds {
            _ = pipeline(for: k, device: device, format: format, cumulus: false, wait: false)
            if k == .oceanHorizon { _ = pipeline(for: k, device: device, format: format, cumulus: true, wait: false) }
        }
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

    /// The weather pipeline for a scene, built on first use (then cached per GPU and format; a
    /// failure is cached too). nil (no such function in the library) leaves fx_fragment drawing
    /// the scene's clear sky. `wait: false` (prewarm) starts the build on a background queue
    /// and returns nil unless it's already there.
    static func pipeline(for kind: EffectKind, device: MTLDevice, format: MTLPixelFormat,
                         cumulus: Bool = false, wait: Bool = true) -> MTLRenderPipelineState? {
        let name = kind == .shallows ? functionNames[2] : (cumulus ? functionNames[1] : functionNames[0])
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
