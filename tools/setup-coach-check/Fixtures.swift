//  Fixtures.swift — System Settings accessibility trees for tools/setup-coach-check, built the
//  way the coach captures them (App/SetupCoach.swift: AXApplication › AXWindow › …).
//
//  These are INFERRED, not recorded: DotStudio's agents may not open System Settings on the
//  owner's Mac. What they're built from:
//    • the labels: System Settings' own string tables (Wallpaper.appex Localizable.loctable:
//      SCREEN_SAVER_BUTTON_TITLE "Screen Saver…", DONE, SHOW_AS_WALLPAPER;
//      WallpaperLegacyExtension.appex OTHER "Other"; macOS 27.2);
//    • AppKit/SwiftUI's usual AX shapes: a sidebar AXOutline › AXRow › AXCell › AXStaticText
//      (the text in AXValue), buttons with AXTitle, SwiftUI image buttons with AXDescription,
//      lazy grids that only create the tiles near the visible area, sheets as AXSheet.
//  Each OS layout is drawn in more than one plausible shape (tile = button + label, image +
//  label in a group, cell around a label, radio button; sheet as AXSheet or as the Wallpaper
//  extension's own dialog window) so the matcher isn't tuned to one guess. When the owner
//  sends a DOTSTUDIO_AX_DUMP capture (…json), add it under fixtures/ — run.sh checks every
//  .json there too.

import Foundation
import CoreGraphics

typealias N = AXNodeSnapshot

func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }

/// The Settings window: x 200…915, y 100…740 (title bar 52 pt).
let windowFrame = R(200, 100, 715, 640)
let sidebarFrame = R(200, 152, 215, 588)
let contentFrame = R(415, 152, 500, 588)

enum OS: String { case sonoma = "14", sequoia = "15", tahoe = "26", next = "27" }

func sidebar(_ os: OS, wallpaper: String = "Wallpaper", screenSaver: String = "Screen Saver",
             selected: String) -> N {
    var names = ["Wi-Fi", "Bluetooth", "Network", "Battery", "General", "Accessibility", "Appearance",
                 "Control Center", "Desktop & Dock", "Displays"]
    if os == .sonoma || os == .sequoia { names.append(screenSaver) }
    names += [wallpaper, "Notifications", "Sound", "Focus", "Lock Screen", "Privacy & Security"]
    let rows = names.enumerated().map { i, name -> N in
        let y = 160 + CGFloat(i) * 28
        return N("AXRow", subrole: "AXOutlineRow", frame: R(200, y, 215, 28), selected: name == selected,
                 children: [N("AXCell", frame: R(210, y, 195, 28),
                              children: [N("AXImage", label: name, frame: R(214, y + 4, 20, 20)),
                                         N("AXStaticText", value: name, frame: R(242, y + 6, 150, 16))])])
    }
    return N("AXGroup", frame: sidebarFrame, children: [
        N("AXTextField", subrole: "AXSearchField", label: "Search", frame: R(210, 110, 195, 28)),
        N("AXScrollArea", frame: sidebarFrame, children: [
            N("AXOutline", label: "Sidebar", frame: R(200, 152, 215, CGFloat(rows.count) * 28 + 16), children: rows)
        ])
    ])
}

func window(title: String, _ os: OS, selected: String, content: [N], extra: [N] = [],
            wallpaperLabel: String = "Wallpaper", focused: Bool = true) -> N {
    N("AXWindow", subrole: "AXStandardWindow", title: title, frame: windowFrame, focused: focused, children: [
        N("AXGroup", frame: windowFrame, children: [
            N("AXSplitGroup", frame: windowFrame, children: [
                sidebar(os, wallpaper: wallpaperLabel, selected: selected),
                N("AXGroup", frame: contentFrame, children: content),
            ])
        ]),
        N("AXButton", subrole: "AXCloseButton", frame: R(210, 118, 14, 16)),
        N("AXToolbar", frame: R(415, 100, 500, 52), children: [
            N("AXButton", label: "Back", frame: R(425, 112, 28, 28)),
            N("AXStaticText", value: title, frame: R(470, 116, 200, 20)),
        ]),
    ] + extra)
}

