//  SetupCoachMatch.swift — the pure half of the setup coach (SetupCoach.swift): what it finds
//  in a captured System Settings accessibility tree, which step the user is on, and where the
//  ring and its callout go. No AppKit, no Accessibility calls: tools/setup-coach-check compiles
//  this file on its own and runs it over fixture trees (and over a DOTSTUDIO_AX_DUMP capture).
//
//  Coordinates: everything here is in the Accessibility API's global space — points, origin at
//  the top-left of the main display (the one with the menu bar), y down. CGWindowList uses the
//  same space. SetupCoach converts to Cocoa (y up) only to place the overlay window.
//
//  What System Settings looks like (assumptions — see tools/setup-coach-check/Fixtures.swift):
//    macOS 26/27  Wallpaper page (window titled "Wallpaper") with a "Screen Saver…" button near
//                 the bottom of the page. It opens a sheet: a scroll area of screen-saver tiles
//                 in sections ("macOS", Aerial categories, "Other" = third-party .savers), "Show
//                 as wallpaper", and a "Done" button. The sheet shows up as an AXSheet in the
//                 Settings window, or — the page lives in the Wallpaper extension's own process —
//                 as a separate dialog window; both are handled.
//    macOS 14/15  Wallpaper page with a "Screen Saver…" button that switches to a separate
//                 Screen Saver page (window titled "Screen Saver"): the tiles sit in the page
//                 itself, "Other" section included, and there is no Done button.
//  Tiles are matched by their name ("DotStudio": the .saver's name, never localized), whether
//  the name is the tile's own title/description or a text label under an image. Section and
//  button labels come from CoachStrings: English plus the user's language, read from System
//  Settings' own string tables at runtime — no hard failure in other languages: when nothing
//  matches, the coach falls back to the illustrated step.

import Foundation
import CoreGraphics

// MARK: - Captured tree

/// One accessibility element as captured (SetupCoach) or written in a fixture. Strings are
/// the element's own (AXTitle, AXDescription, AXValue when it's text or a number, AXHelp).
struct AXNodeSnapshot: Codable, Equatable {
    var role: String
    var subrole: String?
    var identifier: String?
    var title: String?
    /// AXDescription.
    var label: String?
    var value: String?
    var help: String?
    /// AX global frame (top-left origin), nil when the element has no position/size.
    var frame: CGRect?
    var selected: Bool?
    /// Windows: AXMain / AXFocused.
    var focused: Bool?
    /// The capture's id for this element (live captures only), so a target can be re-read
    /// quickly without a new full capture.
    var id: Int?
    var children: [AXNodeSnapshot]

    init(_ role: String, subrole: String? = nil, identifier: String? = nil, title: String? = nil,
         label: String? = nil, value: String? = nil, help: String? = nil, frame: CGRect? = nil,
         selected: Bool? = nil, focused: Bool? = nil, id: Int? = nil, children: [AXNodeSnapshot] = []) {
        self.role = role; self.subrole = subrole; self.identifier = identifier; self.title = title
        self.label = label; self.value = value; self.help = help; self.frame = frame
        self.selected = selected; self.focused = focused; self.id = id; self.children = children
    }

    /// The element's non-empty strings, title first.
    var texts: [String] {
        [title, label, value].compactMap { s in
            guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return s
        }
    }

    /// Every node, depth first, with its ancestors (nearest last) and its index path from
    /// this node (child indices; [] = this node).
    func walk(_ visit: (AXNodeSnapshot, [AXNodeSnapshot], [Int]) -> Void) {
        var stack: [AXNodeSnapshot] = []
        var path: [Int] = []
        func go(_ n: AXNodeSnapshot) {
            visit(n, stack, path)
            stack.append(n)
            for (i, c) in n.children.enumerated() {
                path.append(i); go(c); path.removeLast()
            }
            stack.removeLast()
        }
        go(self)
    }

