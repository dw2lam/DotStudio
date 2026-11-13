//  Film.swift — photoreal, ray-traced "film" scenes: the Blender toolkit seam and the job runner.
//
//  The toolkit (Python package `dsfilm`, branch commute-film, tools/film/) turns a scene spec into
//  a .blend and renders Cycles stills and seamless video loops. dotstudio-mcp drives it through
//  `FilmToolkitAPI` (contract §6). What it makes plays through DotStudio's built-in `film` engine
//  (Shared/CustomFilm.swift, Engines/film/1/guide.md): a scene package of clips, one per variant,
//  which `FilmPackage.make` builds from a loop's output and CustomScenesAPI installs.
//
//  TODO(commute-film): the toolkit isn't in this build yet (it's mid-iteration on its own branch),
//  so `makeFilmToolkit` returns `UnavailableFilmToolkit` (the self-test: `FakeFilmToolkit`). When
//  tools/film merges, add `DSFilmToolkit: FilmToolkitAPI` beside them and return it from
//  makeFilmToolkit when the toolkit is installed:
//    • status()       Blender via FilmPaths.blender() (never launched to check), the toolkit's
//                     install and version, the GPU;
//    • templates()    the toolkit's scene templates (Commute first) with their params and spec;
//    • validate(spec) the toolkit's own spec check, without rendering;
//    • stillsCommand / loopCommand  Blender headless + dsfilm argv and env — FilmJobs runs them
//                     detached and nice'd; progress JSON to $DSFILM_PROGRESS; stills to
//                     <out>/<variant>.png, loops to <out>/<variant>.mov (HEVC);
//    • package(...)   FilmPackage.make (or the toolkit's own packager writing the same format).
//
//  Renders run as JOBS, never inside a tool call: each is a detached process group (its own
//  session, `nice`d, stdin from /dev/null, reparented to launchd), so it outlives the MCP process
//  (a client restart doesn't kill a 40-minute render) and is cancellable. State lives on disk:
//    <store>/film/<draft>/spec.json                 a film scene draft (create_film_scene)
//    <store>/jobs/<job>/job.json                    kind, draft, options, pgid, started/finished
//    <store>/jobs/<job>/log.txt, progress.json      the toolkit's log and {fraction, stage, eta_s}
//    <store>/jobs/<job>/exit_code                   written when the command ends
//    <store>/jobs/<job>/out/                        stills (<variant>.png) or the loop's clips
//    <store>/jobs/<job>/cancelled                   cancel_film_job was called
//  A finished loop job is packaged (scene package, engine "film", `clips` per variant) and
//  installed through CustomScenesAPI the first time film_job_status sees it done.

import AVFoundation
import CoreGraphics
import Foundation

struct FilmStatus {
    var blenderPath: String?
    var blenderVersion: String?
    var toolkitPulled: Bool
    var toolkitVersion: String?
    var gpu: String
    var notes: [String]
}

struct FilmCommand {
    var executable: String
    var arguments: [String]
    var environment: [String: String] = [:]
}

protocol FilmToolkitAPI {
    /// The toolkit is in this build (status() says whether this Mac has it installed).
    var isAvailable: Bool { get }
    func status() -> FilmStatus
    /// Scenes to start from (Commute first): id, name, summary, variants, cameras, loop, the
    /// editable params with their defaults, and the full starting `spec`.
    func templates() -> [JSONObject]
    /// Check a scene spec in the toolkit's format (dsfilm's schema) without rendering.
    func validate(spec: JSONObject) -> CSReport
    /// Cycles stills of the base scene, one PNG per variant into `outDir` (`<variant>.png`).
    /// The command reports progress by writing JSON {fraction, stage, eta_s} to $DSFILM_PROGRESS.
    func stillsCommand(spec: URL, outDir: URL, variants: [String], width: Int, height: Int, samples: Int) throws -> FilmCommand
    /// A seamless loop per variant (HEVC) into `outDir`, same progress protocol.
    func loopCommand(spec: URL, outDir: URL, variants: [String], seconds: Double, fps: Int, width: Int, height: Int,
                     quality: String) throws -> FilmCommand
    /// Turn a finished loop's output into a scene package (scene.json with engine "film" and a
    /// `clips` list, plus the clip files) in `package`.
    func package(loopOutput: URL, spec: JSONObject, sceneID: String, into package: URL) throws
}