func app(_ windows: [N]) -> N { N("AXApplication", title: "System Settings", children: windows) }

// MARK: Pages

/// The Wallpaper page; the "Screen Saver…" button at y = `buttonY` (beyond 740 = scrolled out).
func wallpaperPage(_ os: OS, buttonY: CGFloat = 690, title: String = "Wallpaper", button: String = "Screen Saver\u{2026}") -> N {
    N("AXScrollArea", frame: contentFrame, children: [
        N("AXGroup", frame: R(415, 152, 500, max(620, buttonY - 152 + 60)), children: [
            N("AXImage", label: "Wallpaper preview", frame: R(440, 170, 200, 120)),
            N("AXStaticText", value: "Sequoia Sunrise", frame: R(660, 180, 220, 18)),
            N("AXPopUpButton", value: "Fill Screen", frame: R(660, 210, 150, 22)),
            N("AXCheckBox", title: "Show on all Spaces", value: "1", frame: R(660, 240, 200, 20)),
            N("AXStaticText", value: "Dynamic Wallpapers", frame: R(440, 320, 200, 18)),
            N("AXGroup", frame: R(440, 345, 450, 300), children: (0..<6).map { i in
                N("AXButton", label: "Wallpaper \(i + 1)", frame: R(440 + CGFloat(i % 3) * 150, 345 + CGFloat(i / 3) * 110, 140, 100))
            }),
            N("AXButton", title: button, frame: R(790, buttonY, 110, 24)),
        ])
    ])
}

enum TileStyle { case buttonAndLabel, imageAndLabel, cellAroundLabel, radio }

/// The screen-saver tile list. `scroll` = how far it's scrolled; `lazy` = only tiles near the
/// visible area exist (as SwiftUI's lazy grids do).
func tiles(clip: CGRect, style: TileStyle, scroll: CGFloat = 0, lazy: Bool = false,
           selected: String? = nil, other: String = "Other", extraSections: Int = 0) -> N {
    var sections: [(String, [String])] = [("macOS", ["Drift", "Hello", "Macintosh", "Monterey", "Sonoma", "Ventura"])]
    let aerials = ["Landscape", "Cityscape", "Underwater", "Earth"]
    for (i, s) in aerials.enumerated() where i < 2 + extraSections {
        sections.append((s, (1...8).map { "\(s) \($0)" }))
    }
    sections.append((other, ["Album Artwork", "Arabesque", "Computer Name", "DotStudio", "Flurry", "Shell", "Word of the Day"]))

    var kids: [N] = []
    var y = clip.minY + 12 - scroll
    let cols = columns(clip), tileW: CGFloat = 120, tileH: CGFloat = 70, labelH: CGFloat = 16, rowH: CGFloat = 110
    func near(_ yy: CGFloat) -> Bool { !lazy || (yy > clip.minY - 250 && yy < clip.maxY + 250) }
    for (name, items) in sections {
        if near(y) { kids.append(N("AXStaticText", subrole: nil, value: name, frame: R(clip.minX + 16, y, 200, 20))) }
        y += 30
        for (i, item) in items.enumerated() {
            let x = clip.minX + 16 + CGFloat(i % cols) * (tileW + 18)
            let ty = y + CGFloat(i / cols) * rowH
            guard near(ty) else { continue }
            let sel = item == selected
            let tile = R(x, ty, tileW, tileH), label = R(x, ty + tileH + 6, tileW, labelH)
            switch style {
            case .buttonAndLabel:
                kids.append(N("AXButton", label: item, frame: tile, selected: sel))
                kids.append(N("AXStaticText", value: item, frame: label))
            case .imageAndLabel:
                kids.append(N("AXGroup", frame: tile.union(label), selected: sel, children: [
                    N("AXImage", frame: tile), N("AXStaticText", value: item, frame: label)]))
            case .cellAroundLabel:
                kids.append(N("AXCell", frame: tile.union(label), selected: sel, children: [
                    N("AXImage", label: "Preview", frame: tile), N("AXStaticText", value: item, frame: label)]))
            case .radio:
                kids.append(N("AXRadioButton", title: item, value: sel ? "1" : "0", frame: tile.union(label)))
            }
        }
        y += CGFloat((items.count + cols - 1) / cols) * rowH + 10
    }
    let content = R(clip.minX, clip.minY - scroll, clip.width, y + scroll - clip.minY)
    return N("AXScrollArea", frame: clip, children: [
        N("AXGroup", frame: content, children: kids),
        N("AXScrollBar", subrole: nil, value: "0", frame: R(clip.maxX - 12, clip.minY, 12, clip.height)),
    ])
}