    /// A readable dump (DOTSTUDIO_AX_DUMP): one element per line, indented by depth.
    func dumpText(depth: Int = 0, into out: inout String) {
        var line = String(repeating: "  ", count: depth) + role
        if let subrole { line += "/\(subrole)" }
        func q(_ k: String, _ v: String?) {
            guard let v, !v.isEmpty else { return }
            let short = v.count > 80 ? String(v.prefix(80)) + "…" : v
            line += " \(k)=\"\(short.replacingOccurrences(of: "\n", with: " "))\""
        }
        q("id", identifier); q("title", title); q("desc", label); q("value", value); q("help", help)
        if let f = frame { line += String(format: " frame=(%.0f,%.0f %.0fx%.0f)", f.minX, f.minY, f.width, f.height) }
        if selected == true { line += " selected" }
        if focused == true { line += " main" }
        out += line + "\n"
        for c in children { c.dumpText(depth: depth + 1, into: &out) }
    }
}

// MARK: - Labels

/// The labels the coach looks for, normalized (CoachStrings.norm). English always; the user's
/// language added from System Settings' own string tables when they can be read.
struct CoachStrings: Equatable {
    /// The sidebar item and the Wallpaper page's window title.
    var wallpaper: Set<String>
    /// The Wallpaper page's "Screen Saver…" button (normalized without the ellipsis).
    var screenSaverButton: Set<String>
    /// macOS 14/15: the Screen Saver page's window title (and its sidebar item).
    var screenSaverPage: Set<String>
    /// The third-party section in the screen-saver list.
    var other: Set<String>
    var done: Set<String>
    /// "Show as wallpaper": only in the screen-saver chooser (a marker that it's open).
    var showAsWallpaper: Set<String>
    /// The tile's name: the .saver's bundle name, the same in every language.
    var saverName = "DotStudio"

    static let english = CoachStrings(
        wallpaper: ["wallpaper"],
        screenSaverButton: ["screen saver"],
        screenSaverPage: ["screen saver"],
        other: ["other"],
        done: ["done"],
        showAsWallpaper: ["show as wallpaper"])

    /// Lowercased, NBSPs as spaces, whitespace collapsed, a trailing "…" / "..." dropped.
    static func norm(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix("…") || t.hasSuffix("...") {
            t = String(t.dropLast(t.hasSuffix("…") ? 1 : 3)).trimmingCharacters(in: .whitespaces)
        }
        return t.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .joined(separator: " ")
            .lowercased()
    }

    func isSaverName(_ s: String) -> Bool { Self.norm(s) == Self.norm(saverName) }

    /// Adds one language's labels.
    mutating func add(wallpaper w: String?, button: String?, page: String?, other o: String?, done d: String?,
                      showAsWallpaper s: String?) {
        func put(_ v: String?, _ set: inout Set<String>) {
            guard let v else { return }
            let n = Self.norm(v.replacingOccurrences(of: "%@", with: ""))
            if !n.isEmpty { set.insert(n) }
        }
        put(w, &wallpaper); put(button, &screenSaverButton); put(page, &screenSaverPage)
        put(o, &other); put(d, &done); put(s, &showAsWallpaper)
    }

    /// English plus the first of `languages` System Settings has strings for. Reads the
    /// Wallpaper settings extension's `.loctable`s (plists keyed by language); a table that
    /// isn't there (another macOS version) is skipped.
    static func system(languages: [String] = Locale.preferredLanguages,
                       extensions: String = "/System/Library/ExtensionKit/Extensions") -> CoachStrings {
        var s = english
        func table(_ appex: String, _ name: String) -> [String: Any] {
            let url = URL(fileURLWithPath: extensions).appendingPathComponent("\(appex).appex/Contents/Resources/\(name).loctable")
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { return [:] }
            return plist
        }
        let wallpaper = table("Wallpaper", "Localizable")
        let info = table("Wallpaper", "InfoPlist")
        let legacy = table("WallpaperLegacyExtension", "Localizable")
        let tables = [wallpaper, info, legacy]
        guard let lang = languageKey(for: languages, available: Set(tables.flatMap(\.keys))) else { return s }
        func get(_ t: [String: Any], _ key: String) -> String? { (t[lang] as? [String: Any])?[key] as? String }
        s.add(wallpaper: get(info, "CFBundleDisplayName") ?? get(wallpaper, "WALLPAPER"),
              button: get(wallpaper, "SCREEN_SAVER_BUTTON_TITLE"),
              page: get(wallpaper, "SCREEN_SAVER"),
              other: get(legacy, "OTHER"),
              done: get(wallpaper, "DONE"),
              showAsWallpaper: get(wallpaper, "SHOW_AS_WALLPAPER"))
        if lang.hasPrefix("en") == false, let w = get(wallpaper, "WALLPAPER") { s.wallpaper.insert(norm(w)) }
        return s
    }