enum FilmPaths {
    static func draftsDir(_ store: URL) -> URL { store.appendingPathComponent("film", isDirectory: true) }
    static func jobsDir(_ store: URL) -> URL { store.appendingPathComponent("jobs", isDirectory: true) }

    static let blenderApps = ["/Applications/Blender.app", SharedStore.realHome.path + "/Applications/Blender.app"]

    /// The toolkit targets this Blender (tools/film README: Blender 5.1).
    static let minimumBlender = "5.1"

    /// Blender's executable and version, if installed — read from Blender.app's Info.plist, so
    /// checking never launches Blender (a Blender process is gigabytes; only renders start one).
    static func blender() -> (path: String, version: String?)? {
        if let fake = ProcessInfo.processInfo.environment["DOTSTUDIO_MCP_FAKE_BLENDER"] {
            return fake == "none" ? nil : (fake, "5.1.0")
        }
        for app in blenderApps {
            let exe = app + "/Contents/MacOS/Blender"
            guard FileManager.default.isExecutableFile(atPath: exe) else { continue }
            let info = NSDictionary(contentsOfFile: app + "/Contents/Info.plist")
            return (exe, info?["CFBundleShortVersionString"] as? String)
        }
        return nil
    }

    static func versionAtLeast(_ v: String?, _ min: String) -> Bool {
        guard let v else { return false }
        let a = v.split(separator: ".").compactMap { Int($0) }, b = min.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }

    /// What to tell the user when Blender is missing or too old. DotStudio never installs it.
    static func installAdvice(found: (path: String, version: String?)?) -> String? {
        if let found, versionAtLeast(found.version, minimumBlender) { return nil }
        let why = found == nil ? "Blender isn't installed." : "Blender \(found!.version ?? "?") is older than \(minimumBlender), which the film toolkit needs."
        return why + " Ask the user to install it themselves (DotStudio never installs it): download Blender \(minimumBlender) or newer for macOS (Apple Silicon) from https://www.blender.org/download/, open the disk image and drag Blender into Applications, then open it once so macOS approves it, and quit it. It's free and about 1 GB on disk."
    }
}

/// The scene spec's "look" block: applied at render (bloom, halation) or at playback (grain).
enum FilmLook {
    static let schema: JSONObject = S.obj([
        "bloom": S.num("Soft glow around bright lights, 0 (off) … 1. Default 0.25.", min: 0, max: 1),
        "halation": S.num("Warm red-orange glow bleeding from bright edges, like film stock, 0 … 1. Default 0.15.", min: 0, max: 1),
        "grain": S.num("Live film grain, 0 … 1, added by DotStudio at playback (not baked into the clips, so it never loops visibly); the package carries it as the default. Default 0.2.", min: 0, max: 1),
    ])
    static let defaults: JSONObject = ["bloom": 0.25, "halation": 0.15, "grain": 0.2]

    static func merged(_ base: Any?, _ patch: Any?) -> JSONObject {
        var out = defaults
        for (k, v) in base as? JSONObject ?? [:] { out[k] = v }
        for (k, v) in patch as? JSONObject ?? [:] { out[k] = v }
        return out
    }
}

/// A finished loop's clips as a scene package for the built-in `film` engine (contract §6 / §8):
/// scene.json with `"engine": {"id": "film"}`, a `clips` entry per `<variant>.mov` in the loop's
/// output (day / golden / night / rain; anything else plays as `any`), the spec's look (its grain
/// becomes the style's starting Grain: EffectInstance.customScene), and the clips themselves.
enum FilmPackage {
    static let variants: Set<String> = ["day", "golden", "night", "rain", "any"]

