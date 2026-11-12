//  setup-guide-check — checks App/SetupGuideStore.swift (see run.sh). Read-only throughout.

import AppKit

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print("\(ok ? "ok  " : "FAIL") \(what)")
    if !ok { failures += 1 }
}

// MARK: Synthetic stores

func config(_ module: String) -> Data {
    try! PropertyListSerialization.data(fromPropertyList: ["module": ["relative": module]], format: .binary, options: 0)
}
func entry(_ module: String?, type: String = "individual") -> [String: Any] {
    guard let module else { return ["Type": type] }
    let provider = module == "default" ? "default" : "com.apple.wallpaper.choice.screen-saver"
    var choice: [String: Any] = ["Provider": provider]
    if module != "default" { choice["Configuration"] = config(module) }
    return ["Type": type, "Idle": ["Content": ["Choices": [choice], "Shuffle": "$null"]]]
}
func store(_ root: [String: Any]) -> Data {
    try! PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
}

let ours = "file:///Users/me/Library/Screen%20Savers/DotStudio.saver"
let drift = "file:///System/Library/ExtensionKit/Extensions/Drift.appex"
let A = "AAAAAAAA-0000-0000-0000-000000000001", B = "BBBBBBBB-0000-0000-0000-000000000002"
typealias D = WallpaperStoreReader.Display

// Two displays on Space "": A chose DotStudio, B chose Drift; stale Spaces mention DotStudio.
let twoDisplays = store([
    "AllSpacesAndDisplays": "$null",
    "SystemDefault": entry(drift),
    "Spaces": [
        "": ["Default": entry(drift), "Displays": [A: entry(ours), B: entry(drift)]],
        "OLD-SPACE": ["Default": entry(ours), "Displays": [B: entry(ours)]],
    ],
    "Displays": [A: entry(ours), B: entry(ours)],
])
let r1 = WallpaperStoreReader.resolve(indexData: twoDisplays,
                                      displays: [D(uuid: A, isMain: true, currentSpace: ""),
                                                 D(uuid: B, isMain: false, currentSpace: "")])
check(r1 == .init(perDisplay: [true, false]), "per display, current Space only: 1 of 2 (\(String(describing: r1)))")

// Linked display falls through to the Space's Default; "default" provider → SystemDefault.
let linked = store([
    "AllSpacesAndDisplays": "$null",
    "SystemDefault": entry(ours),
    "Spaces": ["S1": ["Default": entry("default"), "Displays": [A: entry(nil, type: "linked")]]],
])
let r2 = WallpaperStoreReader.resolve(indexData: linked, displays: [D(uuid: A, isMain: true, currentSpace: "S1")])
check(r2?.perDisplay == [true], "linked → Space default → provider default → SystemDefault (DotStudio)")

// AllSpacesAndDisplays wins over everything.
let everywhere = store([
    "AllSpacesAndDisplays": entry(drift),
    "SystemDefault": entry(ours),
    "Spaces": ["": ["Displays": [A: entry(ours)]]],
])
let r3 = WallpaperStoreReader.resolve(indexData: everywhere, displays: [D(uuid: A, isMain: true, currentSpace: "")])
check(r3?.perDisplay == [false], "AllSpacesAndDisplays applies to every display")

// Unknown Space → the display's own entry → SystemDefault.
let r4 = WallpaperStoreReader.resolve(indexData: twoDisplays, displays: [D(uuid: B, isMain: false, currentSpace: nil)])
check(r4?.perDisplay == [true], "no current Space: the display's own entry")
check(WallpaperStoreReader.resolve(indexData: Data("nope".utf8), displays: []) == nil, "garbage → nil")
check(WallpaperStoreReader.mentionsSaver(indexData: twoDisplays) == true, "fallback scan finds DotStudio")

let spacesConf: [String: Any] = ["Management Data": ["Monitors": [
    ["Display Identifier": "Main", "Current Space": ["uuid": ""]],
    ["Display Identifier": B, "Current Space": ["uuid": "S2"]],
    ["Display Identifier": "STALE"],
]]]
let cs = WallpaperStoreReader.currentSpaces(spacesConfiguration: spacesConf)
check(cs == ["Main": "", B: "S2"], "current Spaces from com.apple.spaces")
check(WallpaperStoreReader.space(for: A, in: cs) == "" && WallpaperStoreReader.space(for: B, in: cs) == "S2",
      "a display without its own Spaces uses Main's")