    /// The loctable key for the user's language: "en-CA" → en_CA, else en; "zh-Hans-CN" →
    /// zh_CN; "zh-Hant-HK" → zh_HK, else zh_TW; "pt" → pt_PT; "es-MX" → es_419.
    static func languageKey(for languages: [String], available: Set<String>) -> String? {
        for raw in languages {
            let parts = raw.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
            guard let lang = parts.first?.lowercased() else { continue }
            let region = parts.dropFirst().first { $0.count == 2 || $0.count == 3 && Int($0) != nil }?.uppercased()
            let script = parts.dropFirst().first { $0.count == 4 }
            var keys: [String] = []
            if lang == "zh" {
                if script == "Hant" || region == "TW" || region == "HK" || region == "MO" {
                    keys = region == "HK" || region == "MO" ? ["zh_HK", "zh_TW"] : ["zh_TW", "zh_HK"]
                } else { keys = ["zh_CN"] }
            } else {
                if let region { keys.append("\(lang)_\(region)") }
                if lang == "es", let region, region != "ES" { keys.append("es_419") }
                if lang == "pt" { keys.append(region == "BR" ? "pt_BR" : "pt_PT") }
                keys.append(lang)
            }
            if let k = keys.first(where: available.contains) { return k }
        }
        return nil
    }
}

// MARK: - What's on screen

/// What the matcher found in one capture. Frames are AX global; nil = not found or not in
/// view. `ids` name the captured elements each target came from (for quick re-reads).
struct CoachScene: Equatable {
    enum Page: Equatable {
        /// System Settings has no window.
        case none
        /// Some other settings page.
        case elsewhere
        /// The Wallpaper page (with its "Screen Saver…" button).
        case wallpaper
        /// The screen-saver chooser: the sheet (26+) or the Screen Saver page (14/15).
        case chooser
    }

    var page: Page = .none
    var window: CGRect?
    /// The sidebar's Wallpaper row, when it's in view.
    var wallpaperRow: CGRect?
    var screenSaverButton: CGRect?
    /// The button is on the page but scrolled out of view: this is the page's visible area.
    var pageScrollArea: CGRect?
    var chooser: CGRect?
    var chooserIsSheet = false
    /// The visible part of the chooser's tile list.
    var scrollArea: CGRect?
    var otherHeader: CGRect?
    /// The DotStudio tile (and its name), only when it's mostly in view.
    var tile: CGRect?
    /// The tile exists but is scrolled (mostly) out of view.
    var tileOutOfView = false
    var tileSelected = false
    var done: CGRect?
    /// Captured element ids behind each target (for quick frame re-reads).
    var ids: Set<Int> = []
}

enum CoachMatcher {
    static let clickableRoles: Set<String> = ["AXButton", "AXRadioButton", "AXCell", "AXCheckBox", "AXMenuButton", "AXPopUpButton"]
    static let textRoles: Set<String> = ["AXStaticText", "AXHeading", "AXTextField"]

    /// A node with its ancestors (nearest last) and its index path from the search root.
    struct Found {
        var node: AXNodeSnapshot
        var ancestors: [AXNodeSnapshot]
        var path: [Int]

        /// `self` lies inside `other` (both found from the same root).
        func isInside(_ other: Found) -> Bool {
            path.count > other.path.count && Array(path.prefix(other.path.count)) == other.path
        }
    }