    static func make(loopOutput: URL, spec: JSONObject, sceneID: String, into package: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: package.appendingPathComponent("clips"), withIntermediateDirectories: true)
        var clips: [JSONObject] = []
        let files = try fm.contentsOfDirectory(at: loopOutput, includingPropertiesForKeys: nil)
            .filter { ["mov", "mp4"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for f in files {
            let name = f.deletingPathExtension().lastPathComponent.lowercased()
            let variant = variants.contains(name) ? name : "any"
            let dst = "clips/\(variant).\(f.pathExtension.lowercased())"
            guard !clips.contains(where: { $0["file"] as? String == dst }) else { continue }
            try fm.copyItem(at: f, to: package.appendingPathComponent(dst))
            clips.append(["variant": variant, "file": dst, "loop": true])
        }
        guard !clips.isEmpty else { throw ToolError("The loop render left no clips (.mov) to package.") }
        let fps = ((spec["loop"] as? JSONObject)?["fps"] as? NSNumber)?.intValue ?? 24
        var m: JSONObject = ["format": 1, "id": sceneID, "name": spec["name"] as? String ?? "Film",
                             "engine": ["id": "film", "version": ">=1"], "fps": fps, "clips": clips,
                             "uses": ["sun", "weather"], "look": FilmLook.merged(spec["look"], nil),
                             "description": spec["description"] as? String ?? "A film scene rendered in Blender by DotStudio's film toolkit."]
        if let a = spec["author"] as? String { m["author"] = a }
        try JSON.data(m, pretty: true).write(to: package.appendingPathComponent("scene.json"))
    }
}

/// No toolkit in this build: status still reports Blender and the GPU; everything else says why.
struct UnavailableFilmToolkit: FilmToolkitAPI {
    static let message = "Making film scenes (photoreal, ray-traced Blender renders) isn't available in this build of DotStudio yet: it arrives with the film toolkit. Film scene packages made elsewhere still play (the film engine is built in); for new scenes, use the built-in scenes and custom shader scenes (list_scenes, list_engines)."
    var isAvailable: Bool { false }
    func status() -> FilmStatus {
        let b = FilmPaths.blender()
        return FilmStatus(blenderPath: b?.path, blenderVersion: b?.version, toolkitPulled: false, toolkitVersion: nil,
                          gpu: PreviewRenderer.gpuName, notes: [Self.message])
    }
    func templates() -> [JSONObject] { [] }
    func validate(spec: JSONObject) -> CSReport { CSReport(ok: false, diagnostics: [CSDiagnostic(message: Self.message, severity: "error")], warnings: []) }
    func stillsCommand(spec: URL, outDir: URL, variants: [String], width: Int, height: Int, samples: Int) throws -> FilmCommand { throw ToolError(Self.message) }
    func loopCommand(spec: URL, outDir: URL, variants: [String], seconds: Double, fps: Int, width: Int, height: Int, quality: String) throws -> FilmCommand { throw ToolError(Self.message) }
    func package(loopOutput: URL, spec: JSONObject, sceneID: String, into package: URL) throws { throw ToolError(Self.message) }
}

/// Self-test stand-in for the toolkit: the "render" is this executable's `--test-film-worker`,
/// which reports progress, sleeps and writes small PNG stills / real H.264 loops (so a packaged
/// scene installs, validates and plays through the real film engine) — enough to exercise
/// detaching, progress, cancel, packaging and install for real.
///   DOTSTUDIO_MCP_TEST_FAKES=1     with FakeCustomScenes: "installed" once pull_engine("film") ran;
///   DOTSTUDIO_MCP_TEST_FAKES=film  with the real engines (CustomScenesBridge): installed.
struct FakeFilmToolkit: FilmToolkitAPI {
    let store: URL
    var alwaysInstalled = false
    var isAvailable: Bool { true }
    var pulled: Bool { alwaysInstalled || FileManager.default.fileExists(atPath: AIStore.enginesDir(store).appendingPathComponent("film").path) }
    func status() -> FilmStatus {
        let b = FilmPaths.blender()
        return FilmStatus(blenderPath: b?.path, blenderVersion: b?.version, toolkitPulled: pulled,
                          toolkitVersion: pulled ? "1" : nil, gpu: PreviewRenderer.gpuName, notes: ["test toolkit"])
    }
    /// Commute, shaped like tools/film/scenes/commute/commute.json.
    func templates() -> [JSONObject] {
        let spec: JSONObject = [
            "scene": "commute", "variant": "day", "loop": ["seconds": 48, "fps": 24],
            "params": ["penguin_color": [0.0, 0.30, 0.47], "sway": 1.0],
            "render": ["engine": "cycles", "res": [1600, 1000], "samples": 384, "exposure": 0.0, "motion_blur": true],
            "stills": [["name": "day_wide", "camera": "wide", "frame": 1, "variant": "day"]],
            "animation": ["camera": "wide", "engine": "eevee", "res": [2560, 1600], "samples": 64],
        ]
        return [["id": "commute", "name": "Commute",
                 "summary": "A Japanese commuter-train interior at real scale, city scrolling past on a viaduct; an original penguin in a suit dozes on the end seat.",
                 "variants": ["day", "golden", "night", "rain"], "cameras": ["wide", "close", "aisle"], "loop": ["seconds": 48, "fps": 24],
                 "params": [["key": "penguin_color", "kind": "rgb", "default": [0.0, 0.30, 0.47], "label": "Passenger feathers"],
                            ["key": "sway", "kind": "number", "min": 0, "max": 2, "default": 1.0, "label": "Carriage sway"]],
                 "spec": spec]]
    }
    func validate(spec: JSONObject) -> CSReport {
        guard let scene = spec["scene"] as? String else {
            return CSReport(ok: false, diagnostics: [CSDiagnostic(line: nil, column: nil, message: "spec needs `scene`", severity: "error")], warnings: [])
        }
        if scene == "local" {
            // A new set: the toolkit imports <scene_dir>/scene.py (the stand-in only reads it).
            let src = (spec["scene_dir"] as? String).flatMap { try? String(contentsOfFile: $0 + "/scene.py", encoding: .utf8) } ?? ""
            var d: [CSDiagnostic] = []
            if !src.contains("def build(") { d.append(CSDiagnostic(line: 1, column: 1, message: "scene.py has no build(ctx)", severity: "error")) }
            if !src.contains("ASSETS") { d.append(CSDiagnostic(line: 1, column: 1, message: "scene.py has no ASSETS list", severity: "error")) }
            return CSReport(ok: d.isEmpty, diagnostics: d, warnings: [])
        }
        if !templates().contains(where: { $0["id"] as? String == scene }) {
            return CSReport(ok: false, diagnostics: [CSDiagnostic(message: "no scene module \"\(scene)\" in the film toolkit (list_film_templates)", severity: "error")], warnings: [])
        }
        return CSReport(ok: true, diagnostics: [], warnings: [])
    }
    private func worker(_ mode: String, _ outDir: URL, _ variants: [String], seconds: Double) -> FilmCommand {
        let me = executablePath()   // absolute: the job runs from its own folder
        let dur = ProcessInfo.processInfo.environment["DOTSTUDIO_MCP_FAKE_RENDER_SECONDS"] ?? "2"
        return FilmCommand(executable: me, arguments: ["--test-film-worker", mode, outDir.path, variants.joined(separator: ","), dur])
    }
    static let notInstalled = "The film toolkit isn't installed on this Mac (the self-test's stand-in installs with pull_engine(\"film\"))."
    func stillsCommand(spec: URL, outDir: URL, variants: [String], width: Int, height: Int, samples: Int) throws -> FilmCommand {
        guard pulled else { throw ToolError(Self.notInstalled) }
        return worker("stills", outDir, variants, seconds: 0)
    }
    func loopCommand(spec: URL, outDir: URL, variants: [String], seconds: Double, fps: Int, width: Int, height: Int, quality: String) throws -> FilmCommand {
        guard pulled else { throw ToolError(Self.notInstalled) }
        return worker("loop", outDir, variants, seconds: seconds)
    }
    func package(loopOutput: URL, spec: JSONObject, sceneID: String, into package: URL) throws {
        try FilmPackage.make(loopOutput: loopOutput, spec: spec, sceneID: sceneID, into: package)
    }

