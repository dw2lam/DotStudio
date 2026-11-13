//  FilmToolkit.swift — DSFilmToolkit: the real FilmToolkitAPI, over the Blender film toolkit
//  (tools/film; shipped as the pullable `film` engine pack: dsfilm/, run.py, job.py, templates).
//
//  Where the toolkit is:
//    • DOTSTUDIO_FILM_TOOLKIT=<a tools/film folder>        (development)
//    • <store>/engines/film/<version>/                       (the pulled pack; the newest wins)
//  Everything goes through the toolkit's own driver, job.py (plain python3, never Blender):
//    templates / validate / env    run synchronously from a tool call (a fraction of a second);
//    stills / loop                 the commands FilmJobs runs detached and nice'd. job.py runs
//                                  Blender headless (run.py) once per variant, one Blender at a time
//                                  (a lock in <store>/jobs, and it waits while another Blender runs),
//                                  turns run.py's PROGRESS lines into $DSFILM_PROGRESS, and for a
//                                  loop encodes the frames to <out>/<variant>.mov (HEVC) itself.
//  Blender is found by reading Blender.app's Info.plist (FilmPaths.blender) and never launched
//  except by a render job.

import AVFoundation
import Foundation

struct DSFilmToolkit: FilmToolkitAPI {
    let store: URL

    struct Install {
        let root: URL
        let version: String?
        let source: String
    }

    var isAvailable: Bool { true }

    // MARK: Finding things