    /// Every node in `root` (root included) passing `test`, in document order.
    static func find(in root: AXNodeSnapshot, _ test: (AXNodeSnapshot) -> Bool) -> [Found] {
        var out: [Found] = []
        root.walk { n, anc, path in if test(n) { out.append(Found(node: n, ancestors: anc, path: path)) } }
        return out
    }

    static func has(_ n: AXNodeSnapshot, in set: Set<String>) -> Bool {
        n.texts.contains { set.contains(CoachStrings.norm($0)) }
    }

    static func isClickable(_ n: AXNodeSnapshot) -> Bool {
        clickableRoles.contains(n.role) || n.role == "AXGroup" && n.subrole == "AXTile"
    }

    /// How much of `r` lies inside `clip` (0…1).
    static func visibleFraction(_ r: CGRect, in clip: CGRect?) -> CGFloat {
        guard r.width > 0, r.height > 0 else { return 0 }
        guard let clip else { return 1 }
        let i = r.intersection(clip)
        guard !i.isNull else { return 0 }
        return (i.width * i.height) / (r.width * r.height)
    }

    /// The tightest clip an element is drawn within: its window, intersected with each
    /// enclosing scroll area's (and sheet's) frame.
    static func clip(for f: Found, window: CGRect?) -> CGRect? {
        var c = window
        for a in f.ancestors where a.role == "AXScrollArea" || a.role == "AXSheet" {
            guard let af = a.frame else { continue }
            c = c.map { $0.intersection(af) } ?? af
            if c?.isNull == true { return .zero }
        }
        return c
    }

    // MARK: Match

    static func match(_ app: AXNodeSnapshot, strings: CoachStrings) -> CoachScene {
        var scene = CoachScene()
        let windows = app.children.filter { $0.role == "AXWindow" }
        guard !windows.isEmpty else { return scene }
        func isDialog(_ w: AXNodeSnapshot) -> Bool {
            ["AXDialog", "AXSystemDialog", "AXFloatingWindow"].contains(w.subrole ?? "")
        }
        // The main window: the focused standard one, else the first standard one.
        let mainIndex = windows.firstIndex { $0.focused == true && !isDialog($0) }
            ?? windows.firstIndex { $0.subrole == "AXStandardWindow" }
            ?? windows.firstIndex { !isDialog($0) }
            ?? 0
        let main = windows[mainIndex]
        scene.window = main.frame
        if let id = main.id { scene.ids.insert(id) }

        // The sidebar's Wallpaper row: a Wallpaper label inside an outline/list/table.
        scene.wallpaperRow = sidebarRow(in: main, strings: strings, scene: &scene)

        // The chooser: an AXSheet in any window, else another (dialog) window with Done.
        var chooser: AXNodeSnapshot?
        for w in windows {
            if let sheet = find(in: w, { $0.role == "AXSheet" }).first(where: {
                looksLikeChooser($0.node, strings: strings, requireDone: false)
            })?.node {
                chooser = sheet; scene.chooserIsSheet = true; break
            }
        }
        if chooser == nil {
            for (i, w) in windows.enumerated() where i != mainIndex {
                if looksLikeChooser(w, strings: strings, requireDone: true) {
                    chooser = w; scene.chooserIsSheet = true; break
                }
            }
        }
        // macOS 14/15: the Screen Saver page itself (titled so, or the chooser's own marks
        // without the Wallpaper page's button).
        let pageButtons = find(in: main) { $0.role == "AXButton" && has($0, in: strings.screenSaverButton) && $0.frame != nil }
        if chooser == nil && pageButtons.isEmpty {
            let titled = main.title.map { strings.screenSaverPage.contains(CoachStrings.norm($0)) } ?? false
            if titled || looksLikeChooserPage(main, strings: strings) {
                chooser = main; scene.chooserIsSheet = false
            }
        }

        if let chooser {
            scene.page = .chooser
            matchChooser(chooser, window: main.frame, strings: strings, scene: &scene)
            return scene
        }

        // The Wallpaper page: its "Screen Saver…" button (or the window's title).
        let titledWallpaper = main.title.map { strings.wallpaper.contains(CoachStrings.norm($0)) } ?? false
        if let b = pageButtons.first {
            scene.page = .wallpaper
            let clip = clip(for: b, window: main.frame)
            if visibleFraction(b.node.frame!, in: clip) >= 0.6 {
                scene.screenSaverButton = b.node.frame
                if let id = b.node.id { scene.ids.insert(id) }
            } else if let scroll = b.ancestors.last(where: { $0.role == "AXScrollArea" }), let sf = scroll.frame {
                let visible = main.frame.map { sf.intersection($0) } ?? sf
                if !visible.isNull { scene.pageScrollArea = visible }
                if let id = scroll.id { scene.ids.insert(id) }
                if let id = b.node.id { scene.ids.insert(id) }
            }
        } else if titledWallpaper {
            scene.page = .wallpaper
        } else {
            scene.page = .elsewhere
        }
        return scene
    }