/// The macOS 26/27 sheet: tiles, Show as wallpaper, Done.
let sheetFrame = R(250, 130, 615, 580)
let sheetList = R(250, 180, 615, 470)
func sheet(style: TileStyle, scroll: CGFloat = 0, lazy: Bool = false, selected: String? = nil,
           other: String = "Other", done: String = "Done", showAs: String = "Show as wallpaper") -> N {
    N("AXSheet", frame: sheetFrame, children: [
        N("AXStaticText", value: "Screen Saver", frame: R(270, 145, 200, 20)),
        tiles(clip: sheetList, style: style, scroll: scroll, lazy: lazy, selected: selected, other: other),
        N("AXCheckBox", title: showAs, value: "1", frame: R(270, 665, 200, 20)),
        N("AXButton", title: done, frame: R(790, 670, 60, 24)),
    ])
}

/// macOS 14/15: the Screen Saver page's content (tiles in the page; no Done).
func screenSaverPage(style: TileStyle, scroll: CGFloat = 0, selected: String? = nil) -> N {
    N("AXGroup", frame: contentFrame, children: [
        N("AXCheckBox", title: "Show as wallpaper", value: "1", frame: R(430, 160, 200, 20)),
        N("AXButton", title: "Preview", frame: R(830, 160, 70, 22)),
        tiles(clip: R(415, 190, 500, 550), style: style, scroll: scroll, selected: selected),
    ])
}

// MARK: The cases

struct Case {
    var name: String
    var tree: N
    var strings = CoachStrings.english
    var chosenOn: Int? = 0
    var chosenOf: Int? = 1
    var chosenWhenOpened: Int? = nil
    /// Expected.
    var page: CoachScene.Page
    var step: CoachStep
    var situation: CoachDecision.Situation = .normal
    /// Where the ring should be (contains the centre of this rect); nil = no ring.
    var ringAround: CGRect?
    var kind: CoachTargetKind = .control
}

/// A tile's frame as `tiles(…)` lays it out (name in the Other section), for expectations.
func tileFrame(clip: CGRect, scroll: CGFloat, name: String = "DotStudio", extraSections: Int = 0) -> CGRect {
    // macOS (6) + 2 aerial sections (8 each) + Other; DotStudio is Other's 4th item.
    var y = clip.minY + 12 - scroll
    let counts = [6] + Array(repeating: 8, count: 2 + extraSections)
    let cols = columns(clip)
    for c in counts { y += 30 + CGFloat((c + cols - 1) / cols) * 110 + 10 }
    y += 30
    let i = ["Album Artwork", "Arabesque", "Computer Name", "DotStudio", "Flurry", "Shell", "Word of the Day"].firstIndex(of: name)!
    return R(clip.minX + 16 + CGFloat(i % cols) * 138, y + CGFloat(i / cols) * 110, 120, 92)
}

/// Tiles per row in a list `clip` wide (120 pt tiles, 18 pt apart, 16 pt margins).
func columns(_ clip: CGRect) -> Int { max(1, Int((clip.width - 32 + 18) / 138)) }