// MARK: pmset

let pmset = """
Battery Power:
 Sleep On Power Button 1
 displaysleep         2
 sleep                1
AC Power:
 displaysleep         10
 sleep                0
"""
let t = DisplaySleepTimers.parse(pmsetCustom: pmset)
check(t == DisplaySleepTimers(battery: 2, ac: 10, ups: nil), "pmset -g custom: battery 2, AC 10")
check(DisplaySleepTimers.parse(pmsetCustom: "AC Power:\n displaysleep 0\n").hasBattery == false, "desktop Mac: no battery section")
check(SetupWords.duration(seconds: 300) == "5 minutes" && SetupWords.duration(seconds: 3600) == "1 hour"
      && SetupWords.short(seconds: 120) == "2 min", "durations in words")

// MARK: This Mac (a read-only copy of the real store)

if CommandLine.arguments.count > 1 {
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    let data = try! Data(contentsOf: url)
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var n: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &n)
    let spaces = WallpaperStoreReader.currentSpaces(
        spacesConfiguration: CFPreferencesCopyAppValue("SpacesDisplayConfiguration" as CFString, "com.apple.spaces" as CFString))
    let displays: [D] = ids.prefix(Int(n)).compactMap { id in
        guard CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay,
              let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let s = CFUUIDCreateString(nil, u) as String? else { return nil }
        return D(uuid: s, isMain: CGDisplayIsMain(id) != 0, currentSpace: WallpaperStoreReader.space(for: s, in: spaces))
    }
    let r = WallpaperStoreReader.resolve(indexData: data, displays: displays)
    print("this Mac: \(displays.count) display(s) \(displays.map { "\($0.uuid.prefix(8)) space=\($0.currentSpace.map { "'\($0.prefix(8))'" } ?? "?")" })")
    print("this Mac: DotStudio chosen on \(r?.chosen ?? -1) of \(r?.total ?? -1); any mention: \(WallpaperStoreReader.mentionsSaver(indexData: data).map(String.init) ?? "?")")
    check(r != nil && r!.total == max(displays.count, 1), "the real store parses (\(data.count) bytes)")

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["-g", "custom"]
    let pipe = Pipe(); p.standardOutput = pipe
    try? p.run(); p.waitUntilExit()
    let timers = DisplaySleepTimers.parse(pmsetCustom: String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    print("this Mac: display sleep battery=\(timers.battery.map(String.init) ?? "-") ac=\(timers.ac.map(String.init) ?? "-") min")
    check(timers.ac != nil || timers.battery != nil, "pmset parses on this Mac")
}

// MARK: Where the app runs from (Move to Applications)

let home = "/Users/me"
check(!AppLocation.shouldOfferMove(bundlePath: "/Applications/DotStudio.app", home: home), "location: /Applications → stay")
check(!AppLocation.shouldOfferMove(bundlePath: "/Applications/Utilities/DotStudio.app", home: home), "location: a subfolder of /Applications → stay")
check(!AppLocation.shouldOfferMove(bundlePath: "/Users/me/Applications/DotStudio.app", home: home), "location: ~/Applications → stay")
check(AppLocation.shouldOfferMove(bundlePath: "/private/var/folders/x/T/AppTranslocation/1234-ABCD/d/DotStudio.app", home: home),
      "location: App Translocation → offer the move")
check(AppLocation.shouldOfferMove(bundlePath: "/Users/me/Downloads/DotStudio.app", home: home), "location: Downloads → offer the move")
check(AppLocation.shouldOfferMove(bundlePath: "/Volumes/DotStudio 1.4.5/DotStudio.app", home: home), "location: the disk image → offer the move")
check(!AppLocation.shouldOfferMove(bundlePath: "/Users/me/Developer/DotStudio/build/Build/Products/Release/DotStudio.app", home: home),
      "location: a build product → never")
check(AppLocation.shouldOfferMove(bundlePath: "/ApplicationsOld/DotStudio.app", home: home), "location: a look-alike folder → offer the move")
check(AppLocation.shouldOfferMove(bundlePath: "/Users/me/Applications Backup/DotStudio.app", home: home),
      "location: ~/Applications Backup → offer the move")

print(failures == 0 ? "all checks passed" : "\(failures) check(s) FAILED")
exit(failures == 0 ? 0 : 1)