    /// Each variant's light, for the stand-in's stills and clips.
    static func tint(_ v: String) -> (top: (Double, Double, Double), bottom: (Double, Double, Double)) {
        switch v {
        case "golden": return ((0.95, 0.62, 0.32), (0.30, 0.16, 0.10))
        case "night": return ((0.06, 0.08, 0.18), (0.02, 0.02, 0.05))
        case "rain": return ((0.42, 0.47, 0.52), (0.12, 0.14, 0.17))
        default: return ((0.55, 0.72, 0.90), (0.18, 0.24, 0.20))
        }
    }

    /// A short seamless H.264 loop: the variant's sky gradient with a soft band of light drifting
    /// across it once per loop (the film engine plays it like a rendered clip).
    static func writeClip(_ url: URL, variant: String, seconds: Double = 1.5, fps: Int32 = 24, w: Int = 640, h: Int = 360) -> Bool {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        let n = Int(Double(fps) * seconds)
        let (top, bottom) = tint(variant)
        for i in 0..<n {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            guard let pool = adaptor.pixelBufferPool else { return false }
            var pbOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
            guard let pb = pbOut else { return false }
            CVPixelBufferLockBaseAddress(pb, [])
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            let bpr = CVPixelBufferGetBytesPerRow(pb)
            let phase = Double(i) / Double(n)                              // once across per loop
            for y in 0..<h {
                let fy = Double(y) / Double(h - 1)
                for x in 0..<w {
                    let fx = Double(x) / Double(w - 1)
                    var d = fx - phase; d -= d.rounded()                   // wraps: seamless
                    let band = 0.18 * exp(-d * d / 0.01) * (1 - fy)
                    func c(_ a: Double, _ b: Double) -> UInt8 { UInt8(max(0, min(1, a + (b - a) * fy + band)) * 255) }
                    let o = y * bpr + x * 4
                    base[o] = c(top.2, bottom.2); base[o + 1] = c(top.1, bottom.1); base[o + 2] = c(top.0, bottom.0); base[o + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        return writer.status == .completed
    }

    /// The fake render: progress over `dur` seconds, then outputs.
    static func runWorker(_ args: [String]) -> Never {
        let mode = args[0], out = URL(fileURLWithPath: args[1])
        let variants = args[2].split(separator: ",").map(String.init)
        let dur = Double(args[3]) ?? 2
        let progress = ProcessInfo.processInfo.environment["DSFILM_PROGRESS"].map { URL(fileURLWithPath: $0) }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let steps = 10
        for i in 0...steps {
            let f = Double(i) / Double(steps)
            let p: JSONObject = ["fraction": f, "stage": "\(mode) sample \(i)/\(steps)", "eta_s": dur * (1 - f)]
            if let progress { try? JSON.data(p).write(to: progress, options: .atomic) }
            print("[fake dsfilm] \(mode) \(Int(f * 100))%")
            fflush(stdout)
            if i < steps { Thread.sleep(forTimeInterval: dur / Double(steps)) }
        }
        for v in variants {
            if mode == "stills" {
                let (top, bottom) = tint(v)
                let c = CGContext(data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                c.setFillColor(CGColor(srgbRed: bottom.0, green: bottom.1, blue: bottom.2, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 64, height: 20))
                c.setFillColor(CGColor(srgbRed: top.0, green: top.1, blue: top.2, alpha: 1)); c.fill(CGRect(x: 0, y: 20, width: 64, height: 20))
                try? PreviewRenderer.png(c.makeImage()!).write(to: out.appendingPathComponent("\(v).png"))
            } else if !writeClip(out.appendingPathComponent("\(v).mov"), variant: v) {
                print("[fake dsfilm] couldn't write \(v).mov")
                exit(1)
            }
        }
        exit(0)
    }
}

/// The toolkit for this build (see the TODO at the top: none until tools/film merges).
func makeFilmToolkit(store: URL) -> FilmToolkitAPI {
    switch ProcessInfo.processInfo.environment["DOTSTUDIO_MCP_TEST_FAKES"] {
    case "1": return FakeFilmToolkit(store: store)
    case "film": return FakeFilmToolkit(store: store, alwaysInstalled: true)
    default: return UnavailableFilmToolkit()
    }
}

// MARK: - Jobs

struct FilmJob: Codable {
    var id: String
    var kind: String                // "stills" | "loop"
    var draft: String
    var variants: [String]
    var pgid: Int32
    var started: Date
    var command: [String]
    /// Set when a finished loop was packaged and installed.
    var installedScene: String?
    var packageError: String?
}

enum FilmJobs {
    static func dir(_ store: URL, _ id: String) -> URL { FilmPaths.jobsDir(store).appendingPathComponent(id, isDirectory: true) }

    static func load(_ store: URL, _ id: String) throws -> FilmJob {
        guard id.range(of: "^[a-z0-9-]{1,64}$", options: .regularExpression) != nil,
              let d = try? Data(contentsOf: dir(store, id).appendingPathComponent("job.json")) else {
            throw ToolError("No film job \"\(id)\". Job ids come from render_film_stills / render_film_loop.")
        }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try dec.decode(FilmJob.self, from: d)
    }

    static func save(_ store: URL, _ job: FilmJob) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(job).write(to: dir(store, job.id).appendingPathComponent("job.json"), options: .atomic)
    }

    /// Start `cmd` detached (own session, nice 10, stdin /dev/null, output to log.txt); the
    /// spawning shell exits at once, so the job is reparented to launchd and never a zombie here.
    static func start(store: URL, kind: String, draft: String, variants: [String],
                      command make: (_ outDir: URL) throws -> FilmCommand) throws -> FilmJob {
        let id = "\(kind)-" + String(UUID().uuidString.prefix(8)).lowercased()
        let jd = dir(store, id)
        try FileManager.default.createDirectory(at: jd.appendingPathComponent("out"), withIntermediateDirectories: true)
        let cmd: FilmCommand
        do { cmd = try make(jd.appendingPathComponent("out")) } catch {
            try? FileManager.default.removeItem(at: jd)
            throw error
        }
        let script = """
        cd "$1" || exit 1
        shift
        ( nice -n 10 "$@" </dev/null >>log.txt 2>&1; echo $? > exit_code.tmp; mv exit_code.tmp exit_code ) &
        echo $! > pid
        """
        var env = ProcessInfo.processInfo.environment
        for (k, v) in cmd.environment { env[k] = v }
        env["DSFILM_PROGRESS"] = jd.appendingPathComponent("progress.json").path
        let argv = ["/bin/sh", "-c", script, "dsfilm-job", jd.path, cmd.executable] + cmd.arguments
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        // The tool call runs on a dispatch thread, which blocks most signals; spawn inherits that
        // mask, and a render that can't receive SIGTERM can't be cancelled. Clear it, and put
        // the usual signals back to their defaults.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attr, &none)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for s in [SIGTERM, SIGINT, SIGHUP, SIGPIPE, SIGQUIT] { sigaddset(&defaults, s) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var pid: pid_t = 0
        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { cArgs.forEach { free($0) }; cEnv.forEach { free($0) } }
        let rc = posix_spawn(&pid, "/bin/sh", &actions, &attr, cArgs, cEnv)
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attr)
        guard rc == 0 else { throw ToolError("Couldn't start the render (posix_spawn \(rc)).") }
        var st: Int32 = 0
        waitpid(pid, &st, 0)     // the launcher shell only; the job runs on in its session
        let job = FilmJob(id: id, kind: kind, draft: draft, variants: variants, pgid: pid, started: Date(),
                          command: [cmd.executable] + cmd.arguments)
        save(store, job)
        return job
    }

    enum State: String { case running, done, failed, cancelled }

    static func state(_ store: URL, _ job: FilmJob) -> (State, Int32?) {
        let jd = dir(store, job.id)
        if FileManager.default.fileExists(atPath: jd.appendingPathComponent("cancelled").path) { return (.cancelled, nil) }
        if let s = try? String(contentsOf: jd.appendingPathComponent("exit_code"), encoding: .utf8),
           let code = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return (code == 0 ? .done : .failed, code)
        }
        if let s = try? String(contentsOf: jd.appendingPathComponent("pid"), encoding: .utf8),
           let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)), kill(pid, 0) == 0 || errno == EPERM {
            return (.running, nil)
        }
        // Started a moment ago: the launcher may not have written its pid yet.
        if Date().timeIntervalSince(job.started) < 3 { return (.running, nil) }
        return (.failed, nil)                    // the process vanished (reboot, killed)
    }

