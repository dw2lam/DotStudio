//  setup-coach-check — checks App/SetupCoachMatch.swift (see run.sh): the fixture System
//  Settings trees (Fixtures.swift), the coordinate and callout geometry, label loading, and —
//  given DOTSTUDIO_AX_DUMP .json captures as arguments — what the coach finds in each.
//  Never touches System Settings; reads only its string tables (read-only).

import Foundation
import CoreGraphics

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print("\(ok ? "ok  " : "FAIL") \(what)")
    if !ok { failures += 1 }
}
func fmt(_ r: CGRect?) -> String {
    guard let r else { return "nil" }
    return String(format: "(%.0f,%.0f %.0fx%.0f)", r.minX, r.minY, r.width, r.height)
}

// MARK: Dumps given on the command line: just report

let dumps = CommandLine.arguments.dropFirst().filter { $0.hasSuffix(".json") }
if !dumps.isEmpty {
    let strings = CoachStrings.system()
    print("labels: wallpaper=\(strings.wallpaper.sorted()) button=\(strings.screenSaverButton.sorted()) other=\(strings.other.sorted()) done=\(strings.done.sorted())")
    for path in dumps {
        guard let data = FileManager.default.contents(atPath: path),
              let tree = try? JSONDecoder().decode(AXNodeSnapshot.self, from: data) else {
            print("FAIL can't read \(path) as an AX dump"); failures += 1; continue
        }
        let scene = CoachMatcher.match(tree, strings: strings)
        let d = CoachPlanner.decide(scene, chosenOn: 0, chosenOf: 1, chosenWhenOpened: 0)
        print("\(path):")
        print("  page=\(scene.page) window=\(fmt(scene.window)) sidebarRow=\(fmt(scene.wallpaperRow))")
        print("  screenSaverButton=\(fmt(scene.screenSaverButton)) pageScroll=\(fmt(scene.pageScrollArea))")
        print("  chooser=\(fmt(scene.chooser)) sheet=\(scene.chooserIsSheet) list=\(fmt(scene.scrollArea)) other=\(fmt(scene.otherHeader))")
        print("  tile=\(fmt(scene.tile)) outOfView=\(scene.tileOutOfView) selected=\(scene.tileSelected) done=\(fmt(scene.done))")
        print("  → step \(d.step.name) (\(d.situation)) ring=\(fmt(d.target)) \(d.kind) \"\(d.callout ?? "")\"")
    }
    exit(failures == 0 ? 0 : 1)
}

// MARK: Fixtures

let all = cases()
for c in all {
    let scene = CoachMatcher.match(c.tree, strings: c.strings)
    let d = CoachPlanner.decide(scene, chosenOn: c.chosenOn, chosenOf: c.chosenOf, chosenWhenOpened: c.chosenWhenOpened,
                                pickedInChooser: c.picked)
    var ok = scene.page == c.page && d.step == c.step && d.situation == c.situation
    if let want = c.ringAround {
        ok = ok && d.kind == c.kind && (d.target.map { $0.insetBy(dx: -2, dy: -2).contains(CGPoint(x: want.midX, y: want.midY))
                                                      && abs($0.width - want.width) < 2 && abs($0.height - want.height) < 2 } ?? false)
    } else {
        ok = ok && d.target == nil
    }
    check(ok, "\(c.name) → \(scene.page) / \(d.step.name) ring \(fmt(d.target))"
          + (ok ? "" : "   [want \(c.page) / \(c.step.name) / \(c.situation) ring \(fmt(c.ringAround)) \(c.kind)]"))
}

// Every captured target is in the ids (fixtures carry no ids: none expected)
check(CoachMatcher.match(all[1].tree, strings: .english).ids.isEmpty, "fixture trees carry no capture ids")

// A captured tree round-trips through the dump's JSON
do {
    let tree = all.last!.tree
    let data = try JSONEncoder().encode(tree)
    let back = try JSONDecoder().decode(AXNodeSnapshot.self, from: data)
    check(back == tree, "AX dump JSON round-trips (\(data.count) bytes)")
    var text = ""
    tree.dumpText(into: &text)
    check(text.contains("AXSheet") && text.contains("title=\"Fertig\""), "AX dump text lists roles and titles")
} catch {
    check(false, "AX dump JSON round-trip: \(error)")
}

// Ids: a live capture's ids name the elements behind each target
do {
    var n = 0
    func number(_ t: inout AXNodeSnapshot) { t.id = n; n += 1; for i in t.children.indices { number(&t.children[i]) } }
    var tree = all.first { $0.name.hasPrefix("26 button+label: scrolled to Other") }!.tree
    number(&tree)
    let s = CoachMatcher.match(tree, strings: .english)
    check(s.tile != nil && s.ids.count >= 4, "a numbered capture reports the ids behind its targets (\(s.ids.count))")
}

// MARK: Labels