    /// The chooser's marks inside a sheet or dialog: the Other section, the DotStudio tile or
    /// "Show as wallpaper"; a dialog window also needs a Done button.
    static func looksLikeChooser(_ root: AXNodeSnapshot, strings: CoachStrings, requireDone: Bool) -> Bool {
        let m = marks(root, strings: strings)
        if requireDone && !m.done { return false }
        return m.other || m.tile || m.showAsWallpaper
    }

    /// A whole page that is the chooser (macOS 14/15, when its title didn't match): "Show as
    /// wallpaper" with the Other section or the DotStudio tile. (DotStudio alone isn't
    /// enough — it's also listed in Privacy & Security, for one.)
    static func looksLikeChooserPage(_ root: AXNodeSnapshot, strings: CoachStrings) -> Bool {
        let m = marks(root, strings: strings)
        return m.showAsWallpaper && (m.other || m.tile)
    }

    private static func marks(_ root: AXNodeSnapshot, strings: CoachStrings)
        -> (other: Bool, tile: Bool, showAsWallpaper: Bool, done: Bool) {
        var other = false, tile = false, marker = false, done = false
        root.walk { n, _, _ in
            if (textRoles.contains(n.role) || n.role == "AXGroup") && has(n, in: strings.other) { other = true }
            if n.texts.contains(where: strings.isSaverName) { tile = true }
            if has(n, in: strings.showAsWallpaper) { marker = true }
            if n.role == "AXButton" && has(n, in: strings.done) { done = true }
        }
        return (other, tile, marker, done)
    }

    private static func sidebarRow(in window: AXNodeSnapshot, strings: CoachStrings, scene: inout CoachScene) -> CGRect? {
        let hits = find(in: window) { n in
            n.frame != nil && n.role != "AXWindow" && has(n, in: strings.wallpaper)
        }
        for h in hits {
            guard let listIndex = h.ancestors.lastIndex(where: { ["AXOutline", "AXList", "AXTable"].contains($0.role) })
            else { continue }
            // The row: the nearest AXRow/AXCell between the list and the label, else the label.
            let between = h.ancestors[(listIndex + 1)...]
            let row = between.last(where: { $0.role == "AXRow" }) ?? between.last(where: { $0.role == "AXCell" }) ?? h.node
            guard var f = row.frame else { continue }
            // Rows can be as wide as the outline's content; keep them inside the list's frame.
            if let lf = h.ancestors[listIndex].frame { f = f.intersection(lf) }
            guard !f.isNull, visibleFraction(f, in: clip(for: h, window: window.frame)) >= 0.6 else { return nil }
            if let id = row.id { scene.ids.insert(id) }
            return f
        }
        return nil
    }

    private static func area(_ r: CGRect?) -> CGFloat { r.map { $0.width * $0.height } ?? 0 }

