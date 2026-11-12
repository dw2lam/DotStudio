//  tools/wallpaper-selftest/main.swift — see run.sh. Never touches the real desktop picture:
//  LockScreenPicture runs against FakeDesktop, and every file goes under argv[1] (a temp dir).

import AppKit

setvbuf(stdout, nil, _IOLBF, 0)
guard CommandLine.arguments.count > 1 else { print("usage: wallpaper-selftest <tmpDir>"); exit(2) }
let tmp = URL(fileURLWithPath: CommandLine.arguments[1])

var failures = 0
func check(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
    print((ok ? "  ok   " : "  FAIL ") + what)
    if !ok { failures += 1 }
}

// MARK: wallpaper.json

print("wallpaper.json")
func decode(_ json: String) -> WallpaperSettings {
    try! JSONDecoder().decode(WallpaperSettings.self, from: Data(json.utf8))
}
check(decode(#"{"enabled":true,"freezeOnBattery":true}"#).batteryMode == .still, "freezeOnBattery true → Still")
check(decode(#"{"enabled":true,"freezeOnBattery":false}"#).batteryMode == .efficient, "freezeOnBattery false → Efficient")
check(decode(#"{"enabled":true}"#).batteryMode == .efficient, "no key → Efficient (the default)")
check(decode(#"{"batteryMode":"full","freezeOnBattery":true}"#).batteryMode == .full, "batteryMode wins over the old key")
check(decode(#"{"batteryMode":"turbo"}"#).batteryMode == .efficient, "unknown batteryMode → Efficient")
check(decode(#"{"enabled":true,"quality":"full","frameRate":120}"#).quality == .full, "other fields still decode")
check(decode("{}").lockScreen == false && decode("{}").savedDesktopPictures.isEmpty, "lock screen off by default")
do {
    var s = WallpaperSettings()
    s.enabled = true
    s.batteryMode = .still
    s.lockScreen = true
    s.savedDesktopPictures = ["A": SavedDesktopPicture(url: "file:///a.heic", scaling: 3, allowClipping: true,
                                                       fillColor: [0, 0.5, 1, 1])]
    let url = tmp.appendingPathComponent("wallpaper.json")
    s.save(to: url)
    let raw = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
    check(raw["batteryMode"] as? String == "still" && raw["freezeOnBattery"] as? Bool == true,
          "writes batteryMode and the old freezeOnBattery (Still ⇔ true) for older builds")
    check(WallpaperSettings.load(from: url) == s, "round-trips (lockScreen, saved pictures)")
    s.batteryMode = .efficient
    s.savedDesktopPictures = [:]
    s.save(to: url)
    let raw2 = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
    check(raw2["freezeOnBattery"] as? Bool == false && raw2["savedDesktopPictures"] == nil,
          "Efficient writes freezeOnBattery false; no saved pictures key while empty")
}

// MARK: WallpaperBudget

print("WallpaperBudget")
do {
    var s = WallpaperSettings()
    check(WallpaperBudget.fps(s, presetFPS: 30, onBattery: false) == 30, "AC Balanced: 30 fps")
    check(WallpaperBudget.fps(s, presetFPS: 30, onBattery: true) == 20, "battery Efficient: 20 fps")
    check(WallpaperBudget.fps(s, presetFPS: 12, onBattery: true) == 12, "battery Efficient: the style's own lower fps")
    check(WallpaperBudget.renderScale(s, onBattery: true, profile: .motion) == 0.6, "battery Efficient motion: 0.6× resolution")
    check(WallpaperBudget.renderScale(s, onBattery: true, profile: .clock(period: 60, burst: 0.65)) == 1,
          "battery Efficient clock: full resolution (1 Hz frames)")
    check(WallpaperBudget.renderScale(s, onBattery: false, profile: .motion) == 1, "AC: full resolution")
    check(WallpaperBudget.batteryStatus(s, onBattery: true) == "Efficient — on battery", "status: Efficient — on battery")
    check(WallpaperBudget.batteryStatus(s, onBattery: false) == nil, "status on AC: none")
    s.frameRate = .smooth
    check(WallpaperBudget.fps(s, presetFPS: 30, onBattery: false) == 120, "AC Smooth: display rate")
    s.batteryMode = .full
    check(WallpaperBudget.fps(s, presetFPS: 30, onBattery: true) == 30, "battery Full + Smooth: 30 fps")
    check(WallpaperBudget.renderScale(s, onBattery: true, profile: .motion) == 1, "battery Full: full resolution")
    check(WallpaperBudget.batteryStatus(s, onBattery: true) == "30 fps — on battery", "status: 30 fps — on battery")
    s.batteryMode = .still
    var st = WallpaperPowerMonitor.State()
    st.onBattery = true
    check(WallpaperBudget.stillReason(s, st) == "Still — on battery", "battery Still holds")
    st.onBattery = false
    check(WallpaperBudget.stillReason(s, st) == nil, "AC with Still set: plays")
    st.thermalHot = true
    check(WallpaperBudget.stillReason(WallpaperSettings(), st) == "Still — Mac is running hot", "hot Mac holds")
    check(WallpaperPacing.divisorRate(target: 20, refresh: 120) == 20 && WallpaperPacing.divisorRate(target: 20, refresh: 60) == 20,
          "20 fps is an exact divisor of 60 and 120 Hz")
    // Bloom steps its time at 24 fps: drawn at the slowest exact divisor at or above that
    check(WallpaperPacing.rate(target: 24, step: 24, refresh: 120) == 24 && WallpaperPacing.rate(target: 24, step: 24, refresh: 60) == 30
          && WallpaperPacing.rate(target: 120, step: 24, refresh: 120) == 24 && WallpaperPacing.rate(target: 20, step: 24, refresh: 60) == 20
          && WallpaperPacing.rate(target: 24, step: nil, refresh: 60) == 20,
          "stepped 24 fps: 24 on 120 Hz, 30 on 60 Hz, never skipping a step unless the battery asks for less")
}

print("time of day")
do {
    let lib = DefaultPresets.makeLibrary()
    func p(_ n: String) -> Preset { lib.presets.first { $0.name == n } ?? Preset(name: n) }
    // (Tidewater — Golden Hour following the sun — folded into Golden Hour's own setting in 1.4.5.)
    var following = p("Golden Hour")
    for i in following.effects.indices where following.effects[i].kind == .oceanHorizon { following.effects[i].params["live"] = 1 }
    check(WallpaperPacing.changesWithTimeOfDay(following), "Golden Hour following the sun follows the time of day")
    check(WallpaperPacing.changesWithTimeOfDay(p("StandBy")) && WallpaperPacing.changesWithTimeOfDay(p("Flip Clock")),
          "clocks follow the time of day")
    check(!WallpaperPacing.changesWithTimeOfDay(p("Liquid Chrome")), "Liquid Chrome doesn't")
}

// MARK: Per-display styles (Shared/DisplayPins.swift, WallpaperPick)

print("per-display styles")
do {
    let base = DefaultPresets.makeLibrary()
    func id(_ n: String) -> UUID { base.presets.first { $0.name == n }!.id }
    let chrome = id("Liquid Chrome"), aurora = id("Aurora"), standby = id("StandBy"), universe = id("Universe")
    let builtIn = "37D8832A-2D66-02CA-B9F7-8F30A301B230", lg = "A1B2C3D4-0000-1111-2222-333344445555"
    let unplugged = "FFFFFFFF-0000-1111-2222-333344445555"
    var lib = base
    lib.activeID = chrome
    lib.rotation = nil
    lib.schedule = nil
    let now = Date()

    // The screensaver: default / override / unknown display / deleted style
    check(Playback.effectivePreset(in: lib, now: now, display: nil).id == chrome, "no display (thumbnail, not known yet): the lineup")
    check(Playback.effectivePreset(in: lib, now: now, display: lg).id == chrome, "no pins: every display plays the lineup")
    lib.displayStyles = [lg: DisplayPin(presetID: aurora, name: "LG HDR 4K")]
    check(Playback.effectivePreset(in: lib, now: now, display: lg).id == aurora, "pinned display plays its own style")
    check(Playback.effectivePreset(in: lib, now: now, display: builtIn).id == chrome, "other displays keep the lineup")
    check(Playback.effectivePreset(in: lib, now: now, display: nil).id == chrome, "the thumbnail keeps the lineup")
    var rot = lib
    rot.rotation = RotationSpec(enabled: true, intervalMinutes: 5, presetIDs: [chrome, standby, universe])
    check(Playback.effectivePreset(in: rot, now: now, display: lg).id == aurora
          && Playback.effectivePreset(in: rot, now: now, display: builtIn).id == Playback.effectivePreset(in: rot, now: now).id,
          "a pin overrides the rotation; the others rotate in step")
    var deleted = lib
    deleted.presets.removeAll { $0.id == aurora }
    check(Playback.effectivePreset(in: deleted, now: now, display: lg).id == chrome, "deleted pinned style: that display falls back to the lineup")
    check(deleted.pruneDisplayStyles() && deleted.displayStyles == nil, "…and the pin is dropped on save (prune)")
    var kept = lib
    check(!kept.pruneDisplayStyles() && kept.displayStyles?[lg]?.presetID == aurora, "prune keeps a live pin")
    var newer = lib
    let gone = newer.presets.first { $0.id == aurora }!
    newer.presets.removeAll { $0.id == aurora }
    newer.unknownPresets = [UnknownPreset(index: 0, preset: gone)]
    check(!newer.pruneDisplayStyles(), "prune keeps a pin to a style only a newer build can draw")
    lib.displayStyles?[unplugged] = DisplayPin(presetID: standby, name: "Studio Display")
    check(Playback.effectivePreset(in: lib, now: now, display: builtIn).id == chrome
          && lib.displayStyles?[unplugged] != nil, "a disconnected display's pin is kept and changes nothing here")

    // library.json: old libraries, round trip, unknown fields, malformed pins
    let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
    let oldData = try! enc.encode(base)
    var oldJSON = try! JSONSerialization.jsonObject(with: oldData) as! [String: Any]
    oldJSON["displayStyles"] = nil
    let decodedOld = try! JSONDecoder().decode(Library.self, from: JSONSerialization.data(withJSONObject: oldJSON))
    check(decodedOld.displayStyles == nil && decodedOld.unknownFields.isEmpty, "a 1.4.5 library (no field) decodes: no pins")
    check(!(String(data: try! enc.encode(decodedOld), encoding: .utf8)!.contains("displayStyles")), "…and saves without the key")
    let round = try! JSONDecoder().decode(Library.self, from: enc.encode(lib))
    check(round.displayStyles == lib.displayStyles && round == lib, "pins round-trip (with names)")
    var future = oldJSON
    future["perDisplayPlaylists"] = ["x": [1, 2, 3]]
    future["someFlag"] = true
    let fut = try! JSONDecoder().decode(Library.self, from: JSONSerialization.data(withJSONObject: future))
    let futBack = try! JSONSerialization.jsonObject(with: enc.encode(fut)) as! [String: Any]
    check(fut.unknownFields.count == 2 && (futBack["someFlag"] as? Bool) == true
          && ((futBack["perDisplayPlaylists"] as? [String: Any])?["x"] as? [Double]) == [1, 2, 3],
          "unknown top-level fields from a newer build survive a save")
    var bad = oldJSON
    bad["displayStyles"] = ["oops": 42]
    let badLib = try? JSONDecoder().decode(Library.self, from: JSONSerialization.data(withJSONObject: bad))
    check(badLib != nil && badLib?.displayStyles == nil, "a malformed pin map never costs the library")

    // The wallpaper
    var ws = WallpaperSettings()
    ws.enabled = true
    ws.presetID = universe
    check(WallpaperPick.preset(display: lg, ws, lib, now: now)?.id == universe, "wallpaper: no pin → the shared pick")
    ws.displayStyles = [lg: DisplayPin(presetID: standby, name: "LG HDR 4K")]
    check(WallpaperPick.preset(display: lg, ws, lib, now: now)?.id == standby
          && WallpaperPick.preset(display: builtIn, ws, lib, now: now)?.id == universe
          && WallpaperPick.shared(ws, lib, now: now)?.id == universe, "wallpaper pin on its display only")
    var noStandby = lib
    noStandby.presets.removeAll { $0.id == standby }
    check(WallpaperPick.preset(display: lg, ws, noStandby, now: now)?.id == universe, "deleted pinned wallpaper style → the shared pick")
    check(WallpaperPick.pruned(ws, noStandby).displayStyles.isEmpty && WallpaperPick.pruned(ws, lib) == ws, "wallpaper prune drops only dead pins")
    var synced = ws
    synced.followsScreensaver = true
    check(WallpaperPick.preset(display: lg, synced, lib, now: now)?.id == aurora,
          "SYNC: the LG wallpaper shows the LG screensaver's own style (not its wallpaper pin)")
    check(WallpaperPick.preset(display: builtIn, synced, lib, now: now)?.id == chrome
          && WallpaperPick.shared(synced, lib, now: now)?.id == chrome, "SYNC: other displays show the lineup")
    check(WallpaperPick.preset(display: lg, synced, rot, now: now)?.id == aurora
          && WallpaperPick.preset(display: builtIn, synced, rot, now: now)?.id == Playback.effectivePreset(in: rot, now: now).id,
          "SYNC with a rotation: pinned display holds, others rotate with the screensaver")
    var shared0 = ws
    shared0.presetID = UUID()
    check(WallpaperPick.shared(shared0, lib, now: now) == nil, "deleted shared pick: nothing (the controller stops)")
    check(decode(#"{"enabled":true,"presetID":"\#(universe.uuidString)"}"#).displayStyles.isEmpty, "a 1.4.5 wallpaper.json: no pins")
    check(decode(#"{"enabled":true,"displayStyles":{"a":7}}"#).enabled, "malformed wallpaper pins are ignored, the rest decodes")
    let wurl = tmp.appendingPathComponent("wallpaper-pins.json")
    ws.save(to: wurl)
    check(WallpaperSettings.load(from: wurl) == ws, "wallpaper pins round-trip")
    var none = ws; none.displayStyles = [:]
    none.save(to: wurl)
    let rawNone = (try? JSONSerialization.jsonObject(with: Data(contentsOf: wurl))) as? [String: Any] ?? [:]
    check(rawNone["displayStyles"] == nil, "no displayStyles key while there are no pins")

    // Identity: a display's key is stable (read only; nothing is shown)
    let main = CGMainDisplayID()
    let k1 = DisplayIdentity.key(main), k2 = DisplayIdentity.key(main)
    check(k1 != nil && k1 == k2 && UUID(uuidString: k1 ?? "") != nil, "the main display has a stable UUID key")
    if let screen = NSScreen.screens.first {
        check(DisplayIdentity.key(screen) == DisplayIdentity.displayID(screen).flatMap(DisplayIdentity.key),
              "NSScreen → NSScreenNumber → key")
    }
}

// MARK: LockScreenPicture

/// The desktop, in memory: what each screen shows, and every set call.
final class FakeDesktop: DesktopPictures {
    var connected: [LockScreenPicture.Screen]
    var shown: [String: SavedDesktopPicture]
    var sets: [(String, SavedDesktopPicture)] = []
    init(_ screens: [LockScreenPicture.Screen], shown: [String: SavedDesktopPicture]) {
        connected = screens
        self.shown = shown
    }
    func screens() -> [LockScreenPicture.Screen] { connected }
    func picture(for key: String) -> SavedDesktopPicture? { shown[key] }
    func setPicture(_ p: SavedDesktopPicture, for key: String) throws {
        guard connected.contains(where: { $0.key == key }) else { throw CocoaError(.fileNoSuchFile) }
        shown[key] = p
        sets.append((key, p))
    }
}

func solid(_ w: Int, _ h: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

print("LockScreenPicture (fake desktop)")
do {
    let dir = tmp.appendingPathComponent("store/lockscreen")
    let origA = SavedDesktopPicture(url: "file:///System/Library/Desktop%20Pictures/A.heic", scaling: 3,
                                    allowClipping: true, fillColor: [0.1, 0.2, 0.3, 1])
    let origB = SavedDesktopPicture(url: "file:///Users/x/Pictures/b.jpg", scaling: 1, allowClipping: false, fillColor: nil)
    let screens: [LockScreenPicture.Screen] = [
        .init(key: "A", pixelWidth: 3024, pixelHeight: 1964),
        .init(key: "B", pixelWidth: 1920, pixelHeight: 1080),
        .init(key: "C", pixelWidth: 1920, pixelHeight: 1080),
    ]
    let desk = FakeDesktop(screens, shown: ["A": origA, "B": origB])   // C: macOS gives no URL
    let pic = LockScreenPicture(dir: dir, desktop: desk)

    var saved: [String: SavedDesktopPicture] = [:]
    check(pic.saveOriginals(into: &saved) && saved == ["A": origA, "B": origB], "records each screen's own picture + options")
    check(!pic.saveOriginals(into: &saved), "records only once")

    var renders: [String] = []
    func render(_ w: Int, _ h: Int) -> CGImage? { renders.append("\(w)x\(h)"); return solid(w, h) }
    let onRecord = desk.screens().filter { saved[$0.key] != nil }
    check(onRecord.map(\.key) == ["A", "B"], "a screen with no picture on record (C) is never replaced")
    var prepared = pic.prepare(screens: onRecord, render: render)
    check(renders == ["3024x1964", "1920x1080"], "one render per native pixel size")
    check(prepared.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) }, "stills written")
    if let first = prepared.first, let img = NSImage(contentsOf: first.url),
       let rep = img.representations.first {
        check(rep.pixelsWide == 3024 && rep.pixelsHigh == 1964, "the still is native size (\(rep.pixelsWide)x\(rep.pixelsHigh), \(first.url.pathExtension))")
    } else { check(false, "the still reads back") }
    let done = pic.set(prepared)
    check(Set(done) == ["A", "B"] && pic.isOurs(desk.shown["A"]!.url) && pic.isOurs(desk.shown["B"]!.url), "set on A and B")
    check(desk.shown["C"] == nil, "C untouched")
    check(desk.shown["A"]?.allowClipping == true && desk.shown["A"]?.scaling == Int(NSImageScaling.scaleProportionallyUpOrDown.rawValue),
          "ours fills the screen")
    check(!pic.saveOriginals(into: &saved) && saved == ["A": origA, "B": origB], "never records one of ours as an original")

    // Rotation: a new file name each time (macOS caches by URL); old ones pruned (newest 2 per size).
    var urls: Set<String> = [desk.shown["A"]!.url]
    for _ in 0..<3 {
        prepared = pic.prepare(screens: onRecord, render: render)
        pic.set(prepared)
        urls.insert(desk.shown["A"]!.url)
    }
    check(urls.count == 4, "every refresh uses a new file name (\(urls.count) of 4)")
    let files = pic.files().map(\.lastPathComponent)
    check(files.count == 4 && files.filter { $0.contains("3024x1964") }.count == 2, "keeps the newest two per size (\(files.count) files)")
    check(FileManager.default.fileExists(atPath: URL(string: desk.shown["A"]!.url)!.path), "the file on screen is kept")

    // A failed render skips that size.
    let partial = pic.prepare(screens: onRecord) { w, h in w == 3024 ? nil : solid(w, h) }
    check(partial.count == 1 && partial[0].screens == ["B"], "a failed render skips its screens")

    // Restore: A shows ours → back to its original with options; B was changed by the user → kept.
    let userPick = SavedDesktopPicture(url: "file:///Users/x/Pictures/new.png", scaling: 3, allowClipping: true, fillColor: nil)
    desk.shown["B"] = userPick
    desk.sets.removeAll()
    var toRestore = saved
    pic.restore(&toRestore)
    check(desk.shown["A"] == origA, "A restored with its options")
    check(desk.shown["B"] == userPick && !desk.sets.contains { $0.0 == "B" }, "B keeps the picture the user chose meanwhile")
    check(toRestore.isEmpty && pic.files().isEmpty, "nothing left on record; our files deleted")

    // A screen that's unplugged at restore keeps its record (and our file) until it's back.
    let desk2 = FakeDesktop(screens, shown: ["A": origA, "B": origB])
    let pic2 = LockScreenPicture(dir: tmp.appendingPathComponent("store2/lockscreen"), desktop: desk2)
    var saved2: [String: SavedDesktopPicture] = [:]
    pic2.saveOriginals(into: &saved2)
    pic2.set(pic2.prepare(screens: desk2.screens().filter { saved2[$0.key] != nil }, render: render))
    desk2.connected.removeAll { $0.key == "B" }
    pic2.restore(&saved2)
    check(desk2.shown["A"] == origA && saved2.keys.sorted() == ["B"] && !pic2.files().isEmpty, "unplugged screen: kept for later")
    desk2.connected = screens
    pic2.restore(&saved2)
    check(desk2.shown["B"] == origB && saved2.isEmpty && pic2.files().isEmpty, "…restored once it's back")
    // Per-display styles: two screens of one size showing different styles get stills of their own.
    let desk3 = FakeDesktop(screens, shown: ["A": origA, "B": origB, "C": origB])
    let pic3 = LockScreenPicture(dir: tmp.appendingPathComponent("store3/lockscreen"), desktop: desk3)
    let styleOf = ["A": "chrome", "B": "chrome", "C": "aurora"]
    var drawn: [String] = []
    var lastSet: [String: String] = [:]
    for _ in 0..<3 {
        let prep = pic3.prepare(screens: screens, style: { styleOf[$0.key]! }) { s in
            drawn.append("\(s.key):\(styleOf[s.key]!)"); return solid(s.pixelWidth, s.pixelHeight)
        }
        pic3.set(prep)
        lastSet = desk3.shown.mapValues(\.url)
    }
    check(drawn.prefix(3) == ["A:chrome", "B:chrome", "C:aurora"], "one render per (style, size): \(drawn.prefix(3))")
    check(lastSet["B"] != lastSet["C"] && Set(lastSet.values).count == 3, "same size, different styles: different files")
    let files3 = pic3.files()
    check(files3.count == 6 && lastSet.values.allSatisfy { u in files3.contains { $0.lastPathComponent == URL(string: u)?.lastPathComponent } },
          "prune keeps every style's still of the newest two renders (\(files3.count) files), and the ones on screen")
    check(!pic.isOurs("file:///Users/x/Pictures/lock-1-2.heic") && pic.isOurs(dir.appendingPathComponent("lock-x.heic").absoluteString),
          "only files in our folder count as ours")
}

// MARK: A real still (offscreen render + HEIC write; nothing is set anywhere)

print("real still")
do {
    let store = SharedStore(role: .app)    // DOTSTUDIO_STORE_DIR: run.sh's temp dir
    let lib = DefaultPresets.makeLibrary()
    let dir = tmp.appendingPathComponent("store/lockscreen-real")
    let pic = LockScreenPicture(dir: dir, desktop: FakeDesktop([], shown: [:]))
    for name in ["Tidewater", "StandBy", "Liquid Chrome"] {
        guard let preset = lib.presets.first(where: { $0.name == name }) else { continue }
        let t0 = CFAbsoluteTimeGetCurrent()
        var tRender = 0.0
        let prepared = pic.prepare(screens: [.init(key: "M", pixelWidth: 3024, pixelHeight: 1964)]) { w, h in
            guard let r = MetalRenderer(pixelFormat: .bgra8Unorm, store: store) else { return nil }
            r.waitsForScenePipelines = true
            let img = r.renderThumbnail(preset: preset, source: lib.source, width: w, height: h,
                                        time: Float(MetalRenderer.wallPhase(Date().timeIntervalSince1970)))
            tRender = CFAbsoluteTimeGetCurrent() - t0
            return img
        }
        let total = CFAbsoluteTimeGetCurrent() - t0
        let bytes = prepared.first.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.url.path)[.size] as? Int } ?? 0
        check(prepared.count == 1, String(format: "%@: renderer + render %.0f ms, HEIC write %.0f ms, %d KB",
                                          name, tRender * 1000, (total - tRender) * 1000, bytes / 1024))
    }
}

print(failures == 0 ? "all checks passed" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
