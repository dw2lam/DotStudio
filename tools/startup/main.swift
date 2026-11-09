//  tools/startup/main.swift — how long a renderer takes from nothing to its first frame: what the
//  screensaver pays before it shows anything. Build + run with tools/startup/run.sh, which runs
//  each case in a fresh process, cold (MTL_SHADER_CACHE_SIZE=0: the system shader cache off, as
//  on the first start after an update) and warm.
//
//  usage: startup <mode> [--only name] [--size 3024x1964]
//    blocking  MetalRenderer(...) as the app builds it (and as the saver did before), apply, first frame
//    fast      MetalRenderer(..., pipelines: .fastStart) as the saver builds it now: init never waits;
//              frames are polled until the first one draws (with the store's pipeline archive, if any)
//    harvest   build the pipeline archive into the store (what the app does after an install/update);
//              --saver <DotStudio.saver> harvests that bundle's metallib instead of the harness's
//  Never touches the real library: run.sh sets DOTSTUDIO_STORE_DIR to a temp folder.
//  Prints one line: `<mode> init=… ms first=… ms total=… ms` (or the harvest's outcome).

import AppKit
import Metal

var args = Array(CommandLine.arguments.dropFirst())
guard let mode = args.first else { print("usage: startup blocking|fast|harvest [--only name]"); exit(2) }
args.removeFirst()
var only: String?
var saverArg: String?
var W = 3024, H = 1964
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--only": only = args.removeFirst().lowercased()
    case "--saver": saverArg = args.removeFirst()
    case "--size":
        let p = args.removeFirst().split(separator: "x").compactMap { Int($0) }
        if p.count == 2 { W = p[0]; H = p[1] }
    default: break
    }
}
guard ProcessInfo.processInfo.environment["DOTSTUDIO_STORE_DIR"] != nil else {
    print("set DOTSTUDIO_STORE_DIR (never the real library)"); exit(2)
}
let store = SharedStore(role: .app)
func ms(_ t: CFAbsoluteTime) -> String { String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - t) * 1000) }

// What the saver would show on a fresh install: the default library's active style.
let lib = DefaultPresets.makeLibrary()
var preset = Playback.effectivePreset(in: lib, now: Date())
if let only {
    guard let p = DefaultPresets.offeredBuiltIns().first(where: { $0.name.lowercased().contains(only) }) else {
        print("no built-in matching \(only)"); exit(2)
    }
    preset = p
}

switch mode {
case "harvest":
    #if FASTSTART
    // run.sh lays the metallib out as a .saver bundle next to the binary; --saver picks another
    // (e.g. a built DotStudio.saver — never the installed one's folder as the store).
    let saver = saverArg.map { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("Harness.saver")
    let t0 = CFAbsoluteTimeGetCurrent()
    let outcome = PipelineArchive.refresh(saver: saver, baseDir: store.baseDir, force: true)
    print("harvest \(outcome) in \(ms(t0)) ms")
    #else
    print("harvest: not in this build"); exit(2)
    #endif

case "blocking", "fast":
    let t0 = CFAbsoluteTimeGetCurrent()
    #if FASTSTART
    let r = MetalRenderer(pixelFormat: .bgra8Unorm, store: store, pipelines: mode == "fast" ? .fastStart : .blocking)
    #else
    guard mode == "blocking" else { print("fast: not in this build"); exit(2) }
    let r = MetalRenderer(pixelFormat: .bgra8Unorm, store: store)
    #endif
    guard let r else { print("no renderer"); exit(1) }
    let initMs = ms(t0)
    r.timeBase = lib.rendererTimeBase
    r.apply(preset, source: lib.source)
    let t1 = CFAbsoluteTimeGetCurrent()
    var skipped = 0
    // The saver's host ticks at 30 fps; poll faster so the number is the pipelines', not the tick's.
    while r.renderFrame(width: W, height: H) == nil {
        skipped += 1
        if CFAbsoluteTimeGetCurrent() - t0 > 30 { print("\(mode): no frame in 30 s"); exit(1) }
        usleep(2000)
    }
    print("\(mode) [\(preset.name) \(W)x\(H)] init=\(initMs) ms first-frame=\(ms(t1)) ms total=\(ms(t0)) ms (polls before it: \(skipped))")

default:
    print("unknown mode \(mode)"); exit(2)
}