    private static func matchChooser(_ chooser: AXNodeSnapshot, window: CGRect?, strings: CoachStrings,
                                     scene: inout CoachScene) {
        scene.chooser = chooser.frame
        if let id = chooser.id { scene.ids.insert(id) }
        let bounds = chooser.frame ?? window

        let others = find(in: chooser) { n in
            n.frame != nil && (textRoles.contains(n.role) || n.role == "AXGroup") && has(n, in: strings.other)
        }
        let tiles = tileCandidates(in: chooser, strings: strings)

        // The tile list: the innermost scroll area holding Other / the tile (a page can nest
        // the list in an outer one), else the biggest one.
        let scrolls = find(in: chooser) { $0.role == "AXScrollArea" && $0.frame != nil }
        let holding = scrolls.filter { s in
            tiles.contains { $0.found.isInside(s) } || others.contains { $0.isInside(s) }
        }
        let list = holding.max { $0.path.count < $1.path.count }
            ?? scrolls.max { area($0.node.frame) < area($1.node.frame) }
        if let list, var sf = list.node.frame {
            if let b = bounds { sf = sf.intersection(b) }
            if let w = window { sf = sf.intersection(w) }
            if !sf.isNull && sf.width > 0 && sf.height > 0 {
                scene.scrollArea = sf
                if let id = list.node.id { scene.ids.insert(id) }
            }
        }
        let listClip = scene.scrollArea ?? bounds

        if let o = others.first(where: { visibleFraction($0.node.frame!, in: listClip) >= 0.5 }) {
            scene.otherHeader = o.node.frame
        }

        // The best tile: clickable, inside the list, after the Other header.
        let otherY = others.first?.node.frame?.minY
        let best = tiles.max { a, b in
            score(a, list: list, otherY: otherY) < score(b, list: list, otherY: otherY)
        }
        if let best {
            best.ids.forEach { scene.ids.insert($0) }
            scene.tileSelected = best.selected
            if visibleFraction(best.frame, in: listClip) >= 0.6 {
                scene.tile = best.frame
            } else {
                scene.tileOutOfView = true
            }
        }

        if let d = find(in: chooser, { $0.role == "AXButton" && $0.frame != nil && has($0, in: strings.done) }).first,
           visibleFraction(d.node.frame!, in: window) >= 0.6 {
            scene.done = d.node.frame
            if let id = d.node.id { scene.ids.insert(id) }
        }
    }

    struct TileCandidate {
        var found: Found
        /// The tile's frame: the clickable element, plus its name label under it.
        var frame: CGRect
        var clickable: Bool
        var selected: Bool
        var ids: [Int]
    }

    private static func score(_ t: TileCandidate, list: Found?, otherY: CGFloat?) -> Int {
        var s = t.clickable ? 4 : 0
        if let list, t.found.isInside(list) { s += 3 }
        if let otherY, t.frame.minY >= otherY - 2 { s += 2 }
        return s
    }

