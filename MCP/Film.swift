//  Film.swift — photoreal, ray-traced "film" scenes: the Blender toolkit seam and the job runner.
//
//  The toolkit (Python package `dsfilm`, branch commute-film, shipped as the pullable `film`
//  engine) turns a scene spec into a .blend and renders Cycles stills and seamless video loops.
//  dotstudio-mcp drives it through `FilmToolkitAPI` (contract §6); `UnavailableFilmToolkit`
//  stands in until the toolkit and the custom-scene engine are merged into this build.
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
    /// The toolkit (film engine) is in this build and pulled.
    var isAvailable: Bool { get }
    func status() -> FilmStatus
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

    static let blenderCandidates = ["/Applications/Blender.app/Contents/MacOS/Blender",
                                    SharedStore.realHome.path + "/Applications/Blender.app/Contents/MacOS/Blender"]

    /// Blender's path and version (`Blender --version`'s first line), if installed.
    static func blender() -> (path: String, version: String?)? {
        if let fake = ProcessInfo.processInfo.environment["DOTSTUDIO_MCP_FAKE_BLENDER"] { return (fake, "Blender 4.5.0 (test)") }
        guard let path = blenderCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["--version"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (path, nil) }
        let deadline = Date().addingTimeInterval(10)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return (path, nil) }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (path, out.split(separator: "\n").first.map(String.init))
    }
}

/// No toolkit in this build: status still reports Blender and the GPU; everything else says why.
struct UnavailableFilmToolkit: FilmToolkitAPI {
    static let message = "Film scenes (photoreal, ray-traced Blender renders) aren't available in this build of DotStudio yet: they arrive with the film engine. Use the built-in scenes for now (list_scenes)."
    var isAvailable: Bool { false }
    func status() -> FilmStatus {
        let b = FilmPaths.blender()
        return FilmStatus(blenderPath: b?.path, blenderVersion: b?.version, toolkitPulled: false, toolkitVersion: nil,
                          gpu: PreviewRenderer.gpuName, notes: [Self.message])
    }
    func validate(spec: JSONObject) -> CSReport { CSReport(ok: false, diagnostics: [CSDiagnostic(message: Self.message, severity: "error")], warnings: []) }
    func stillsCommand(spec: URL, outDir: URL, variants: [String], width: Int, height: Int, samples: Int) throws -> FilmCommand { throw ToolError(Self.message) }
    func loopCommand(spec: URL, outDir: URL, variants: [String], seconds: Double, fps: Int, width: Int, height: Int, quality: String) throws -> FilmCommand { throw ToolError(Self.message) }
    func package(loopOutput: URL, spec: JSONObject, sceneID: String, into package: URL) throws { throw ToolError(Self.message) }
}

/// Self-test stand-in (DOTSTUDIO_MCP_TEST_FAKES=1): the "render" is this executable's
/// `--test-film-worker`, which reports progress, sleeps and writes small PNGs / clip files —
/// enough to exercise detaching, progress, cancel, packaging and install for real.
struct FakeFilmToolkit: FilmToolkitAPI {
    let store: URL
    var isAvailable: Bool { true }
    var pulled: Bool { FileManager.default.fileExists(atPath: AIStore.enginesDir(store).appendingPathComponent("film").path) }
    func status() -> FilmStatus {
        FilmStatus(blenderPath: "/fake/Blender", blenderVersion: "Blender 4.5.0 (test)", toolkitPulled: pulled,
                   toolkitVersion: pulled ? "1" : nil, gpu: PreviewRenderer.gpuName, notes: ["test toolkit"])
    }
    func validate(spec: JSONObject) -> CSReport {
        spec["shots"] == nil && spec["scene"] == nil
            ? CSReport(ok: false, diagnostics: [CSDiagnostic(line: nil, column: nil, message: "spec needs `scene`", severity: "error")], warnings: [])
            : CSReport(ok: true, diagnostics: [], warnings: [])
    }
    private func worker(_ mode: String, _ outDir: URL, _ variants: [String], seconds: Double) -> FilmCommand {
        let me = executablePath()   // absolute: the job runs from its own folder
        let dur = ProcessInfo.processInfo.environment["DOTSTUDIO_MCP_FAKE_RENDER_SECONDS"] ?? "2"
        return FilmCommand(executable: me, arguments: ["--test-film-worker", mode, outDir.path, variants.joined(separator: ","), dur])
    }
    func stillsCommand(spec: URL, outDir: URL, variants: [String], width: Int, height: Int, samples: Int) throws -> FilmCommand {
        guard pulled else { throw ToolError("Pull the film engine first: pull_engine(\"film\").") }
        return worker("stills", outDir, variants, seconds: 0)
    }
    func loopCommand(spec: URL, outDir: URL, variants: [String], seconds: Double, fps: Int, width: Int, height: Int, quality: String) throws -> FilmCommand {
        guard pulled else { throw ToolError("Pull the film engine first: pull_engine(\"film\").") }
        return worker("loop", outDir, variants, seconds: seconds)
    }
    func package(loopOutput: URL, spec: JSONObject, sceneID: String, into package: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: package.appendingPathComponent("clips"), withIntermediateDirectories: true)
        var clips: [JSONObject] = []
        for f in (try fm.contentsOfDirectory(at: loopOutput, includingPropertiesForKeys: nil)) where f.pathExtension == "mov" {
            try fm.copyItem(at: f, to: package.appendingPathComponent("clips").appendingPathComponent(f.lastPathComponent))
            clips.append(["variant": f.deletingPathExtension().lastPathComponent, "file": "clips/" + f.lastPathComponent, "codec": "hevc"])
        }
        let m: JSONObject = ["format": 1, "id": sceneID, "name": spec["name"] as? String ?? "Film", "engine": ["id": "film", "version": ">=1"],
                             "entry": "clips", "fps": 30, "params": [], "clips": clips, "uses": ["sun", "weather"]]
        try JSON.data(m, pretty: true).write(to: package.appendingPathComponent("scene.json"))
        try Data("// film package: clips only\nfloat4 dsScene(float2 uv, DSContext ctx) { return 0; }\n".utf8)
            .write(to: package.appendingPathComponent("clips.txt"))
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
                let c = CGContext(data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                c.setFillColor(CGColor(srgbRed: 0.2, green: 0.3, blue: 0.4, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
                try? PreviewRenderer.png(c.makeImage()!).write(to: out.appendingPathComponent("\(v).png"))
            } else {
                try? Data("fake hevc \(v)".utf8).write(to: out.appendingPathComponent("\(v).mov"))
            }
        }
        exit(0)
    }
}

func makeFilmToolkit(store: URL) -> FilmToolkitAPI {
    if ProcessInfo.processInfo.environment["DOTSTUDIO_MCP_TEST_FAKES"] == "1" { return FakeFilmToolkit(store: store) }
    return UnavailableFilmToolkit()
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
