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
    check(WallpaperBudget.stillReason(s, st) == "Paused — on battery", "battery Pause holds")
    st.onBattery = false
    check(WallpaperBudget.stillReason(s, st) == nil, "AC with Pause set: plays")
    // Another app focused: keep playing by default; Pause per power source
    var fs = WallpaperSettings()
    var fo = WallpaperPowerMonitor.State()
    fo.otherAppFront = true
    check(WallpaperBudget.stillReason(fs, fo) == nil, "another app focused, defaults: keeps playing")
    fs.otherAppOnBattery = .pause
    check(WallpaperBudget.stillReason(fs, fo) == nil, "plugged in, Pause set only on battery: plays")
    fo.onBattery = true
    check(WallpaperBudget.stillReason(fs, fo) == "Paused — another app in front", "on battery + another app focused: holds")
    fo.otherAppFront = false
    check(WallpaperBudget.stillReason(fs, fo) == nil, "desktop focused again: plays")
    fs.otherAppPluggedIn = .pause
    fo.onBattery = false; fo.otherAppFront = true
    check(WallpaperBudget.stillReason(fs, fo) == "Paused — another app in front", "plugged in + Pause: holds")
    let round = try! JSONDecoder().decode(WallpaperSettings.self, from: JSONEncoder().encode(fs))
    check(round.otherAppPluggedIn == .pause && round.otherAppOnBattery == .pause, "focus modes survive wallpaper.json")
    let old = try! JSONDecoder().decode(WallpaperSettings.self, from: Data(#"{"enabled":true,"batteryMode":"full"}"#.utf8))
    check(old.otherAppPluggedIn == .keepPlaying && old.otherAppOnBattery == .keepPlaying && old.batteryMode == .full,
          "a 1.6.4 wallpaper.json: keeps playing, battery mode kept")
    st.thermalHot = true
    check(WallpaperBudget.stillReason(WallpaperSettings(), st) == "Still — Mac is running hot", "hot Mac holds")
    // Low Power Mode holds a still (drawn first) instead of pausing: a wallpaper turned on in
    // Low Power used to never show a frame at all.
    var lp = WallpaperPowerMonitor.State()
    lp.lowPowerMode = true
    check(WallpaperBudget.stillReason(WallpaperSettings(), lp) == "Still — Low Power Mode", "Low Power Mode holds a still")
    check(WallpaperPacing.plan(.motion, fps: 30, still: true) == .none, "a held still runs no display link (one frame, drawn on entry)")
    check(WallpaperPacing.divisorRate(target: 20, refresh: 120) == 20 && WallpaperPacing.divisorRate(target: 20, refresh: 60) == 20,
          "20 fps is an exact divisor of 60 and 120 Hz")
    // Bloom steps its time at 24 fps: drawn at the slowest exact divisor at or above that
    check(WallpaperPacing.rate(target: 24, step: 24, refresh: 120) == 24 && WallpaperPacing.rate(target: 24, step: 24, refresh: 60) == 30
          && WallpaperPacing.rate(target: 120, step: 24, refresh: 120) == 24 && WallpaperPacing.rate(target: 24, step: nil, refresh: 60) == 20,
          "stepped 24 fps: 24 on 120 Hz, 30 on 60 Hz, never skipping a step")
    check(!SceneCatalog.penguinPresets.isEmpty && SceneCatalog.penguinPresets.allSatisfy { WallpaperPacing.steppedFPS($0) == 24 },
          "Penguin steps its time at 24 fps, like Bloom")
    // …and below 24 (Efficient's 20, the saver's Low Power 15) every other step, evenly: 12, an
    // exact divisor of 60, 120 and 144 Hz (20 or 15 would drop steps unevenly)
    check(WallpaperPacing.rate(target: 20, step: 24, refresh: 60) == 12 && WallpaperPacing.rate(target: 15, step: 24, refresh: 120) == 12
          && WallpaperPacing.rate(target: 15, step: 24, refresh: 144) == 12 && WallpaperPacing.rate(target: 15, step: 24, refresh: 50) == 16.666666666666668,
          "stepped 24 fps under budget: 12 (on twos) on 60/120/144 Hz; 50 Hz has no such divisor (plain divisor rule)")
    // StepClock: draws at exactly the step rate, encoded with up to ±3 ms of jitter around a
    // boundary, show every step once (no repeat-then-skip); 30 draws/s never skip; 12/s advance 2.
    do {
        func steps(drawFPS: Double, jitter: Double, phase0: Double, n: Int = 600) -> [Int] {
            var clock = StepClock(), out: [Int] = []
            var seed: UInt64 = 0x9E3779B97F4A7C15
            func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
            for k in 0..<n {
                let at = 1000 + Double(k) / drawFPS + (rnd() * 2 - 1) * jitter
                let t = at - 1000 + phase0 / 24                 // draws land phase0 steps past a boundary
                out.append(Int((clock.time(t, rate: 24, at: at) * 24).rounded(.down)))
            }
            return out
        }
        var worst24 = 0, worst30 = 0, worst12 = 0
        for p in [0.0, 0.01, 0.05, 0.5, 0.95, 0.99] { for j in [0.0, 0.003] {
            let a = steps(drawFPS: 24, jitter: j, phase0: p), b = steps(drawFPS: 30, jitter: j, phase0: p)
            let c = steps(drawFPS: 12, jitter: j, phase0: p)
            // after the first few draws (the lock), consecutive draws: 24/s → +1 each, 30/s → +0/+1, 12/s → +2
            worst24 += zip(a.dropFirst(4), a.dropFirst(5)).filter { $1 - $0 != 1 }.count
            worst30 += zip(b, b.dropFirst()).filter { $1 - $0 > 1 || $1 < $0 }.count
            worst12 += zip(c.dropFirst(4), c.dropFirst(5)).filter { $1 - $0 != 2 }.count
        } }
        check(worst24 == 0 && worst30 == 0 && worst12 == 0,
              "StepClock: 24 draws/s show each 24 fps step once, 12/s every other one, 30/s never skip (exact or ±3 ms jitter, at any phase; \(worst24)/\(worst12)/\(worst30) misses)")
    }
}

print("time of day")
do {
    let lib = DefaultPresets.makeLibrary()
    func p(_ n: String) -> Preset { lib.presets.first { $0.name == n } ?? Preset(name: n) }
    var live = p("Golden Hour")   // Follow the Sun on (what Tidewater was until 1.4.5)
    for i in live.effects.indices where live.effects[i].kind == .oceanHorizon { live.effects[i].params["live"] = 1 }
    check(WallpaperPacing.changesWithTimeOfDay(live), "Golden Hour with Follow the Sun follows the time of day")
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
    check(Playback.effectivePreset(in: lib, now: now, display: nil, live: nil).id == chrome, "no display (thumbnail, not known yet): the lineup")
    check(Playback.effectivePreset(in: lib, now: now, display: lg, live: nil).id == chrome, "no pins: every display plays the lineup")
    lib.displayStyles = [lg: DisplayPin(presetID: aurora, name: "LG HDR 4K")]
    check(Playback.effectivePreset(in: lib, now: now, display: lg, live: nil).id == aurora, "pinned display plays its own style")
    check(Playback.effectivePreset(in: lib, now: now, display: builtIn, live: nil).id == chrome, "other displays keep the lineup")
    check(Playback.effectivePreset(in: lib, now: now, display: nil, live: nil).id == chrome, "the thumbnail keeps the lineup")
    var rot = lib
    rot.rotation = RotationSpec(enabled: true, intervalMinutes: 5, presetIDs: [chrome, standby, universe])
    check(Playback.effectivePreset(in: rot, now: now, display: lg, live: nil).id == aurora
          && Playback.effectivePreset(in: rot, now: now, display: builtIn, live: nil).id == Playback.effectivePreset(in: rot, now: now, live: nil).id,
          "a pin overrides the rotation; the others rotate in step")
    var deleted = lib
    deleted.presets.removeAll { $0.id == aurora }
    check(Playback.effectivePreset(in: deleted, now: now, display: lg, live: nil).id == chrome, "deleted pinned style: that display falls back to the lineup")
    check(deleted.pruneDisplayStyles() && deleted.displayStyles == nil, "…and the pin is dropped on save (prune)")
    var kept = lib
    check(!kept.pruneDisplayStyles() && kept.displayStyles?[lg]?.presetID == aurora, "prune keeps a live pin")
    var newer = lib
    let gone = newer.presets.first { $0.id == aurora }!
    newer.presets.removeAll { $0.id == aurora }
    newer.unknownPresets = [UnknownPreset(index: 0, preset: gone)]
    check(!newer.pruneDisplayStyles(), "prune keeps a pin to a style only a newer build can draw")
    lib.displayStyles?[unplugged] = DisplayPin(presetID: standby, name: "Studio Display")
    check(Playback.effectivePreset(in: lib, now: now, display: builtIn, live: nil).id == chrome
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
    check(WallpaperPick.preset(display: lg, ws, lib, now: now, live: nil)?.id == universe, "wallpaper: no pin → the shared pick")
    ws.displayStyles = [lg: DisplayPin(presetID: standby, name: "LG HDR 4K")]
    check(WallpaperPick.preset(display: lg, ws, lib, now: now, live: nil)?.id == standby
          && WallpaperPick.preset(display: builtIn, ws, lib, now: now, live: nil)?.id == universe
          && WallpaperPick.shared(ws, lib, now: now, live: nil)?.id == universe, "wallpaper pin on its display only")
    var noStandby = lib
    noStandby.presets.removeAll { $0.id == standby }
    check(WallpaperPick.preset(display: lg, ws, noStandby, now: now, live: nil)?.id == universe, "deleted pinned wallpaper style → the shared pick")
    check(WallpaperPick.pruned(ws, noStandby).displayStyles.isEmpty && WallpaperPick.pruned(ws, lib) == ws, "wallpaper prune drops only dead pins")
    var synced = ws
    synced.followsScreensaver = true
    check(WallpaperPick.preset(display: lg, synced, lib, now: now, live: nil)?.id == aurora,
          "SYNC: the LG wallpaper shows the LG screensaver's own style (not its wallpaper pin)")
    check(WallpaperPick.preset(display: builtIn, synced, lib, now: now, live: nil)?.id == chrome
          && WallpaperPick.shared(synced, lib, now: now, live: nil)?.id == chrome, "SYNC: other displays show the lineup")
    check(WallpaperPick.preset(display: lg, synced, rot, now: now, live: nil)?.id == aurora
          && WallpaperPick.preset(display: builtIn, synced, rot, now: now, live: nil)?.id == Playback.effectivePreset(in: rot, now: now, live: nil).id,
          "SYNC with a rotation: pinned display holds, others rotate with the screensaver")
    var shared0 = ws
    shared0.presetID = UUID()
    check(WallpaperPick.shared(shared0, lib, now: now, live: nil) == nil, "deleted shared pick: nothing (the controller stops)")
    check(decode(#"{"enabled":true,"presetID":"\#(universe.uuidString)"}"#).displayStyles.isEmpty, "a 1.4.5 wallpaper.json: no pins")
    check(decode(#"{"enabled":true,"displayStyles":{"a":7}}"#).enabled, "malformed wallpaper pins are ignored, the rest decodes")
    let wurl = tmp.appendingPathComponent("wallpaper-pins.json")
    ws.save(to: wurl)
    check(WallpaperSettings.load(from: wurl) == ws, "wallpaper pins round-trip")
    var none = ws; none.displayStyles = [:]
    none.save(to: wurl)
    let rawNone = (try? JSONSerialization.jsonObject(with: Data(contentsOf: wurl))) as? [String: Any] ?? [:]
    check(rawNone["displayStyles"] == nil, "no displayStyles key while there are no pins")

    // 1. One display connected with a style of its own: that's what the app names as playing.
    check(Playback.shownPreset(in: lib, now: now, displays: [lg], live: nil).id == aurora,
          "one display, pinned: the app names its own style as playing")
    check(Playback.shownPreset(in: lib, now: now, displays: [builtIn], live: nil).id == chrome,
          "one display, unpinned: the lineup")
    check(Playback.shownPreset(in: lib, now: now, displays: [builtIn, lg], live: nil).id == chrome,
          "two displays, one pinned: the lineup (it's on screen)")
    var allPinned = lib
    allPinned.displayStyles?[builtIn] = DisplayPin(presetID: standby, name: "Built-in Retina Display")
    check(Playback.shownPreset(in: allPinned, now: now, displays: [builtIn, lg], live: nil).id == standby,
          "every display pinned: the first display's style")
    check(Playback.shownPreset(in: lib, now: now, displays: [], live: nil).id == chrome, "no displays known: the lineup")

    // 3. Leaving sync by giving one display a wallpaper of its own changes nothing else.
    var syncedStale = WallpaperSettings()
    syncedStale.enabled = true
    syncedStale.followsScreensaver = true
    syncedStale.presetID = standby                                   // the old own pick, not on screen
    syncedStale.displayStyles = [builtIn: DisplayPin(presetID: universe, name: "Built-in")]   // stale
    let left = WallpaperPick.leavingSync(syncedStale, rot, now: now, live: nil,
                                         pin: DisplayPin(presetID: universe, name: "Studio"), display: unplugged)
    check(!left.followsScreensaver && left.presetID == Playback.effectivePreset(in: rot, now: now, live: nil).id,
          "leaving sync: the shared pick becomes what the lineup shows now")
    check(left.displayStyles[lg]?.presetID == aurora && left.displayStyles[builtIn] == nil
          && left.displayStyles[unplugged]?.presetID == universe,
          "…the screensaver's pins become wallpaper pins, stale wallpaper pins go, the pick is added")
    for d in [builtIn, lg] {
        check(WallpaperPick.preset(display: d, left, rot, now: now, live: nil)?.id == WallpaperPick.preset(display: d, syncedStale, rot, now: now, live: nil)?.id,
              "…display \(d.prefix(4)) shows the same style before and after")
    }

    // 4. Deleting the shared wallpaper style while another display has its own.
    var afterDelete = lib
    afterDelete.presets.removeAll { $0.id == universe }
    let pinsLG = [lg: DisplayPin(presetID: standby, name: "LG")]
    check(WallpaperPick.sharedReplacement(pins: pinsLG, afterDelete, connected: [builtIn, lg]) == chrome,
          "shared pick deleted, LG has its own: the others move to the active style (no stop)")
    var noActive = afterDelete
    noActive.activeID = UUID()
    check(WallpaperPick.sharedReplacement(pins: pinsLG, noActive, connected: [builtIn, lg]) == standby,
          "…no active style: the surviving pin's style")
    check(WallpaperPick.sharedReplacement(pins: [:], afterDelete, connected: [builtIn]) == nil
          && WallpaperPick.sharedReplacement(pins: pinsLG, afterDelete, connected: [builtIn]) == nil,
          "nothing survives on a connected display: stop, as before")
    check(WallpaperPick.sharedReplacement(pins: [lg: DisplayPin(presetID: universe, name: "LG")], afterDelete,
                                          connected: [builtIn, lg]) == nil, "a pin to the deleted style doesn't count")

    // 5. Identical monitors sharing a UUID get distinct, stable keys.
    let u = "11111111-2222-3333-4444-555555555555"
    let twins: [DisplayIdentity.Entry] = [.init(id: 9, uuid: u, x: 1920, y: 0), .init(id: 4, uuid: u, x: 0, y: 0),
                                         .init(id: 1, uuid: "B", x: -1500, y: 0)]
    let tk = DisplayIdentity.keys(twins)
    check(tk[4] == u && tk[9] == u + "#2" && tk[1] == "B", "twin monitors: left one keeps the UUID, the right one \"#2\"")
    check(DisplayIdentity.keys(twins.reversed()) == tk && Set(tk.values).count == 3, "…deterministic, all keys unique")

    // 6. Pins of displays that come back under a new UUID, and the cap on unplugged ones.
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let moved = DisplayPins.reconcile([unplugged: DisplayPin(presetID: aurora, name: "DELL U2720Q", seen: 1)],
                                      connected: [(lg, "DELL U2720Q"), (builtIn, "Built-in Retina Display")], now: t0)
    check(moved?[lg]?.presetID == aurora && moved?[unplugged] == nil && moved?[lg]?.seen == t0.timeIntervalSince1970,
          "a display back under a new UUID adopts its pin (same name, the only candidate)")
    let ambiguous = [unplugged: DisplayPin(presetID: aurora, name: "DELL", seen: 1),
                     "OTHER": DisplayPin(presetID: standby, name: "DELL", seen: 2)]
    let amb = DisplayPins.reconcile(ambiguous, connected: [(lg, "DELL")], now: t0)
    check(amb == nil || (amb?[lg] == nil && amb?.count == 2), "two unplugged pins with that name: nothing adopted")
    check(DisplayPins.reconcile([lg: DisplayPin(presetID: aurora, name: "LG", seen: t0.timeIntervalSince1970 - 60)],
                                connected: [(lg, "LG")], now: t0) == nil, "connected and recently seen: no write")
    var many: [String: DisplayPin] = [:]
    for i in 0..<12 { many["GONE-\(i)"] = DisplayPin(presetID: aurora, name: "Display \(i)", seen: Double(i)) }
    many[lg] = DisplayPin(presetID: standby, name: "LG", seen: t0.timeIntervalSince1970)
    let capped = DisplayPins.reconcile(many, connected: [(lg, "LG")], now: t0) ?? many
    check(capped.count == 9 && capped[lg] != nil && capped["GONE-11"] != nil && capped["GONE-3"] == nil,
          "unplugged pins capped at the 8 most recently seen (\(capped.count - 1) kept); connected ones untouched")

    // 8. Unknown fields keep big integers exactly.
    let bigJSON = #"{"n":9007199254740993,"f":0.25,"neg":-42}"#
    let bigVal = try! JSONDecoder().decode(JSONValue.self, from: Data(bigJSON.utf8))
    let bigBack = String(data: try! JSONEncoder().encode(bigVal), encoding: .utf8)!
    check(bigBack.contains("9007199254740993") && bigBack.contains("0.25") && bigBack.contains("-42"),
          "JSONValue: 2^53+1 survives a round trip (\(bigBack))")
    var futureBig = oldJSON
    futureBig["stamp"] = NSNumber(value: Int64(9_007_199_254_740_993))
    let fb = try! JSONDecoder().decode(Library.self, from: JSONSerialization.data(withJSONObject: futureBig))
    check(String(data: try! enc.encode(fb), encoding: .utf8)!.contains("\"stamp\":9007199254740993"),
          "…as an unknown library field too")

    // 9. A new library has been through the Tidewater fold; the fold and the 1.4.2 retirement
    // move display pins too.
    check(DefaultPresets.makeLibrary().seenBuiltIns?.contains(DefaultPresets.tidewaterMarker) == true,
          "makeLibrary records the Tidewater fold as done")
    if let tideDef = DefaultPresets.builtInDefinition("Tidewater") {
        var tl = base
        tl.presets.append(tideDef)
        tl.activeID = chrome
        tl.rotation = nil
        tl.schedule = nil
        let gold = tl.presets.first { $0.name == "Golden Hour" }!.id
        tl.displayStyles = [lg: DisplayPin(presetID: tideDef.id, name: "LG")]
        let (folded, report) = DefaultPresets.foldTidewater(tl, wallpaperPick: nil)
        let goldOn = folded.presets.first { $0.id == gold }?.effects.first { $0.kind == .oceanHorizon }?.params["live"]
        check(folded.displayStyles?[lg]?.presetID == gold && goldOn == 1 && report.removed == ["Tidewater"],
              "fold: a display pinned to Tidewater moves to Golden Hour, which follows the sun (in use)")
        var tw = tl
        tw.displayStyles = nil
        let (folded2, _) = DefaultPresets.foldTidewater(tw, wallpaperPick: nil, wallpaperPins: [tideDef.id])
        let gold2 = folded2.presets.first { $0.id == gold }?.effects.first { $0.kind == .oceanHorizon }?.params["live"]
        check(gold2 == 1, "fold: a wallpaper pin to Tidewater counts as in use")
    } else { check(false, "Tidewater's definition exists") }
    if let sunray = DefaultPresets.builtInDefinition("Sunray"), let blue = DefaultPresets.builtInDefinition("Blue Hour") {
        var rl = base
        rl.presets += [sunray, blue]
        rl.displayStyles = [lg: DisplayPin(presetID: sunray.id, name: "LG"), builtIn: DisplayPin(presetID: blue.id, name: "B")]
        let (retired, _) = DefaultPresets.retireUntouched(rl)
        let chrono = retired.presets.first { $0.name == "Chronometer" }?.id
        check(retired.displayStyles?[lg]?.presetID == chrono && retired.displayStyles?[builtIn] != nil
              && retired.displayStyles?[builtIn]?.presetID != blue.id,
              "retirement: pins move to the replacement (Sunray → Chronometer)")
    } else { check(false, "the retired definitions exist") }

    // Identity: a display's key is stable (read only; nothing is shown)
    let main = CGMainDisplayID()
    let k1 = DisplayIdentity.key(main), k2 = DisplayIdentity.key(main)
    check(k1 != nil && k1 == k2 && UUID(uuidString: k1 ?? "") != nil, "the main display has a stable UUID key")
    if let screen = NSScreen.screens.first {
        check(DisplayIdentity.key(screen) == DisplayIdentity.displayID(screen).flatMap(DisplayIdentity.key),
              "NSScreen → NSScreenNumber → key")
    }
}

// MARK: When rules (Shared/Signals: Playback's overlay, the lease, RuleEngine)

print("when rules")
do {
    let base = DefaultPresets.makeLibrary()
    func id(_ n: String) -> UUID { base.presets.first { $0.name == n }!.id }
    let chrome = id("Liquid Chrome"), aurora = id("Aurora"), standby = id("StandBy"), universe = id("Universe")
    let lg = "A1B2C3D4-0000-1111-2222-333344445555"
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let t = now.timeIntervalSince1970
    let snow = PlayRule(name: "Snow day", when: RuleCondition(all: [RuleClause(signal: "weather.condition", op: .eq, value: .string("snow"))]),
                        play: [aurora])
    func lease(_ r: UUID?, since: Double = t - 60, until: Double = t + 1800) -> SignalState {
        var s = SignalState(); s.rule = RuleLease(id: r, since: since, validUntil: until); return s
    }
    var lib = base
    lib.activeID = chrome
    lib.rotation = RotationSpec(enabled: true, intervalMinutes: 5, presetIDs: [chrome, standby, universe])
    lib.schedule = nil
    lib.rules = [snow]
    let live = lease(snow.id)

    // Precedence: pin > rule > night > rotation
    let rotating = Playback.effectivePreset(in: lib, now: now, live: nil).id
    check([chrome, standby, universe].contains(rotating), "no lease: the rotation plays")
    check(Playback.effectivePreset(in: lib, now: now, live: live).id == aurora, "an active rule beats the rotation")
    var night = lib
    night.schedule = ScheduleSpec(enabled: true, dayPresetID: standby, nightPresetID: standby)
    check(Playback.effectivePreset(in: night, now: now, live: nil).id == standby
          && Playback.effectivePreset(in: night, now: now, live: live).id == aurora, "…and the day/night schedule")
    var pinned = lib
    pinned.displayStyles = [lg: DisplayPin(presetID: universe, name: "LG")]
    check(Playback.effectivePreset(in: pinned, now: now, display: lg, live: live).id == universe
          && Playback.effectivePreset(in: pinned, now: now, display: nil, live: live).id == aurora,
          "a display's own style beats the rule; the others play the rule")
    check(Playback.shownPreset(in: lib, now: now, displays: [lg], live: live).id == aurora, "shownPreset follows the rule")
    var off = lib
    off.rules?[0].enabled = false
    check(Playback.effectivePreset(in: off, now: now, live: live).id == rotating, "a disabled rule's lease is ignored")
    var gone = lib
    gone.presets.removeAll { $0.id == aurora }
    check(Playback.effectivePreset(in: gone, now: now, live: live).id != aurora, "a rule whose style is gone: the lineup")
    var two = lib
    two.rules = [PlayRule(id: snow.id, name: "Snow", when: snow.when, play: [aurora, standby])]
    two.rotation?.enabled = false
    let a = Playback.effectivePreset(in: two, now: now, live: live).id
    let b = Playback.effectivePreset(in: two, now: now.addingTimeInterval(300), live: live).id
    check(Set([a, b]) == Set([aurora, standby]), "a rule with two styles rotates them (the playlist's interval)")
    check(Playback.secondsUntilNextSlot(in: two, now: now, live: live) != nil && Playback.secondsUntilNextSlot(in: two, now: now, live: nil) == nil,
          "…so the next slot is scheduled even with the rotation off")

    // Lease expiry: a quit app's decision runs out
    check(lease(snow.id, until: t - 1).activeRuleID(at: now) == nil
          && Playback.effectivePreset(in: lib, now: now, live: lease(snow.id, until: t - 1)).id == rotating,
          "an expired lease: the lineup again")
    check(lease(nil).activeRuleID(at: now) == nil && lease(snow.id).activeRuleID(at: now) == snow.id, "lease: id while valid, nil for “no rule”")
    let leaseJSON = try! JSONEncoder().encode(live)
    check((try? JSONDecoder().decode(SignalState.self, from: leaseJSON)) == live, "signal-values.json round-trips")
    check((try? JSONDecoder().decode(SignalState.self, from: Data(#"{"values":{"x":{"v":1}},"future":true}"#.utf8)))?.values["x"]?.v == 1,
          "a newer writer's extra fields don't break the readers")

    // Wallpaper "Same as Screensaver" follows the rule
    var ws = WallpaperSettings()
    ws.enabled = true
    ws.followsScreensaver = true
    check(WallpaperPick.shared(ws, lib, now: now, live: live)?.id == aurora
          && WallpaperPick.preset(display: lg, ws, pinned, now: now, live: live)?.id == universe,
          "the wallpaper matching the screensaver plays the rule (a pinned display keeps its style)")

    // Pruning on style delete
    var pr = lib
    pr.rules = [snow, PlayRule(name: "Two", when: snow.when, play: [aurora, standby])]
    pr.removePreset(aurora)
    check(pr.rules?.count == 1 && pr.rules?[0].play == [standby], "deleting a style: rules lose it; one left with none goes")
    pr.removePreset(standby)
    check(pr.rules == nil, "…and no rules left: the field goes")

    // library.json: round trip, and a newer build's rules kept verbatim
    var withSignal = lib
    var sig = Signal(name: "Air quality")
    sig.url = "https://example.com/aqi"; sig.pointer = "/aqi"; sig.range = [0, 300]
    sig.auth = SignalAuth(placement: .header, name: "X-API-Key")
    withSignal.signals = [sig]
    let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
    let data = try! enc.encode(withSignal)
    let back = try! JSONDecoder().decode(Library.self, from: data)
    check(back.signals == [sig] && back.rules == lib.rules, "signals and rules round-trip")
    check(String(data: data, encoding: .utf8)!.contains(#""auth":{"in":"header","name":"X-API-Key"}"#), "auth stores where the key goes, no value")
    var raw = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    raw["rules"] = [["id": UUID().uuidString, "name": "Future", "when": ["all": [["signal": "x", "op": "matchesRegex", "value": "a"]]], "play": []]]
    let fut = try! JSONDecoder().decode(Library.self, from: JSONSerialization.data(withJSONObject: raw))
    let futBack = try! JSONSerialization.jsonObject(with: enc.encode(fut)) as! [String: Any]
    check(fut.rules == nil && ((futBack["rules"] as? [[String: Any]])?.first?["name"] as? String) == "Future",
          "rules a newer build wrote (an op this build doesn't know) survive a save verbatim")

    // RuleEngine: first match wins, hysteresis, hold, stale
    func val(_ v: Double, age: Double = 60) -> SignalValue { SignalValue(v: v, at: t - age, stale: 1800) }
    let low = PlayRule(name: "Low battery", when: RuleCondition(all: [RuleClause(signal: "power.battery", op: .lt, value: .number(20))]),
                       play: [standby], holdMinutes: 0)
    let range: (String) -> ClosedRange<Double>? = { lib.signalInfo($0)?.range }
    let styles = Set(lib.presets.map(\.id))
    func decide(_ rules: [PlayRule], _ values: [String: SignalValue], prev: RuleLease? = nil, night: Bool = false, at: Date = now) -> UUID? {
        RuleEngine.decide(rules: rules, styles: styles, values: { values[$0] }, range: range, isNight: night, previous: prev, now: at).id
    }
    check(decide([low], ["power.battery": val(19)]) == low.id && decide([low], ["power.battery": val(21)]) == nil, "lt 20: 19 on, 21 off")
    let on = RuleLease(id: low.id, since: t - 3600, validUntil: t + 600)
    check(decide([low], ["power.battery": val(24)], prev: on) == low.id, "hysteresis: once on, 24 still holds (5 % of 0…100 back)")
    check(decide([low], ["power.battery": val(26)], prev: on) == nil, "…26 lets go")
    check(decide([low], ["power.battery": val(19, age: 3600)]) == nil, "a stale value counts as false")
    check(decide([low], [:]) == nil, "a missing value counts as false")
    var held = low
    held.holdMinutes = 10
    check(decide([held], ["power.battery": val(80)], prev: RuleLease(id: low.id, since: t - 60, validUntil: t + 600)) == low.id,
          "hold: a rule on for 1 minute stays (10-minute hold) though it no longer matches")
    check(decide([held], ["power.battery": val(80)], prev: RuleLease(id: low.id, since: t - 660, validUntil: t + 600)) == nil,
          "…and lets go after its hold")
    let both: [String: SignalValue] = ["power.battery": val(10), "weather.condition": SignalValue(s: "Snow", at: t - 60, stale: 1800)]
    check(decide([snow, low], both) == snow.id && decide([low, snow], both) == low.id, "the first matching rule in list order wins (words match any case)")
    var disabled = snow
    disabled.enabled = false
    check(decide([disabled, low], both) == low.id, "a disabled rule is skipped")
    let nowhere = PlayRule(name: "Nowhere", when: snow.when, play: [UUID()])
    check(decide([nowhere, low], both) == low.id, "a rule with no style left is skipped")
    var nightOnly = snow
    nightOnly.when.timeOfDay = "night"
    check(decide([nightOnly], both, night: false) == nil && decide([nightOnly], both, night: true) == snow.id, "timeOfDay night")
    let keep = RuleEngine.decide(rules: [snow], styles: styles, values: { both[$0] }, range: range, isNight: false,
                                 previous: RuleLease(id: snow.id, since: t - 500, validUntil: t + 100), now: now)
    check(keep.since == t - 500 && keep.validUntil == t + SignalState.leaseSeconds, "the same rule keeps its start; the lease is renewed")
    let between = PlayRule(name: "Mild", when: RuleCondition(all: [RuleClause(signal: "weather.tempC", op: .between, values: [.number(10), .number(20)])]), play: [aurora])
    check(decide([between], ["weather.tempC": val(15)]) == between.id && decide([between], ["weather.tempC": val(22)]) == nil
          && decide([between], ["weather.tempC": val(22)], prev: RuleLease(id: between.id, since: t - 3600, validUntil: t)) == between.id,
          "between 10–20: 15 on, 22 off, 22 held once on (5 % of −30…45 ≈ 3.75)")
    check(RuleEngine.validate(PlayRule(name: "x", when: RuleCondition(all: [RuleClause(signal: "weather.condition", op: .gt, value: .number(1))]), play: [aurora]), in: lib)
            .contains { $0.contains("is a word") }, "validate: op vs type")
    check(RuleText.condition(snow.when, in: lib) == "Weather is Snow", "a rule in words")

    // Scene inputs: a binding makes a signal watched (like a rule test) and holds it on delete.
    var bl = Library()
    var air = Signal(name: "Air")
    air.kind = .file; air.file = "air.txt"
    bl.signals = [air]
    var custom = EffectInstance(.custom)
    custom.custom = CustomSceneRef(id: "haze-3a71c0de")
    custom.inputs = ["aqi": InputBinding(signal: air.key.lowercased()), "warm": InputBinding(signal: "weather.tempC")]
    bl.presets = [Preset(name: "Haze", effects: [custom])]
    check(bl.ruleSignalKeys.isEmpty && bl.referencedSignalKeys == [air.key, "weather.tempC"],
          "bindings count as references (a UUID in any case): the app fetches them, the weather too")
    check(bl.deleteSignal(air.id, force: false)?.contains("scene input") == true && bl.signals?.count == 1,
          "deleting a signal a scene input is bound to: refused")
    check(bl.deleteSignal(air.id, force: true) == nil && bl.signals == nil
          && bl.presets[0].effects[0].inputs == ["warm": InputBinding(signal: "weather.tempC")],
          "…force: the signal goes and the input is disconnected (the other binding stays)")
    bl.presets[0].effects[0].enabled = false
    check(bl.referencedSignalKeys.isEmpty, "a hidden effect's bindings aren't watched")
}

// MARK: Location (Library.locationMode / manualPlace / autoPlace)

print("location")
do {
    /// A library as an older build writes it (37.77, -122.42 from the IP lookup), plus `extra` keys.
    func lib(_ extra: String) -> Library? {
        var base = Library(); base.locationLat = 37.77; base.locationLon = -122.42
        guard var obj = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(base))) as? [String: Any],
              let more = (try? JSONSerialization.jsonObject(with: Data("{\(extra.dropFirst())}".utf8))) as? [String: Any] ?? (extra.isEmpty ? [:] : nil)
        else { return nil }
        obj.merge(more) { _, new in new }
        return (try? JSONSerialization.data(withJSONObject: obj)).flatMap { try? JSONDecoder().decode(Library.self, from: $0) }
    }
    func roundTrip(_ l: Library) -> Library? {
        (try? JSONEncoder().encode(l)).flatMap { try? JSONDecoder().decode(Library.self, from: $0) }
    }
    var l = lib("")!
    check(!l.usesManualLocation && l.locationPlaceName == nil, "an older library: automatic, no name yet")
    l.autoPlace = NamedPlace(name: "San Francisco, California", lat: 37.77, lon: -122.42)
    check(l.locationPlaceName == "San Francisco, California", "the IP lookup's name while it matches the location")
    l.setManualLocation(NamedPlace(name: "Toronto, Ontario", lat: 43.65, lon: -79.38))
    check(l.usesManualLocation && l.locationLat == 43.65 && l.locationLon == -79.38 && l.locationPlaceName == "Toronto, Ontario",
          "manual: every reader's locationLat/Lon follow the user's place")
    let back = roundTrip(l)
    check(back == l && back?.locationMode == "manual" && back?.manualPlace?.name == "Toronto, Ontario", "manual place round-trips")
    l.setAutomaticLocation()
    check(!l.usesManualLocation && l.manualPlace == nil && l.locationLat == 37.77 && l.locationPlaceName == "San Francisco, California",
          "back to automatic: the last IP answer until the next lookup")
    let bad = lib(#","locationMode":"manual","manualPlace":{"name":"Nowhere","lat":200,"lon":0},"autoPlace":"oops""#)
    check(bad != nil && bad?.manualPlace == nil && bad?.autoPlace == nil && bad?.usesManualLocation == false,
          "a malformed place is dropped, never the library (and without one it's automatic)")
    let future = lib(#","locationMode":"device""#)
    check(future?.usesManualLocation == false && roundTrip(future!)?.locationMode == "device", "an unknown mode is automatic here, kept for its build")
    let stale = lib(#","autoPlace":{"name":"Elsewhere","lat":1,"lon":2}"#)
    check(stale?.locationPlaceName == nil, "an IP name for another location isn't shown")
    check(NamedPlace.coordinateName(-33.87, 151.21) == "33.9° S, 151.2° E", "coordinates name a place")
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

// MARK: Signals: where an AI-made signal's host points (Shared/Signals/Fetch/SignalFetch.swift)
// A fake resolver only: no real DNS lookup.

print("signals: DNS policy")
do {
    for a in ["10.1.2.3", "127.0.0.1", "0.0.0.0", "169.254.169.254", "172.20.0.1", "192.168.1.5", "100.100.100.100",
              "224.0.0.251", "255.255.255.255", "::", "::1", "fe80::1", "fe80::1%en0", "fec0::1", "fd12:3456::1", "fc00::1",
              "ff02::1", "::ffff:192.168.1.1", "::10.0.0.1", "64:ff9b::a00:1", "2002:c0a8:0101::1"] {
        check(SignalPolicy.isPrivateAddress(a) == true, "private / local: \(a)")
    }
    for a in ["93.184.216.34", "1.1.1.1", "172.32.0.1", "100.128.0.1", "2606:4700::1111", "::ffff:8.8.8.8", "64:ff9b::808:808", "2002:0808:0808::1"] {
        check(SignalPolicy.isPrivateAddress(a) == false, "public: \(a)")
    }
    check(SignalPolicy.isPrivateAddress("example.com") == nil, "a name isn't an address")
    let table: [String: [String]] = ["public.example": ["93.184.216.34", "2606:2800:220:1::1"],
                                     "rebind.example": ["10.0.0.5"],
                                     "mixed.example": ["93.184.216.34", "192.168.0.10"],
                                     "v6local.example": ["fd00::7"],
                                     "mapped.example": ["::ffff:127.0.0.1"],
                                     "junk.example": ["not-an-address"]]
    var asked: [String] = []
    let fake: (String) -> [String]? = { asked.append($0); return table[$0] }
    check(SignalPolicy.resolvedRefusal("public.example", resolve: fake) == nil, "a name with only public addresses: allowed")
    for h in ["rebind.example", "mixed.example", "v6local.example", "mapped.example", "junk.example"] {
        check(SignalPolicy.resolvedRefusal(h, resolve: fake)?.contains("local network") == true, "\(h): refused (ANY private address)")
    }
    check(SignalPolicy.resolvedRefusal("nowhere.example", resolve: fake) == "Host not found", "a name that doesn't resolve: Host not found")
    check(asked.count == 7, "every check asked the (fake) resolver")
    check(SignalPolicy.hostToResolve(URL(string: "https://api.example.com/x")) == "api.example.com"
          && SignalPolicy.hostToResolve(URL(string: "https://API.Example.com./x")) == "api.example.com",
          "names are resolved (lowercased, trailing dot dropped)")
    check(SignalPolicy.hostToResolve(URL(string: "https://93.184.216.34/x")) == nil
          && SignalPolicy.hostToResolve(URL(string: "https://[2606:4700::1111]/x")) == nil,
          "IP literals aren't looked up (refusal() judges them as written)")
}

// MARK: Live weather: only what actually reads it (Shared/Weather/WeatherFeed.swift)

print("weather: who needs the live feed")
do {
    let store = SharedStore(role: .app).baseDir    // DOTSTUDIO_STORE_DIR: run.sh's temp dir
    var lib = DefaultPresets.makeLibrary()
    func ocean(_ weather: Double, enabled: Bool = true) -> Preset {
        var e = EffectInstance(.oceanHorizon)
        e.params["weather"] = weather
        e.enabled = enabled
        return Preset(name: "Ocean \(weather)", effects: [e])
    }
    check(WeatherLink.followsLive(ocean(0)), "Ocean Horizon, Weather Live: follows the live weather")
    check(!WeatherLink.followsLive(ocean(2)) && !WeatherLink.followsLive(ocean(10)), "…pinned to a condition: doesn't")
    check(!WeatherLink.followsLive(ocean(0, enabled: false)), "…a disabled scene doesn't")
    lib.presets = [ocean(2)]
    lib.rules = nil
    check(!WeatherLink.needed(by: lib, store: store), "a library of pinned weather: no fetch")
    lib.presets.append(ocean(0))
    check(WeatherLink.needed(by: lib, store: store), "…one Live style: fetch")
    lib.presets = [ocean(3)]
    lib.rules = [PlayRule(name: "Rainy", when: RuleCondition(all: [RuleClause(signal: "weather.condition", op: .eq, value: .string("rain"))]),
                          play: [lib.presets[0].id])]
    check(WeatherLink.needed(by: lib, store: store), "…a When rule on weather.*: fetch")
    lib.rules![0].enabled = false
    check(!WeatherLink.needed(by: lib, store: store), "…the rule disabled: no fetch")
    lib.rules = nil

    // A film that follows the weather (Commute: light layers, uses weather) — unless the style pins it.
    if let m = CustomScenes.manifest(id: "commute-5e7a1c0d", store: store) {
        var film = Preset.customScene(m)
        lib.presets = [film]
        check(WeatherLink.followsLive(film) && WeatherLink.needed(by: lib, store: store), "a film on Live weather: follows it, fetch")
        film.effects[0].params["ds.weather"] = 7      // Rain, pinned
        lib.presets = [film]
        check(!WeatherLink.followsLive(film) && !film.customUses("weather") && !WeatherLink.needed(by: lib, store: store),
              "the same film pinned to Rain: no live weather (although its manifest uses it)")
        check(film.customUses("sun"), "…it still follows the sun")
    } else {
        check(false, "the built-in Commute film package is readable")
    }
}

// MARK: AI library edits: WallpaperChoice (Shared/AI/LibraryOps.swift)

print("AI edits: the wallpaper choice")
do {
    let lib = DefaultPresets.makeLibrary()
    let a = lib.presets[0].id, b = lib.presets[1].id
    let json: [String: Any] = ["enabled": true, "presetID": a.uuidString, "frameRate": 120, "futureField": "kept",
                               "displayStyles": ["LG": ["presetID": b.uuidString, "name": "LG"]]]
    var c = WallpaperChoice(json: json)
    check(c.enabled && c.presetID == a && !c.followsScreensaver && c.displayStyles["LG"]?.presetID == b, "reads wallpaper.json's fields")
    c.displayStyles = [:]
    c.presetID = nil
    let back = c.merged(into: json)
    check(back["futureField"] as? String == "kept" && back["frameRate"] as? Int == 120 && back["displayStyles"] == nil
          && back["presetID"] == nil && back["enabled"] as? Bool == true, "writes its fields back over the rest (unknown ones kept)")

    // A deleted shared pick: a connected display's own style keeps it going, else it stops.
    var after = lib
    after.removePreset(a)
    var d = WallpaperChoice(enabled: true, presetID: a, displayStyles: ["LG": DisplayPin(presetID: b, name: "LG")])
    d.styleDeleted(a, in: after, connected: ["LG"])
    check(d.enabled && d.presetID != a && d.presetID != nil, "deleted shared pick, LG keeps its own: the others move on")
    var e = WallpaperChoice(enabled: true, presetID: a)
    e.styleDeleted(a, in: after, connected: ["LG"])
    check(!e.enabled, "deleted shared pick, nothing else: the wallpaper stops")
    var f = WallpaperChoice(enabled: true, presetID: a, followsScreensaver: true, displayStyles: ["LG": DisplayPin(presetID: a, name: "LG")])
    f.styleDeleted(a, in: after, connected: ["LG"])
    check(f.enabled && f.followsScreensaver && f.displayStyles.isEmpty, "following the screensaver: stays on; the dead pin goes")

    // A refusal leaves nothing half done.
    var l2 = lib
    var w2 = WallpaperChoice()
    var settings = AISettings()
    settings.allowPlaybackChanges = false
    let ctx = LibraryOps.Context(displays: [DisplayEntry(key: "LG", name: "LG", builtIn: false)], settings: settings, live: nil)
    let r = LibraryOps.apply(BridgeRequest(op: .setWallpaper, id: a, mode: "set"), library: &l2, wallpaper: &w2, ctx)
    check(!r.ok && r.error == LibraryOps.playbackOff && l2 == lib && w2 == WallpaperChoice(), "gated: refused, nothing changed")
    settings.allowPlaybackChanges = true
    let ok2 = LibraryOps.Context(displays: ctx.displays, settings: settings, live: nil)
    let u = LibraryOps.apply(BridgeRequest(op: .setScreensaver, display: "NOPE", mode: "unpin"), library: &l2, wallpaper: &w2, ok2)
    check(!u.ok && u.error?.contains("NOPE") == true, "unpin an unknown display: refused")
}

// MARK: A real still (offscreen render + HEIC write; nothing is set anywhere)

print("real still")
do {
    let store = SharedStore(role: .app)    // DOTSTUDIO_STORE_DIR: run.sh's temp dir
    let lib = DefaultPresets.makeLibrary()
    let dir = tmp.appendingPathComponent("store/lockscreen-real")
    let pic = LockScreenPicture(dir: dir, desktop: FakeDesktop([], shown: [:]))
    for name in ["Golden Hour", "StandBy", "Liquid Chrome"] {
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