    /// Elements named DotStudio, each widened to the whole tile: a label's tile is its
    /// clickable parent, or the image right above it; a clickable tile takes in its label.
    static func tileCandidates(in root: AXNodeSnapshot, strings: CoachStrings) -> [TileCandidate] {
        var out: [TileCandidate] = []
        root.walk { n, anc, path in
            guard let f = n.frame, f.width > 1, f.height > 1, n.texts.contains(where: strings.isSaverName) else { return }
            var frame = f
            var ids = [n.id].compactMap { $0 }
            var clickable = isClickable(n)
            var selected = n.selected == true || (n.role == "AXRadioButton" && n.value == "1")
            let parent = anc.last
            let index = path.last ?? 0
            if textRoles.contains(n.role), let parent {
                if isClickable(parent), let pf = parent.frame, pf.width <= max(f.width, 60) * 3.5, pf.height <= 320 {
                    // The label sits inside the tile's button/cell.
                    frame = pf; clickable = true
                    selected = selected || parent.selected == true
                    if let id = parent.id { ids.append(id) }
                } else if index > 0 {
                    // A small group around the label is the tile: its selection counts.
                    if let pf = parent.frame, pf.width <= max(f.width, 60) * 3.5, pf.height <= 320 {
                        selected = selected || parent.selected == true
                    }
                    // An image (or button) right above the label: the two make the tile.
                    let above = parent.children[..<index].reversed().first { s in
                        guard let sf = s.frame, !textRoles.contains(s.role) else { return false }
                        return sf.maxY <= f.minY + 6 && f.minY - sf.maxY < 30 && sf.minX < f.maxX && f.minX < sf.maxX
                    }
                    if let above, let af = above.frame {
                        frame = af.union(f)
                        clickable = clickable || isClickable(above) || above.role == "AXImage"
                        selected = selected || above.selected == true
                        if let id = above.id { ids.append(id) }
                    }
                }
            } else if let parent, index + 1 < parent.children.count {
                // A tile with its name label right under it.
                let next = parent.children[index + 1]
                if let nf = next.frame, textRoles.contains(next.role), next.texts.contains(where: strings.isSaverName),
                   nf.minY >= f.maxY - 6, nf.minY - f.maxY < 30 {
                    frame = f.union(nf)
                    if let id = next.id { ids.append(id) }
                }
            }
            // A label already inside a tile found from its clickable sibling/parent: skip it.
            if textRoles.contains(n.role),
               out.contains(where: { $0.clickable && $0.frame.insetBy(dx: -1, dy: -1).contains(frame) }) {
                return
            }
            out.append(TileCandidate(found: Found(node: n, ancestors: anc, path: path), frame: frame,
                                     clickable: clickable, selected: selected, ids: ids))
        }
        return out
    }
}

// MARK: - The step

/// The coach's steps, in order. The illustrated walkthrough has four steps; Done shares the
/// fourth (Choose DotStudio, then Done).
enum CoachStep: Int, CaseIterable, Comparable {
    case openWallpaper, openChooser, scrollToTile, chooseTile, clickDone, finished

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// The illustrated walkthrough's step (SetupWalkthrough.steps) for this one.
    var walkthroughStep: Int { min(rawValue, 3) }

    var title: String {
        switch self {
        case .openWallpaper: return "Open Wallpaper"
        case .openChooser: return "Click Screen Saver\u{2026}"
        case .scrollToTile: return "Scroll to Other"
        case .chooseTile: return "Choose DotStudio"
        case .clickDone: return "Click Done"
        case .finished: return "All set"
        }
    }

    var name: String { String(describing: self) }
}

enum CoachTargetKind: Equatable {
    /// A control: a tight ring.
    case control
    /// A region to scroll: a softer, wider ring.
    case area
}

/// What the coach shows for one moment: the step, and the ring's target and words.
struct CoachDecision: Equatable {
    enum Situation: Equatable {
        case normal
        /// System Settings isn't open (or has no window).
        case settingsClosed
        /// Some other settings page is showing.
        case elsewhere
        /// DotStudio is chosen on some displays but not all: back on the Wallpaper page.
        case otherDisplay
    }

    var step: CoachStep
    var situation: Situation = .normal
    var target: CGRect?
    var kind: CoachTargetKind = .control
    var callout: String?
}

