//  FXPipelines.swift — the render and compute pipelines MetalRenderer draws with, per GPU and
//  pixel format, process-wide, and how a new renderer gets them without waiting.
//
//  fx_fragment (Shaders.metal) is one switch over every effect and scene: ~3.2 s to compile
//  from cold on an M5 Pro. The system's shader cache hides that after the first time — but each
//  update ships a new metallib, so the first screensaver start after one sat on the frozen
//  desktop while legacyScreenSaver compiled it, before its view even existed. So:
//
//  - A binary archive (PipelineArchive.swift): the app compiles the saver's pipelines once per
//    saver build / macOS / GPU into the shared folder; built from it, each pipeline is a
//    lookup of about a millisecond.
//  - `.fastStart` (the screensaver) never waits on a compile: what the archive doesn't have is
//    compiled in the background, and frames are skipped until theirs exist (the saver shows
//    black, then fades its view in on the first frame).
//  - Pipelines nothing has needed yet (the music veil, the error-diffusion kernels) are built
//    on first use rather than at init.
//  - The heavy scenes also have pipelines of their own (ScenePipelines, below), started when a
//    style is applied; fx_fragment stands in for one until it's built.
//
//  (Specializing fx_fragment per effect with a function constant compiles in 20–200 ms, but the
//  backend optimizes the smaller function differently under fast math: up to 6 levels off on a
//  few pixels. Not the same frame, so not used. The scenes' own functions are specialized in the
//  source instead — the id a literal, folded by the front end — and do draw the same frame.)
//
//  A blocking host (the app, the tools) draws exactly what it always did.

import Metal
import Foundation

final class FXPipelines {
    /// How a renderer waits for its pipelines.
    enum Mode {
        /// The über-shader is built before the renderer is used; the rest on first use. The
        /// app's previews, wallpaper, thumbnails and the tools.
        case blocking
        /// Never waits on a compile (the screensaver): see the header.
        case fastStart
    }

    let device: MTLDevice
    let format: MTLPixelFormat
    let library: MTLLibrary
    /// The pipelines' precompiled binaries, when a current one was found (PipelineArchive).
    let archive: MTLBinaryArchive?

    private let lock = NSLock()
    private enum Slot {
        case ready(AnyObject)
        case building(DispatchGroup)
        case failed
    }
    private var slots: [String: Slot] = [:]
    /// Bumped by purge(): a build that finishes after it is dropped, not stored.
    private var generation = 0

    private init(device: MTLDevice, format: MTLPixelFormat, library: MTLLibrary, archive: MTLBinaryArchive?) {
        self.device = device
        self.format = format
        self.library = library
        self.archive = archive
    }

    // MARK: Shared instances

    private static let tableLock = NSLock()
    private static var table: [String: FXPipelines] = [:]

    /// The pipelines for `device` and `format` in this process (the saver host builds a renderer
    /// per display, and rebuilds them after a teardown). `makeLibrary` and `loadArchive` run
    /// only when there is no instance yet.
    static func shared(device: MTLDevice, format: MTLPixelFormat, makeLibrary: () -> MTLLibrary?,
                       loadArchive: (MTLDevice) -> MTLBinaryArchive?) -> FXPipelines? {
        let key = "\(device.registryID)/\(format.rawValue)"
        tableLock.lock(); defer { tableLock.unlock() }
        if let p = table[key] { return p }
        guard let lib = makeLibrary() else { return nil }
        let p = FXPipelines(device: device, format: format, library: lib, archive: loadArchive(device))
        table[key] = p
        return p
    }

    /// Frees every pipeline (the screensaver's teardown: its host process outlives the views).
    /// The next renderer builds them again — from the archive or the system's shader cache.
    static func purge() {
        tableLock.lock(); defer { tableLock.unlock() }
        for p in table.values {
            p.lock.lock(); p.generation += 1; p.slots = [:]; p.lock.unlock()
        }
        table = [:]
    }

    // MARK: Descriptors (PipelineArchive harvests exactly these)

    /// A fullscreen pass: fx_vertex + the fragment function `fragment`, one colour attachment.
    static func renderDescriptor(_ library: MTLLibrary, fragment: String, format: MTLPixelFormat,
                                 archive: MTLBinaryArchive?) -> MTLRenderPipelineDescriptor? {
        guard let v = library.makeFunction(name: "fx_vertex"), let f = library.makeFunction(name: fragment) else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = v
        d.fragmentFunction = f
        d.colorAttachments[0].pixelFormat = format
        if let archive { d.binaryArchives = [archive] }
        return d
    }