    static func progress(_ store: URL, _ job: FilmJob) -> JSONObject {
        guard let d = try? Data(contentsOf: dir(store, job.id).appendingPathComponent("progress.json")),
              let o = JSON.parse(d) as? JSONObject else { return [:] }
        return o
    }

    static func logTail(_ store: URL, _ job: FilmJob, lines: Int = 20) -> String {
        guard let s = try? String(contentsOf: dir(store, job.id).appendingPathComponent("log.txt"), encoding: .utf8) else { return "" }
        return s.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }

    static func cancel(_ store: URL, _ job: FilmJob) {
        kill(-job.pgid, SIGTERM)
        if let s = try? String(contentsOf: dir(store, job.id).appendingPathComponent("pid"), encoding: .utf8),
           let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(pid, SIGTERM)
        }
        try? Data().write(to: dir(store, job.id).appendingPathComponent("cancelled"))
        // Anything still alive after a grace period gets SIGKILL (best effort, from a detached helper).
        let pg = job.pgid
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { kill(-pg, SIGKILL) }
    }

    static func all(_ store: URL) -> [FilmJob] {
        let items = (try? FileManager.default.contentsOfDirectory(at: FilmPaths.jobsDir(store), includingPropertiesForKeys: nil)) ?? []
        return items.compactMap { try? load(store, $0.lastPathComponent) }.sorted { $0.started > $1.started }
    }
}