enum CoachPlanner {
    /// The step for what's on screen and what the wallpaper store says.
    /// - chosenOn / chosenOf: SetupSnapshot.choice (nil when it couldn't be read).
    /// - chosenWhenOpened: chosenOn when the chooser opened — a rise means the user just
    ///   picked DotStudio in it.
    static func decide(_ scene: CoachScene, chosenOn: Int?, chosenOf: Int?, chosenWhenOpened: Int?) -> CoachDecision {
        let everywhere = (chosenOn ?? 0) > 0 && (chosenOn ?? 0) >= (chosenOf ?? 1)
        switch scene.page {
        case .none:
            return CoachDecision(step: .openWallpaper, situation: .settingsClosed)
        case .elsewhere:
            return CoachDecision(step: .openWallpaper, situation: .elsewhere, target: scene.wallpaperRow,
                                 callout: scene.wallpaperRow == nil ? nil : "Click Wallpaper")
        case .wallpaper:
            if everywhere { return CoachDecision(step: .finished) }
            let situation: CoachDecision.Situation = (chosenOn ?? 0) > 0 ? .otherDisplay : .normal
            if let b = scene.screenSaverButton {
                return CoachDecision(step: .openChooser, situation: situation, target: b, callout: "Click Screen Saver\u{2026}")
            }
            if let a = scene.pageScrollArea {
                return CoachDecision(step: .openChooser, situation: situation, target: a, kind: .area,
                                     callout: "Scroll down to Screen Saver\u{2026}")
            }
            return CoachDecision(step: .openChooser, situation: situation)
        case .chooser:
            let rose = chosenWhenOpened.map { (chosenOn ?? 0) > $0 } ?? false
            let picked = scene.tileSelected || rose || everywhere
            if picked {
                if let d = scene.done { return CoachDecision(step: .clickDone, target: d, callout: "Click Done") }
                // macOS 14/15 have no Done: choosing is the last click.
                if !scene.chooserIsSheet { return CoachDecision(step: .finished) }
                return CoachDecision(step: .clickDone)
            }
            if let t = scene.tile { return CoachDecision(step: .chooseTile, target: t, callout: "Click DotStudio") }
            if let a = scene.scrollArea {
                return CoachDecision(step: .scrollToTile, target: a, kind: .area,
                                     callout: scene.otherHeader == nil ? "Scroll down to Other" : "DotStudio is under Other \u{2014} scroll a little more")
            }
            return CoachDecision(step: .scrollToTile)
        }
    }
}

// MARK: - Geometry

enum CoachGeometry {
    /// AX global (top-left origin, y down) ↔ Cocoa screen (bottom-left of the main display,
    /// y up). The same flip both ways; `mainHeight` = the main display's height in points.
    static func flip(_ r: CGRect, mainHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }

    enum Side: String { case below, above, right, left }

    /// Where the callout goes: outside the ring (with `gap`), below if it fits, else above,
    /// right, left; clamped into `bounds` (the screen, same space as `ring`).
    static func callout(ring: CGRect, size: CGSize, bounds: CGRect, gap: CGFloat = 14) -> (frame: CGRect, side: Side) {
        let inset = bounds.insetBy(dx: 8, dy: 8)
        func clamp(_ r: CGRect) -> CGRect {
            var r = r
            r.origin.x = min(max(r.minX, inset.minX), max(inset.maxX - r.width, inset.minX))
            r.origin.y = min(max(r.minY, inset.minY), max(inset.maxY - r.height, inset.minY))
            return r
        }
        let below = CGRect(x: ring.midX - size.width / 2, y: ring.maxY + gap, width: size.width, height: size.height)
        if below.maxY <= inset.maxY { return (clamp(below), .below) }
        let above = CGRect(x: ring.midX - size.width / 2, y: ring.minY - gap - size.height, width: size.width, height: size.height)
        if above.minY >= inset.minY { return (clamp(above), .above) }
        let right = CGRect(x: ring.maxX + gap, y: ring.midY - size.height / 2, width: size.width, height: size.height)
        if right.maxX <= inset.maxX { return (clamp(right), .right) }
        let left = CGRect(x: ring.minX - gap - size.width, y: ring.midY - size.height / 2, width: size.width, height: size.height)
        if left.minX >= inset.minX { return (clamp(left), .left) }
        // A ring as big as the screen: inside it, at the bottom.
        let inside = CGRect(x: ring.midX - size.width / 2, y: min(ring.maxY, inset.maxY) - size.height - gap,
                            width: size.width, height: size.height)
        return (clamp(inside), .above)
    }

    /// How much of `target` the windows in `occluders` cover (0…1; overlaps counted once
    /// per occluder, capped at 1).
    static func coveredFraction(_ target: CGRect, by occluders: [CGRect]) -> CGFloat {
        guard target.width > 0, target.height > 0 else { return 0 }
        var covered: CGFloat = 0
        for o in occluders {
            let i = target.intersection(o)
            if !i.isNull { covered += i.width * i.height }
        }
        return min(covered / (target.width * target.height), 1)
    }
}