    static func computeDescriptor(_ library: MTLLibrary, name: String,
                                  archive: MTLBinaryArchive?) -> MTLComputePipelineDescriptor? {
        guard let f = library.makeFunction(name: name) else { return nil }
        let d = MTLComputePipelineDescriptor()
        d.computeFunction = f
        if let archive { d.binaryArchives = [archive] }
        return d
    }

    /// A render pipeline: from the archive (a lookup — a miss throws at once), else compiled.
    static func makeRender(_ d: MTLRenderPipelineDescriptor, device: MTLDevice,
                           archiveOnly: Bool = false) -> MTLRenderPipelineState? {
        if !d.binaryArchives.isNilOrEmpty,
           let p = (try? device.makeRenderPipelineState(descriptor: d, options: .failOnBinaryArchiveMiss))?.0 {
            return p
        }
        return archiveOnly ? nil : try? device.makeRenderPipelineState(descriptor: d)
    }

    static func makeCompute(_ d: MTLComputePipelineDescriptor, device: MTLDevice,
                            archiveOnly: Bool = false) -> MTLComputePipelineState? {
        if !d.binaryArchives.isNilOrEmpty,
           let p = (try? device.makeComputePipelineState(descriptor: d, options: .failOnBinaryArchiveMiss))?.0 {
            return p
        }
        return archiveOnly ? nil : (try? device.makeComputePipelineState(descriptor: d, options: []))?.0
    }

    static let uberFunction = "fx_fragment"
    /// The music veil's passes (down, composite), and the error-diffusion kernels.
    static let veilFunctions = ["fx_veil_down", "fx_veil"]
    static let ditherKernels = ["dither_prep", "dither_wave", "dither_riem", "dither_relax", "dither_final"]

    // MARK: Pipelines

    /// The über-shader. `wait: false` starts it in the background if nothing has, and returns
    /// nil until it's built (at once when the archive has it).
    func uber(wait: Bool) -> MTLRenderPipelineState? {
        render(FXPipelines.uberFunction, wait: wait)
    }

    /// A pipeline already built (or nil): just the table lookup, no build closure made — the
    /// path every call takes once a pipeline exists.
    private func ready(_ key: String) -> AnyObject? {
        lock.lock(); defer { lock.unlock() }
        if case .ready(let p)? = slots[key] { return p }
        return nil
    }

    func veil(down: Bool, wait: Bool) -> MTLRenderPipelineState? {
        render(FXPipelines.veilFunctions[down ? 0 : 1], wait: wait)
    }

    /// Effect `id`'s own pipeline (ScenePipelines), or nil: it has none, it isn't built yet
    /// (`wait: false` starts the build — from the archive at once, else in the background), or
    /// it failed. fx_fragment draws the same frame meanwhile.
    func scene(_ id: Int32, wait: Bool) -> MTLRenderPipelineState? {
        guard let name = ScenePipelines.functionName(id) else { return nil }
        return render(name, wait: wait)
    }

    func sceneState(_ id: Int32) -> State {
        guard let name = ScenePipelines.functionName(id) else { return .failed }
        return state(name)
    }

    /// Starts building, off the calling thread, the own pipelines of `ids` (a style just
    /// applied), so its frames draw with them as soon as possible and never wait for one.
    func prewarmScenes(_ ids: [Int32]) {
        for id in ids { _ = scene(id, wait: false) }
    }

    func compute(_ name: String, wait: Bool) -> MTLComputePipelineState? {
        if let p = ready(name) as? MTLComputePipelineState { return p }
        return get(name, wait: wait) { [library, device, archive] archiveOnly in
            FXPipelines.computeDescriptor(library, name: name, archive: archive)
                .flatMap { FXPipelines.makeCompute($0, device: device, archiveOnly: archiveOnly) }
        } as? MTLComputePipelineState
    }

    /// Where a pipeline is: built, still to come (building, or never asked for), or impossible
    /// (no such function, a compile error).
    enum State { case ready, pending, failed }
    var uberState: State { state(FXPipelines.uberFunction) }
    func veilState(down: Bool) -> State { state(FXPipelines.veilFunctions[down ? 0 : 1]) }
    func computeState(_ name: String) -> State { state(name) }

    private func state(_ key: String) -> State {
        lock.lock(); defer { lock.unlock() }
        switch slots[key] {
        case .ready?: return .ready
        case .failed?: return .failed
        default: return .pending
        }
    }

    private func render(_ name: String, wait: Bool) -> MTLRenderPipelineState? {
        if let p = ready(name) as? MTLRenderPipelineState { return p }
        return get(name, wait: wait) { [library, device, format, archive] archiveOnly in
            FXPipelines.renderDescriptor(library, fragment: name, format: format, archive: archive)
                .flatMap { FXPipelines.makeRender($0, device: device, archiveOnly: archiveOnly) }
        } as? MTLRenderPipelineState
    }