func german() -> CoachStrings {
    var s = CoachStrings.english
    s.add(wallpaper: "Hintergrundbild", button: "Bildschirmschoner\u{00A0}…", page: "Bildschirmschoner",
          other: "Andere", done: "Fertig", showAsWallpaper: "Als Hintergrundbild anzeigen")
    return s
}

func cases() -> [Case] {
    var c: [Case] = []
    let wallpaperButton = R(790, 690, 110, 24)

    // Nothing open
    c.append(Case(name: "no windows", tree: app([]), page: .none, step: .openWallpaper, situation: .settingsClosed))

    // Wallpaper page, every OS
    for os in [OS.sonoma, .sequoia, .tahoe, .next] {
        c.append(Case(name: "\(os.rawValue): Wallpaper page",
                      tree: app([window(title: "Wallpaper", os, selected: "Wallpaper", content: [wallpaperPage(os)])]),
                      page: .wallpaper, step: .openChooser, ringAround: wallpaperButton))
    }
    // The button below the fold: ring the page with "scroll down"
    c.append(Case(name: "26: Screen Saver… scrolled out of view",
                  tree: app([window(title: "Wallpaper", .tahoe, selected: "Wallpaper", content: [wallpaperPage(.tahoe, buttonY: 900)])]),
                  page: .wallpaper, step: .openChooser, ringAround: contentFrame, kind: .area))
    // Chosen on one of two displays: back to the button for the other display
    c.append(Case(name: "26: chosen on 1 of 2 displays",
                  tree: app([window(title: "Wallpaper", .tahoe, selected: "Wallpaper", content: [wallpaperPage(.tahoe)])]),
                  chosenOn: 1, chosenOf: 2, page: .wallpaper, step: .openChooser, situation: .otherDisplay,
                  ringAround: wallpaperButton))
    // Chosen everywhere, sheet closed: done
    c.append(Case(name: "26: chosen everywhere, sheet closed",
                  tree: app([window(title: "Wallpaper", .tahoe, selected: "Wallpaper", content: [wallpaperPage(.tahoe)])]),
                  chosenOn: 2, chosenOf: 2, page: .wallpaper, step: .finished))

    // Elsewhere
    let wallpaperRow = R(200, 160 + 10 * 28, 215, 28)
    c.append(Case(name: "26: Battery page (wandered off)",
                  tree: app([window(title: "Battery", .tahoe, selected: "Battery",
                                    content: [N("AXStaticText", value: "Battery Health", frame: R(440, 200, 200, 20))])]),
                  page: .elsewhere, step: .openWallpaper, situation: .elsewhere, ringAround: wallpaperRow))
    // Privacy & Security › Accessibility lists DotStudio (and an "Other" label): not the chooser
    c.append(Case(name: "26: Accessibility privacy list mentions DotStudio",
                  tree: app([window(title: "Accessibility", .tahoe, selected: "Privacy & Security", content: [
                      N("AXScrollArea", frame: contentFrame, children: [
                          N("AXTable", frame: R(430, 200, 470, 200), children: [
                              N("AXRow", frame: R(430, 200, 470, 30), children: [
                                  N("AXCell", frame: R(430, 200, 470, 30), children: [
                                      N("AXStaticText", value: "DotStudio", frame: R(470, 206, 200, 18)),
                                      N("AXCheckBox", label: "DotStudio", value: "1", frame: R(860, 206, 30, 18))])])]),
                          N("AXStaticText", value: "Other", frame: R(430, 420, 100, 18))])])]),
                  page: .elsewhere, step: .openWallpaper, situation: .elsewhere, ringAround: wallpaperRow))
    // 14/15 sidebar has a Screen Saver row too: the Wallpaper row moves down one
    c.append(Case(name: "14: Battery page (wandered off)",
                  tree: app([window(title: "Battery", .sonoma, selected: "Battery", content: [])]),
                  page: .elsewhere, step: .openWallpaper, situation: .elsewhere,
                  ringAround: R(200, 160 + 11 * 28, 215, 28)))

    // macOS 26/27 sheet, each tile shape
    let styles: [(TileStyle, String)] = [(.buttonAndLabel, "button+label"), (.imageAndLabel, "image+label"),
                                         (.cellAroundLabel, "cell"), (.radio, "radio")]
    let inView = tileFrame(clip: sheetList, scroll: 460)
    for (style, tag) in styles {
        for os in [OS.tahoe, .next] {
            let main = window(title: "Wallpaper", os, selected: "Wallpaper", content: [wallpaperPage(os)])
            // Sheet just opened: the list starts at the top — DotStudio is far below
            var m = main; m.children.append(sheet(style: style))
            c.append(Case(name: "\(os.rawValue) \(tag): sheet open, DotStudio below", tree: app([m]),
                          chosenWhenOpened: 0, page: .chooser, step: .scrollToTile, ringAround: sheetList, kind: .area))
            // Scrolled to Other: ring the tile
            var m2 = main; m2.children.append(sheet(style: style, scroll: 460))
            c.append(Case(name: "\(os.rawValue) \(tag): scrolled to Other", tree: app([m2]),
                          chosenWhenOpened: 0, page: .chooser, step: .chooseTile, ringAround: inView))
            // Picked (AX selection, or the store says so): ring Done
            var m3 = main; m3.children.append(sheet(style: style, scroll: 460, selected: "DotStudio"))
            c.append(Case(name: "\(os.rawValue) \(tag): DotStudio picked", tree: app([m3]),
                          chosenWhenOpened: 0, page: .chooser, step: .clickDone, ringAround: R(790, 670, 60, 24)))
        }
    }
    // The store says chosen (no AX selection): Done
    do {
        var m = window(title: "Wallpaper", .tahoe, selected: "Wallpaper", content: [wallpaperPage(.tahoe)])
        m.children.append(sheet(style: .imageAndLabel, scroll: 460))
        c.append(Case(name: "26: store rose to 1 while the sheet is open", tree: app([m]), chosenOn: 1, chosenOf: 1,
                      chosenWhenOpened: 0, page: .chooser, step: .clickDone, ringAround: R(790, 670, 60, 24)))
        // Chosen on another display before (1 of 2), sheet for the second display: not picked yet
        c.append(Case(name: "26: second display's sheet, not picked yet", tree: app([m]), chosenOn: 1, chosenOf: 2,
                      chosenWhenOpened: 1, page: .chooser, step: .chooseTile, ringAround: inView))
    }
    // Lazy grid: the Other section isn't created yet
    do {
        var m = window(title: "Wallpaper", .next, selected: "Wallpaper", content: [wallpaperPage(.next)])
        m.children.append(sheet(style: .imageAndLabel, lazy: true))
        c.append(Case(name: "27 lazy: Other not created yet", tree: app([m]), chosenWhenOpened: 0,
                      page: .chooser, step: .scrollToTile, ringAround: sheetList, kind: .area))
        var m2 = window(title: "Wallpaper", .next, selected: "Wallpaper", content: [wallpaperPage(.next)])
        m2.children.append(sheet(style: .imageAndLabel, scroll: 460, lazy: true))
        c.append(Case(name: "27 lazy: scrolled to Other", tree: app([m2]), chosenWhenOpened: 0,
                      page: .chooser, step: .chooseTile, ringAround: inView))
        // Half-way: Other header visible, DotStudio's row just under the edge
        var m3 = window(title: "Wallpaper", .next, selected: "Wallpaper", content: [wallpaperPage(.next)])
        m3.children.append(sheet(style: .imageAndLabel, scroll: 360, lazy: true))
        c.append(Case(name: "27 lazy: Other visible, tile under the edge", tree: app([m3]), chosenWhenOpened: 0,
                      page: .chooser, step: .scrollToTile, ringAround: sheetList, kind: .area))
    }
    // The sheet as the Wallpaper extension's own dialog window (not an AXSheet)
    do {
        let main = window(title: "Wallpaper", .next, selected: "Wallpaper", content: [wallpaperPage(.next)], focused: false)
        var dialog = sheet(style: .buttonAndLabel, scroll: 460)
        dialog.role = "AXWindow"; dialog.subrole = "AXDialog"; dialog.title = ""; dialog.focused = true
        c.append(Case(name: "27: chooser as a dialog window", tree: app([main, dialog]), chosenWhenOpened: 0,
                      page: .chooser, step: .chooseTile, ringAround: inView))
    }

    // macOS 14/15: the Screen Saver page (no sheet, no Done)
    let pageClip = R(415, 190, 500, 550)
    for (os, title) in [(OS.sonoma, "Screen Saver"), (.sequoia, "Screen Saver")] {
        c.append(Case(name: "\(os.rawValue): Screen Saver page, top",
                      tree: app([window(title: title, os, selected: "Screen Saver", content: [screenSaverPage(style: .imageAndLabel)])]),
                      chosenWhenOpened: 0, page: .chooser, step: .scrollToTile, ringAround: pageClip, kind: .area))
        let t = tileFrame(clip: pageClip, scroll: 800)
        c.append(Case(name: "\(os.rawValue): Screen Saver page, scrolled to Other",
                      tree: app([window(title: title, os, selected: "Screen Saver", content: [screenSaverPage(style: .imageAndLabel, scroll: 800)])]),
                      chosenWhenOpened: 0, page: .chooser, step: .chooseTile, ringAround: t))
        c.append(Case(name: "\(os.rawValue): Screen Saver page, DotStudio picked → done (no Done button)",
                      tree: app([window(title: title, os, selected: "Screen Saver",
                                        content: [screenSaverPage(style: .imageAndLabel, scroll: 800, selected: "DotStudio")])]),
                      chosenWhenOpened: 0, page: .chooser, step: .finished))
    }
    // 14 with an untitled window (title missing): recognised by its marks
    c.append(Case(name: "14: Screen Saver page, no window title",
                  tree: app([window(title: "", .sonoma, selected: "Screen Saver", content: [screenSaverPage(style: .radio, scroll: 800)])]),
                  chosenWhenOpened: 0, page: .chooser, step: .chooseTile, ringAround: tileFrame(clip: pageClip, scroll: 800)))

    // German
    do {
        let de = german()
        var m = window(title: "Hintergrundbild", .next, selected: "Hintergrundbild",
                       content: [wallpaperPage(.next, title: "Hintergrundbild", button: "Bildschirmschoner\u{00A0}…")],
                       wallpaperLabel: "Hintergrundbild")
        c.append(Case(name: "27 de: Wallpaper page", tree: app([m]), strings: de, page: .wallpaper, step: .openChooser,
                      ringAround: wallpaperButton))
        m.children.append(sheet(style: .buttonAndLabel, scroll: 460, other: "Andere", done: "Fertig",
                                showAs: "Als Hintergrundbild anzeigen"))
        c.append(Case(name: "27 de: scrolled to Andere", tree: app([m]), strings: de, chosenWhenOpened: 0,
                      page: .chooser, step: .chooseTile, ringAround: inView))
        // The same German screens with only English labels: no ring on the wrong control.
        // DotStudio is still found by name (not localized); the button isn't.
        var w = window(title: "Hintergrundbild", .next, selected: "Hintergrundbild",
                       content: [wallpaperPage(.next, title: "Hintergrundbild", button: "Bildschirmschoner\u{00A0}…")],
                       wallpaperLabel: "Hintergrundbild")
        c.append(Case(name: "27 de with English labels: no ring", tree: app([w]), page: .elsewhere, step: .openWallpaper,
                      situation: .elsewhere, ringAround: nil))
        w.children.append(sheet(style: .buttonAndLabel, scroll: 460, other: "Andere", done: "Fertig",
                                showAs: "Als Hintergrundbild anzeigen"))
        c.append(Case(name: "27 de with English labels: tile still found by name", tree: app([w]), chosenWhenOpened: 0,
                      page: .chooser, step: .chooseTile, ringAround: inView))
    }
    return c
}