    /// The toolkit folder: DOTSTUDIO_FILM_TOOLKIT, else the newest pulled pack.
    static func locate(store: URL) -> Install? {
        let fm = FileManager.default
        func root(_ u: URL) -> URL? {
            // A pack unzipped as-is has a top-level film/ folder.
            for r in [u, u.appendingPathComponent("film", isDirectory: true)]
            where ["run.py", "job.py", "dsfilm/__init__.py"].allSatisfy({ fm.fileExists(atPath: r.appendingPathComponent($0).path) }) {
                return r
            }
            return nil
        }
        func version(_ u: URL) -> String? {
            (try? Data(contentsOf: u.appendingPathComponent("engine.json"))).flatMap { JSON.parse($0) as? JSONObject }?["version"] as? String
        }
        if let p = ProcessInfo.processInfo.environment["DOTSTUDIO_FILM_TOOLKIT"], !p.isEmpty {
            guard let r = root(URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)) else { return nil }
            return Install(root: r, version: version(r), source: "DOTSTUDIO_FILM_TOOLKIT")
        }
        let base = AIStore.enginesDir(store).appendingPathComponent("film", isDirectory: true)
        let found = ((try? fm.contentsOfDirectory(atPath: base.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .compactMap { v in root(base.appendingPathComponent(v, isDirectory: true)).map { (v, $0) } }
        guard let best = found.max(by: { CustomScenes.compareVersions($0.0, $1.0) < 0 }) else { return nil }
        return Install(root: best.1, version: version(best.1) ?? best.0, source: "pulled")
    }

    /// python3 for job.py (and, through PATH, for the scenes' own pre-steps — Commute draws its
    /// posters with Pillow): DOTSTUDIO_FILM_PYTHON, else the first of the usual installs that has
    /// Pillow, else the first that exists. /usr/bin/python3 only when the developer tools are
    /// installed (otherwise it's a stub that asks to install them).
    static let python: (path: String, pillow: Bool)? = {
        let fm = FileManager.default
        var c: [String]
        if let p = ProcessInfo.processInfo.environment["DOTSTUDIO_FILM_PYTHON"], !p.isEmpty {
            c = [p]
        } else {
            c = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/Library/Frameworks/Python.framework/Versions/Current/bin/python3"]
            if fm.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/python3")
                || fm.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/python3") {
                c.append("/usr/bin/python3")
            }
        }
        c = c.filter { fm.isExecutableFile(atPath: $0) }
        let check = "import importlib.util, sys; sys.exit(0 if sys.version_info >= (3, 9) and importlib.util.find_spec('PIL') else 3)"
        for p in c where run(p, ["-I", "-c", check], timeout: 10)?.status == 0 { return (p, true) }
        return c.first.map { ($0, false) }
    }()

    static func ffmpeg(path: String) -> String? {
        for d in path.split(separator: ":") {
            let f = "\(d)/ffmpeg"
            if FileManager.default.isExecutableFile(atPath: f) { return f }
        }
        return nil
    }

    /// The jobs' PATH: python's own folder first (so a scene's `python3` is this one), then
    /// Homebrew's (ffmpeg), then the server's own.
    static func searchPath(python: String?) -> String {
        let base = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var seen = Set<String>(), out: [String] = []
        for d in [python.map { ($0 as NSString).deletingLastPathComponent }, "/opt/homebrew/bin", "/usr/local/bin"].compactMap({ $0 })
            + base.split(separator: ":").map(String.init) where !d.isEmpty && seen.insert(d).inserted {
            out.append(d)
        }
        return out.joined(separator: ":")
    }

    var lockPath: String { FilmPaths.jobsDir(store).appendingPathComponent(".blender.lock").path }

    // MARK: Running job.py

    /// Runs a short process to completion (stdin /dev/null), killing it after `timeout`.
    static func run(_ exe: String, _ args: [String], environment: [String: String]? = nil,
                    timeout: TimeInterval = 30) -> (status: Int32, out: Data, err: String)? {
        final class Box: @unchecked Sendable { var out = Data(), err = Data() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let environment { p.environment = environment }
        p.standardInput = FileHandle.nullDevice
        let o = Pipe(), e = Pipe()
        p.standardOutput = o
        p.standardError = e
        let box = Box(), group = DispatchGroup(), done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        group.enter()
        DispatchQueue.global().async { box.out = o.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { box.err = e.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 2)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        group.wait()
        return (p.terminationStatus, box.out, String(decoding: box.err, as: UTF8.self))
    }

    private func environment(python: String?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.searchPath(python: python)
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    /// `python3 -I job.py <args>` → its JSON stdout.
    private func job(_ args: [String]) throws -> Any {
        guard let kit = Self.locate(store: store) else { throw ToolError(Self.notInstalled) }
        guard let py = Self.python else { throw ToolError(Self.noPython) }
        guard let r = Self.run(py.path, ["-I", kit.root.appendingPathComponent("job.py").path] + args,
                               environment: environment(python: py.path)) else {
            throw ToolError("Couldn't run the film toolkit (\(py.path)).")
        }
        guard r.status == 0, let o = JSON.parse(r.out) else {
            throw ToolError("The film toolkit failed (job.py \(args.first ?? ""), status \(r.status)): \(r.err.suffix(600))")
        }
        return o
    }

    static let notInstalled = "The film toolkit (DotStudio's Blender scene scripts: dsfilm, run.py, job.py and the templates) isn't installed on this Mac. It's the `film` engine pack, which lives in DotStudio's store under engines/film/<version>/ — it isn't in DotStudio's engine index yet, so tell the user film scenes can't be made on this Mac yet. (Developers: set DOTSTUDIO_FILM_TOOLKIT to a tools/film checkout.)"
    static let noPython = "Python 3 (3.9 or newer) isn't installed, and the film toolkit runs on it. Ask the user to install it themselves (DotStudio never installs it): from https://www.python.org/downloads/macos/ or with Homebrew (`brew install python`), plus Pillow (`python3 -m pip install pillow`) for the templates' textures."
    static let noFFmpeg = "ffmpeg isn't installed, and the film toolkit encodes its loops with it. Ask the user to install it themselves (DotStudio never installs it), e.g. with Homebrew: `brew install ffmpeg`."

    /// Everything a render needs, or the reason (and what to tell the user) it can't start.
    private func ready(needsFFmpeg: Bool) throws -> (kit: Install, python: String, blender: String, env: [String: String]) {
        guard let kit = Self.locate(store: store) else { throw ToolError(Self.notInstalled) }
        let b = FilmPaths.blender()
        if let advice = FilmPaths.installAdvice(found: b) { throw ToolError(advice) }
        guard let py = Self.python else { throw ToolError(Self.noPython) }
        let env = environment(python: py.path)
        if needsFFmpeg, Self.ffmpeg(path: env["PATH"] ?? "") == nil { throw ToolError(Self.noFFmpeg) }
        // Only what differs from the server's own environment goes in the command (FilmJobs merges).
        return (kit, py.path, b!.path, ["PATH": env["PATH"]!, "PYTHONUNBUFFERED": "1"])
    }

    // MARK: FilmToolkitAPI

    func status() -> FilmStatus {
        let b = FilmPaths.blender()
        let kit = Self.locate(store: store)
        var notes: [String] = []
        if let kit {
            notes.append("Toolkit: \(kit.root.path) (\(kit.source)).")
            if let py = Self.python {
                let env = (try? job(["env"])) as? JSONObject
                notes.append("Python: \(py.path) \(env?["python"] as? String ?? "")" + (py.pillow ? " with Pillow." : " — without Pillow, which Commute needs for its posters: ask the user to run `\(py.path) -m pip install pillow`."))
                if let f = env?["ffmpeg"] as? String { notes.append("ffmpeg: \(f).") } else { notes.append(Self.noFFmpeg) }
            } else {
                notes.append(Self.noPython)
            }
            notes.append("Renders run one Blender at a time: a job started while another Blender renders waits its turn (its stage says so).")
        } else {
            if let p = ProcessInfo.processInfo.environment["DOTSTUDIO_FILM_TOOLKIT"], !p.isEmpty {
                notes.append("DOTSTUDIO_FILM_TOOLKIT=\(p) isn't a film toolkit folder (it needs run.py, job.py and dsfilm/).")
            }
            notes.append(Self.notInstalled)
        }
        return FilmStatus(blenderPath: b?.path, blenderVersion: b?.version, toolkitPulled: kit != nil,
                          toolkitVersion: kit.map { $0.version ?? "?" }, gpu: PreviewRenderer.gpuName, notes: notes)
    }

    func templates() -> [JSONObject] {
        ((try? job(["templates"])) as? [JSONObject]) ?? []
    }

    func validate(spec: JSONObject) -> CSReport {
        func fail(_ m: String) -> CSReport { CSReport(ok: false, diagnostics: [CSDiagnostic(message: m, severity: "error")], warnings: []) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dsfilm-spec-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try JSON.data(spec).write(to: tmp)
            guard let r = try job(["validate", tmp.path]) as? JSONObject else { return fail("The film toolkit's validator returned nothing.") }
            let diags = (r["diagnostics"] as? [JSONObject] ?? []).map {
                CSDiagnostic(line: ($0["line"] as? NSNumber)?.intValue, column: ($0["column"] as? NSNumber)?.intValue,
                             message: $0["message"] as? String ?? "?", severity: $0["severity"] as? String ?? "error",
                             file: $0["file"] as? String)
            }
            return CSReport(ok: r["ok"] as? Bool ?? false, diagnostics: diags, warnings: r["warnings"] as? [String] ?? [])
        } catch let e as ToolError {
            return fail(e.message)
        } catch {
            return fail("\(error)")
        }
    }

    /// The job's scratch folder (the resolved spec, a loop's frames), next to its out/.
    private func work(_ outDir: URL) -> String { outDir.deletingLastPathComponent().appendingPathComponent("work").path }

    func stillsCommand(spec: URL, outDir: URL, variants: [String], width: Int, height: Int, samples: Int) throws -> FilmCommand {
        let r = try ready(needsFFmpeg: false)
        return FilmCommand(executable: r.python, arguments: [
            "-I", r.kit.root.appendingPathComponent("job.py").path, "stills",
            "--blender", r.blender, "--spec", spec.path, "--out", outDir.path, "--work", work(outDir),
            "--variants", variants.joined(separator: ","), "--res", "\(width)x\(height)", "--samples", "\(samples)",
            "--lock", lockPath], environment: r.env)
    }

    func loopCommand(spec: URL, outDir: URL, variants: [String], seconds: Double, fps: Int, width: Int, height: Int,
                     quality: String) throws -> FilmCommand {
        guard ["draft", "standard", "final"].contains(quality) else { throw ToolError("quality: draft, standard or final") }
        let frames = seconds * Double(fps)
        guard abs(frames - frames.rounded()) < 1e-6 else {
            throw ToolError("\(Schema.fmt(seconds)) s × \(fps) fps isn't a whole number of frames: pick a loop length that is.")
        }
        let r = try ready(needsFFmpeg: true)
        return FilmCommand(executable: r.python, arguments: [
            "-I", r.kit.root.appendingPathComponent("job.py").path, "loop",
            "--blender", r.blender, "--spec", spec.path, "--out", outDir.path, "--work", work(outDir),
            "--variants", variants.joined(separator: ","), "--seconds", Schema.fmt(seconds), "--fps", "\(fps)",
            "--res", "\(width)x\(height)", "--quality", quality, "--lock", lockPath], environment: r.env)
    }

    func package(loopOutput: URL, spec: JSONObject, sceneID: String, into package: URL) throws {
        try FilmPackage.make(loopOutput: loopOutput, spec: spec, sceneID: sceneID, into: package)
    }
}