check(CoachStrings.norm("Screen Saver…") == "screen saver", "norm drops the ellipsis")
check(CoachStrings.norm("  Bildschirmschoner\u{00A0}… ") == "bildschirmschoner", "norm: NBSP + ellipsis")
check(CoachStrings.norm("Options...") == "options", "norm: three dots")
let avail: Set<String> = ["en", "en_CA", "de", "zh_CN", "zh_TW", "zh_HK", "pt_BR", "pt_PT", "es", "es_419", "fr", "fr_CA"]
check(CoachStrings.languageKey(for: ["en-CA"], available: avail) == "en_CA", "language: en-CA")
check(CoachStrings.languageKey(for: ["en-US"], available: avail) == "en", "language: en-US → en")
check(CoachStrings.languageKey(for: ["de-DE"], available: avail) == "de", "language: de-DE → de")
check(CoachStrings.languageKey(for: ["zh-Hans-CN"], available: avail) == "zh_CN", "language: zh-Hans-CN")
check(CoachStrings.languageKey(for: ["zh-Hant-HK"], available: avail) == "zh_HK", "language: zh-Hant-HK")
check(CoachStrings.languageKey(for: ["zh-Hant"], available: avail) == "zh_TW", "language: zh-Hant")
check(CoachStrings.languageKey(for: ["pt"], available: avail) == "pt_PT", "language: pt → pt_PT")
check(CoachStrings.languageKey(for: ["es-MX"], available: avail) == "es_419", "language: es-MX → es_419")
check(CoachStrings.languageKey(for: ["tlh", "fr-CA"], available: avail) == "fr_CA", "language: first known one")
check(CoachStrings.languageKey(for: ["tlh"], available: avail) == nil, "language: unknown → English only")

let ext = "/System/Library/ExtensionKit/Extensions/Wallpaper.appex/Contents/Resources/Localizable.loctable"
if FileManager.default.fileExists(atPath: ext) {
    let de = CoachStrings.system(languages: ["de-DE"])
    check(de.other.contains("andere") && de.other.contains("other"), "system labels (de): Other = \(de.other.sorted())")
    check(de.done.count == 2 && de.done.contains("done"), "system labels (de): Done = \(de.done.sorted())")
    check(de.screenSaverButton.count == 2, "system labels (de): Screen Saver… = \(de.screenSaverButton.sorted())")
    let en = CoachStrings.system(languages: ["en-US"])
    check(en == CoachStrings.english || en.screenSaverButton == ["screen saver"], "system labels (en) = English")
    let ja = CoachStrings.system(languages: ["ja-JP"])
    check(ja.other.count == 2, "system labels (ja): Other = \(ja.other.sorted())")
} else {
    print("skip system labels: \(ext) not on this macOS")
}

// MARK: Geometry

let mainH: CGFloat = 982
let ax = CGRect(x: 100, y: 50, width: 200, height: 30)
check(CoachGeometry.flip(CoachGeometry.flip(ax, mainHeight: mainH), mainHeight: mainH) == ax, "AX ↔ Cocoa flip is its own inverse")
check(CoachGeometry.flip(ax, mainHeight: mainH) == CGRect(x: 100, y: 902, width: 200, height: 30), "AX y-down → Cocoa y-up")
// A display above the main one has negative AX y; below, y beyond the main height
let above = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
check(CoachGeometry.flip(above, mainHeight: mainH) == CGRect(x: 0, y: mainH, width: 1920, height: 1080), "a display above the main one")

let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
let size = CGSize(width: 220, height: 44)
let mid = CoachGeometry.callout(ring: CGRect(x: 600, y: 300, width: 120, height: 30), size: size, bounds: screen)
check(mid.side == .below && mid.frame.minY >= 330 && !mid.frame.intersects(CGRect(x: 600, y: 300, width: 120, height: 30)),
      "callout below the ring, clear of it (\(fmt(mid.frame)))")
let low = CoachGeometry.callout(ring: CGRect(x: 600, y: 940, width: 120, height: 30), size: size, bounds: screen)
check(low.side == .above && low.frame.maxY <= 940, "near the bottom: callout above (\(fmt(low.frame)))")
let edge = CoachGeometry.callout(ring: CGRect(x: 1450, y: 300, width: 50, height: 30), size: size, bounds: screen)
check(edge.frame.maxX <= screen.maxX - 8 && edge.frame.minX >= 8, "clamped inside the screen (\(fmt(edge.frame)))")
let huge = CoachGeometry.callout(ring: screen.insetBy(dx: 10, dy: 10), size: size, bounds: screen)
check(screen.contains(huge.frame), "a ring as big as the screen keeps the callout on screen (\(fmt(huge.frame)))")
let second = CGRect(x: 1512, y: -200, width: 1920, height: 1080)
let onSecond = CoachGeometry.callout(ring: CGRect(x: 2000, y: 100, width: 100, height: 30), size: size, bounds: second)
check(second.contains(onSecond.frame), "callout on a second display stays on it (\(fmt(onSecond.frame)))")

check(CoachGeometry.coveredFraction(CGRect(x: 0, y: 0, width: 100, height: 100), by: [CGRect(x: 50, y: 0, width: 100, height: 100)]) == 0.5,
      "occlusion: half covered")
check(CoachGeometry.coveredFraction(CGRect(x: 0, y: 0, width: 100, height: 100), by: []) == 0, "occlusion: nothing above")

print("")
print(failures == 0 ? "setup coach check: PASS (\(all.count) fixtures)" : "setup coach check: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