    /// The pipeline under `key`, made once whoever asks: on this thread (`wait`), or else looked
    /// up in the archive here and, failing that, compiled on a background queue — nil until it's
    /// there. A failure is remembered (until purge()).
    /// - build: makes the pipeline; with `archiveOnly`, only if the archive has it (no compile).
    private func get(_ key: String, wait: Bool, build: @escaping (_ archiveOnly: Bool) -> AnyObject?) -> AnyObject? {
        lock.lock()
        switch slots[key] {
        case .ready(let p)?:
            lock.unlock(); return p
        case .failed?:
            lock.unlock(); return nil
        case .building(let g)?:
            lock.unlock()
            guard wait else { return nil }
            g.wait()
            lock.lock(); defer { lock.unlock() }
            if case .ready(let p)? = slots[key] { return p }
            return nil
        case nil:
            break
        }
        let g = DispatchGroup()
        g.enter()
        slots[key] = .building(g)
        let gen = generation
        lock.unlock()

        let finish: (AnyObject?) -> Void = { [weak self] p in
            if let self {
                self.lock.lock()
                if self.generation == gen { self.slots[key] = p.map(Slot.ready) ?? .failed }
                self.lock.unlock()
            }
            g.leave()
        }
        if wait {
            let p = build(false)
            finish(p)
            return p
        }
        if archive != nil, let p = build(true) {
            finish(p)
            return p
        }
        DispatchQueue.global(qos: .userInitiated).async { finish(build(false)) }
        return nil
    }
}

/// The effects and scenes drawn with a fragment function of their own, fx_scene_<id>
/// (SceneEntries.metal: fx_fragment's body with the id a literal, so the function holds that
/// one case), instead of the über-shader.
///
/// Why: fx_fragment is allocated registers — and so occupancy — for its heaviest case, and every
/// effect pays for it. The list is chosen by measurement — tools/gallery --pipebench, at
/// 5120×2880, 3 interleaved rounds against a reference — keeping the ids whose own function is
/// meaningfully (≥ 10 %) faster with none of their presets slower. That came out as every id
/// measured (scenes 10–70 %, one-tap passes ~0.6 → ~0.2 ms at 5K; Grain Wash's Soft Focus only
/// 3 %, but its other presets ~23 %). Re-measure when a scene's code changes much.
///
/// A scene's own function draws the über-shader's frame (≤ 1 level on a few pixels: compiled
/// apart). fx_fragment keeps every case, so it stands in whenever the own pipeline isn't built
/// yet or failed: the renderer never waits for one mid-animation (MetalRenderer.scenePipeline).
/// Ocean Horizon (59), Shallows (67) and Meadow (78) have theirs through WeatherLink (Weather_fragment.h).
enum ScenePipelines {
    /// Every id with an fx_scene_<id> in SceneEntries.metal. Keep the two lists the same.
    /// 0 / 1: the source passes (photo or video; the gradient behind a scene); 38: the
    /// error-diffusion dithers' upscale; 41: the style crossfade; the rest: effects and scenes.
    static let ids: [Int32] = Array(0...58) + Array(60...66) + Array(68...72) + Array(74...77) + [79, 80, 90]

    /// By id (dense: ids are small), so a pass's lookup is an index, not a hash or a new string.
    private static let names: [String?] = {
        var t = [String?](repeating: nil, count: 128)
        for id in ids where id >= 0 && Int(id) < t.count { t[Int(id)] = "fx_scene_\(id)" }
        return t
    }()

    /// The fragment function effect `id` draws with when its pipeline is ready, or nil (fx_fragment).
    @inline(__always)
    static func functionName(_ id: Int32) -> String? {
        id >= 0 && Int(id) < names.count ? names[Int(id)] : nil
    }

    /// Every such function (PipelineArchive harvests them all).
    static var functionNames: [String] { ids.compactMap(functionName) }

    /// The ids among `preset`'s passes that have a function of their own: its enabled effects
    /// (and a dither's upscale, 38), a Look's source pass (0: a photo or video; 1: the gradient —
    /// a scene has none: MetalRenderer.encodePasses) and the crossfade into the next style (41).
    static func ids(for preset: Preset) -> [Int32] {
        var out: [Int32] = []
        func add(_ id: Int32) { if functionName(id) != nil, !out.contains(id) { out.append(id) } }
        for inst in preset.effects where inst.enabled {
            add(inst.kind.shaderID)
            if inst.kind == .dither { add(38) }
        }
        if !preset.isScene { add(0); add(1) }
        add(41)
        return out
    }
}

private extension Optional where Wrapped == [MTLBinaryArchive] {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}
