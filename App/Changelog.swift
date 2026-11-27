//  Changelog.swift — the release notes, in the app: CHANGELOG.md (the repo's, bundled as a
//  resource by project.yml) parsed into releases, and the one-time "What's New" decision.
//
//    • Changelog        — the parsed file: releases newest first, each with its version, title,
//                         optional date and sections of bullets (nested, inline Markdown kept).
//                         Forgiving: unknown headings are just section names, a non-version
//                         "## Unreleased" (or any other) block is skipped, prose and "> " notes
//                         become items, wrapped lines join their bullet. Never touches the network.
//    • Release.media    — an optional image line in a release (`![alt](url)`, standard Markdown so
//                         GitHub's release notes show it): kept on the release, never drawn as
//                         text. The app never loads the URL — WhatsNewClip maps it to a film
//                         bundled in the app (a tiny table, version → film), else shows nothing.
//    • AppVersion       — numeric version compare ("1.6.10" > "1.6.9").
//    • WhatsNew         — what to show at launch (a pure function, self-tested) and the main
//                         window's state for the sheet (WhatsNew.Center). ChangelogViews.swift
//                         draws the sheet and Settings › Updates › Release Notes.
//
//  The once-only rule (WhatsNew.decide):
//    • The running version is newer than `changelogSeenVersion` and the changelog has an entry
//      for it → the entries after the seen version up to the running one, newest first.
//    • Nothing seen yet: a fresh install (onboarding never finished) records the version and
//      shows nothing — onboarding covers the first run; an existing user (onboarding done, from
//      before this feature) gets the running version's entry.
//    • Seen ≥ running (same version, a downgrade): nothing, and the record never goes down.
//  It's recorded only once the sheet is actually up, so a launch hidden in the menu bar at
//  login (no window) shows it the next time the window opens. Never in a headless run, a demo
//  run or a local (dev) build — those share the real app's defaults; DEBUG hooks below.
//
//  DEBUG / test hooks:
//    DOTSTUDIO_WHATSNEW_SELFTEST=1         parser + decision + a temp defaults suite round
//                                          trip, printed as ok/FAIL lines, then exits
//    DOTSTUDIO_WHATSNEW_DEFAULTS=<suite>   read/write the seen version in that defaults suite
//                                          (never the app's own), and allow a local build
//    DOTSTUDIO_WHATSNEW_VERSION=1.6.8      pretend to be that version (Settings' "installed" too)

import Foundation
import SwiftUI

// MARK: - Model

struct Changelog: Equatable {
    struct Item: Equatable, Identifiable {
        enum Kind: Equatable { case bullet, paragraph, note }
        let id: Int
        var kind: Kind
        /// Inline Markdown (bold, italics, `code`, links), wrapped lines joined with a space.
        var text: String
        var children: [Item] = []
    }

    struct Section: Equatable, Identifiable {
        let id: Int
        /// "New", "Changed", "Fixed"… — nil for items straight under the release heading.
        var heading: String?
        var items: [Item] = []

        /// An SF Symbol for the heading (Classic's sheet and Settings). Unknown headings get a
        /// plain list glyph.
        var symbol: String {
            let h = (heading ?? "").lowercased()
            if h.contains("new") { return "sparkles" }
            if h.contains("fix") { return "wrench.and.screwdriver" }
            if h.contains("improv") || h.contains("better") { return "wand.and.stars" }
            if h.contains("chang") { return "arrow.triangle.2.circlepath" }
            if h.contains("fast") || h.contains("perf") { return "hare" }
            if h.contains("battery") || h.contains("power") { return "battery.100" }
            if h.contains("retire") || h.contains("remov") { return "archivebox" }
            if h.contains("secur") { return "lock.shield" }
            return "list.bullet"
        }

        /// The symbol's colour in Classic (one hue per kind of change).
        var tint: Color {
            switch symbol {
            case "sparkles": return .orange
            case "wrench.and.screwdriver": return .green
            case "wand.and.stars": return .purple
            case "arrow.triangle.2.circlepath": return .blue
            case "hare": return .pink
            case "battery.100": return .green
            case "archivebox": return .brown
            default: return .secondary
            }
        }
    }

    struct Release: Equatable, Identifiable {
        var id: String { label }
        /// The version as compared ("1.6.8").
        let version: String
        /// The version as printed: "1.6.8", or "1.1.2 and earlier".
        let label: String
        /// The release's name ("Frame rate, your way"); may be empty.
        let title: String
        /// A date from the heading ("2026-11-24"), if it has one.
        let date: String?
        var sections: [Section] = []
        /// The release's image line, if it has one (the first; later ones are dropped).
        var media: Media?

        var isEmpty: Bool { sections.allSatisfy { $0.items.isEmpty } }
    }

    /// A release's picture: `![Retro, assembled](https://…/media/whatsnew/1.7.0.webp)`.
    struct Media: Equatable {
        /// The alt text (the clip's accessibility label in the app).
        var alt: String
        /// As written; the app only reads its name (WhatsNewClip), never fetches it.
        var url: String
    }

    /// Newest first, as in the file.
    var releases: [Release]

    func release(for version: String) -> Release? {
        releases.first { AppVersion.compare($0.version, version) == .orderedSame }
    }
}

// MARK: - Parser

extension Changelog {
    /// The bundled CHANGELOG.md, parsed once. Empty if the resource is missing.
    static let bundled: Changelog = {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return Changelog(releases: []) }
        return parse(text)
    }()

    static func parse(_ markdown: String) -> Changelog {
        var releases: [Release] = []
        var current: Release?
        var nextID = 0
        func newID() -> Int { nextID += 1; return nextID }

        /// Where the next continuation line goes: the last item and its depth.
        var lastPath: [Int] = []          // indices into section.items / children
        var lastKind: Item.Kind?
        var blankSinceItem = false

        func finishRelease() {
            if var r = current {
                r.sections.removeAll { $0.items.isEmpty }
                if !r.isEmpty || !r.title.isEmpty { releases.append(r) }
            }
            current = nil
            lastPath = []; lastKind = nil
        }

        func ensureSection() {
            guard current != nil else { return }
            if current!.sections.isEmpty { current!.sections.append(Section(id: newID(), heading: nil)) }
        }

        /// Appends to the item at `path` in the last section.
        func appendText(_ s: String, at path: [Int]) {
            guard current != nil, !current!.sections.isEmpty, !path.isEmpty else { return }
            let si = current!.sections.count - 1
            func walk(_ items: inout [Item], _ p: ArraySlice<Int>) {
                guard let i = p.first, items.indices.contains(i) else { return }
                if p.count == 1 {
                    items[i].text += (items[i].text.isEmpty ? "" : " ") + s
                } else {
                    walk(&items[i].children, p.dropFirst())
                }
            }
            walk(&current!.sections[si].items, path[...])
        }

        /// Adds an item at `depth` (0 = top level; deeper only under an existing bullet).
        func addItem(_ item: Item, depth: Int) {
            guard current != nil else { return }
            ensureSection()
            let si = current!.sections.count - 1
            var d = min(depth, lastPath.count)        // can't skip a level
            if d > 0, lastKind == nil { d = 0 }
            func insert(_ items: inout [Item], _ p: ArraySlice<Int>, _ level: Int) -> [Int] {
                if level == 0 {
                    items.append(item)
                    return [items.count - 1]
                }
                guard let i = p.first, items.indices.contains(i) else {
                    items.append(item); return [items.count - 1]
                }
                return [i] + insert(&items[i].children, p.dropFirst(), level - 1)
            }
            lastPath = insert(&current!.sections[si].items, lastPath[...], d)
            lastKind = item.kind
        }

        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix { $0 == " " }.count

            if trimmed.isEmpty { blankSinceItem = true; continue }

            // Headings
            if let level = headingLevel(trimmed) {
                let text = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if level <= 1 { continue }                       // "# Changelog"
                if level == 2 {
                    finishRelease()
                    current = releaseHeading(text)                // nil → skipped block
                    blankSinceItem = false
                    continue
                }
                // ### and deeper: a section of the current release
                guard current != nil else { continue }
                current!.sections.append(Section(id: newID(), heading: stripInline(text)))
                lastPath = []; lastKind = nil; blankSinceItem = false
                continue
            }
            guard current != nil else { continue }
            if trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) && trimmed.count >= 3 { continue }   // rule

            // An image line: the release's media (checked before the wrapped-line rule, so it
            // never joins the bullet above it)
            if let media = imageLine(trimmed) {
                if current!.media == nil { current!.media = media }
                blankSinceItem = true
                continue
            }

            // Bullets: "- ", "* ", "+ ", "1. "
            if let body = bulletBody(trimmed) {
                addItem(Item(id: newID(), kind: .bullet, text: body), depth: indent / 2)
                blankSinceItem = false
                continue
            }
            // A blockquote note ("> **Installing:** …"), joined across its lines
            if trimmed.hasPrefix(">") {
                let body = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                if lastKind == .note, !blankSinceItem, lastPath.count == 1 {
                    appendText(body, at: lastPath)
                } else {
                    addItem(Item(id: newID(), kind: .note, text: body), depth: 0)
                }
                blankSinceItem = false
                continue
            }
            // A wrapped line: joins the item above (indented, or straight after it)
            if let kind = lastKind, kind != .note, !lastPath.isEmpty, indent > 0 || !blankSinceItem {
                appendText(trimmed, at: lastPath)
                blankSinceItem = false
                continue
            }
            // Prose
            addItem(Item(id: newID(), kind: .paragraph, text: trimmed), depth: 0)
            blankSinceItem = false
        }
        finishRelease()
        return Changelog(releases: releases)
    }

    private static func headingLevel(_ s: String) -> Int? {
        let hashes = s.prefix { $0 == "#" }.count
        guard hashes > 0, hashes <= 6 else { return nil }
        let rest = s.dropFirst(hashes)
        return rest.isEmpty || rest.first == " " ? hashes : nil
    }

    /// `![alt](url)` or `![alt](url "title")`, alone on a line.
    static func imageLine(_ s: String) -> Media? {
        guard s.hasPrefix("!["),
              let m = imagePattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let alt = Range(m.range(at: 1), in: s), let url = Range(m.range(at: 2), in: s) else { return nil }
        return Media(alt: stripInline(String(s[alt])), url: String(s[url]))
    }
    private static let imagePattern = try! NSRegularExpression(
        pattern: #"^!\[([^\]]*)\]\(\s*<?([^\s<>()]+)>?(?:\s+"[^"]*")?\s*\)$"#)

    private static func bulletBody(_ s: String) -> String? {
        for marker in ["- ", "* ", "+ "] where s.hasPrefix(marker) {
            return String(s.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        if let r = s.range(of: #"^\d{1,3}[.)] "#, options: .regularExpression) {
            return String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// "1.6.8 — Frame rate, your way", "[1.6.8] - 2026-11-24", "v1.7.0: Title (2026-12-01)",
    /// "1.1.2 and earlier". Nil when there's no version (e.g. "Unreleased").
    static func releaseHeading(_ heading: String) -> Release? {
        var text = heading.trimmingCharacters(in: .whitespaces)
        guard let r = text.range(of: #"^\[?v?(\d+(?:\.\d+){0,3})\]?"#, options: .regularExpression) else { return nil }
        let version = text[r].trimmingCharacters(in: CharacterSet(charactersIn: "[]vV"))
        text = String(text[r.upperBound...])

        // A date anywhere after the version
        var date: String?
        if let d = text.range(of: #"\(?\b\d{4}-\d{2}-\d{2}\b\)?"#, options: .regularExpression) {
            date = text[d].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            text.removeSubrange(d)
        }
        let separators = CharacterSet(charactersIn: "—–-:·|").union(.whitespaces)
        let lead = text.trimmingCharacters(in: .whitespaces).unicodeScalars.first
        let startsWithSeparator = lead.map { CharacterSet(charactersIn: "—–-:·|").contains($0) } ?? false
        let rest = text.trimmingCharacters(in: separators)
        if !rest.isEmpty, !startsWithSeparator {
            // "1.1.2 and earlier": the words belong to the version
            return Release(version: version, label: "\(version) \(rest)", title: "", date: date)
        }
        return Release(version: version, label: version, title: stripInline(rest), date: date)
    }

    /// A heading's text without Markdown emphasis marks.
    static func stripInline(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Clips

/// A release's clip in the app. The media line names a picture on the web for GitHub
/// (`…/whatsnew/<version>.webp`); the app never fetches it but plays a film it bundles: the
/// name after `whatsnew/` (the version) looked up here. No media line, another kind of name or
/// no row → no clip.
enum WhatsNewClip {
    /// `whatsnew/<version>` → a bundled film's base name; the app plays `<base>-light` or
    /// `<base>-dark` (.mov, with a .jpg poster) for the appearance it wears. A release with its
    /// own clip bundles the film and adds a row.
    static let films: [String: String] = [
        "1.7.0": "theme-retro",        // Retro, assembled (App/ThemeFilms)
    ]

    /// The bundled film's base name for a media line, or nil.
    static func film(for media: Changelog.Media?) -> String? {
        guard let media, let url = URL(string: media.url) else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count >= 2, parts[parts.count - 2] == "whatsnew", let last = parts.last else { return nil }
        return films[(String(last) as NSString).deletingPathExtension]
    }

    /// The film for a release in light or dark: "theme-retro-dark".
    static func filmName(for release: Changelog.Release, dark: Bool) -> String? {
        film(for: release.media).map { "\($0)-\(dark ? "dark" : "light")" }
    }
}

// MARK: - Versions

enum AppVersion {
    /// The running app's version (CFBundleShortVersionString), or DOTSTUDIO_WHATSNEW_VERSION.
    static var running: String {
        if let v = override { return v }
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
    /// Renders pin this (UIShots); the env hook sets it for a dev run.
    static var override: String? = ProcessInfo.processInfo.environment["DOTSTUDIO_WHATSNEW_VERSION"]

    static func components(_ v: String) -> [Int] {
        let core = v.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: "-").first ?? ""
        return core.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = components(a), y = components(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    static func isValid(_ v: String) -> Bool { v.range(of: #"^v?\d+(\.\d+)*"#, options: .regularExpression) != nil }
}

// MARK: - What's New

enum WhatsNew {
    static let seenKey = "changelogSeenVersion"
    /// A long gap (an update after months away) shows this many at most; the rest are in Settings.
    static let maxShown = 6

    struct Decision: Equatable {
        /// Newest first; empty = show nothing.
        var show: [Changelog.Release] = []
        /// Write this as the seen version now (fresh install, nothing to show); a shown sheet
        /// records `running` as it appears.
        var recordNow: String?
    }

    /// The pure rule (see the file header).
    static func decide(running: String, seen: String?, priorUse: Bool, changelog: Changelog) -> Decision {
        guard AppVersion.isValid(running) else { return Decision() }
        guard let seen, AppVersion.isValid(seen) else {
            // Nothing recorded yet.
            guard priorUse, let entry = changelog.release(for: running), !entry.isEmpty else {
                return Decision(recordNow: running)
            }
            return Decision(show: [entry])
        }
        guard AppVersion.compare(running, seen) == .orderedDescending else { return Decision() }
        guard changelog.release(for: running) != nil else { return Decision(recordNow: running) }
        let since = changelog.releases.filter {
            AppVersion.compare($0.version, seen) == .orderedDescending
                && AppVersion.compare($0.version, running) != .orderedDescending
                && !$0.isEmpty
        }
        return since.isEmpty ? Decision(recordNow: running) : Decision(show: Array(since.prefix(maxShown)))
    }

    /// Where the seen version is kept: the app's defaults, or DOTSTUDIO_WHATSNEW_DEFAULTS' suite.
    static let testSuite = ProcessInfo.processInfo.environment["DOTSTUDIO_WHATSNEW_DEFAULTS"]
    static var defaults: UserDefaults { testSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    /// Raising only: a downgrade or an older dev build never lowers it.
    static func record(_ version: String, in d: UserDefaults) {
        if let seen = d.string(forKey: seenKey), AppVersion.isValid(seen),
           AppVersion.compare(version, seen) != .orderedDescending { return }
        d.set(version, forKey: seenKey)
    }

    /// The launch can show it at all: not a render, probe or demo run, and not a local build
    /// (they share the real app's defaults) unless a test suite is set.
    static var allowedThisRun: Bool {
        !Appearance.isHeadlessRun && !DemoHooks.isActive
            && (!UpdateController.isLocalBuild || testSuite != nil)
            && ProcessInfo.processInfo.environment["DOTSTUDIO_WHATSNEW_SELFTEST"] == nil
    }

    /// The main window's What's New state: decided once per launch, presented by ContentView
    /// when the window is free (no onboarding, Settings or alert), recorded once it's up.
    final class Center: ObservableObject {
        static let shared = Center()
        /// The releases to show (newest first). Kept after the sheet closes, so it doesn't
        /// empty while it animates away.
        @Published private(set) var releases: [Changelog.Release] = []
        /// The sheet is waiting to be shown (or up).
        @Published private(set) var isPending = false
        /// Settings › Updates should scroll to the release notes as it opens ("See All Updates").
        @Published var scrollToReleaseNotes = false
        private var decided = false

        /// Once per launch, from the main window as it appears. `priorUse`: DotStudio was set up
        /// before this launch (onboarding finished or skipped).
        func decideIfNeeded(priorUse: Bool) {
            guard !decided, WhatsNew.allowedThisRun else { return }
            decided = true
            let d = WhatsNew.defaults
            let decision = WhatsNew.decide(running: AppVersion.running, seen: d.string(forKey: WhatsNew.seenKey),
                                           priorUse: priorUse, changelog: .bundled)
            if let v = decision.recordNow { WhatsNew.record(v, in: d) }
            if !decision.show.isEmpty {
                releases = decision.show
                isPending = true
            }
        }

        /// The sheet is up: recorded, so it won't come back on a later launch.
        func markShown() { WhatsNew.record(AppVersion.running, in: WhatsNew.defaults) }

        func dismiss() { if isPending { isPending = false } }

        /// "See All Updates": close the sheet, then Settings › Updates at the release notes
        /// (after the sheet has gone — one sheet at a time on the window).
        func showAllUpdates(model: AppModel) {
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.scrollToReleaseNotes = true
                model.openSettings(.updates)
            }
        }
    }
}

// MARK: - Self-test

extension WhatsNew {
    /// DOTSTUDIO_WHATSNEW_SELFTEST=1: parser, the decision table, and recording in a throwaway
    /// defaults suite (removed after). Prints ok/FAIL lines; exits 0 when all pass.
    static func runSelfTestIfRequested() {
        guard ProcessInfo.processInfo.environment["DOTSTUDIO_WHATSNEW_SELFTEST"] != nil else { return }
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print("\(ok ? "ok  " : "FAIL") \(what)")
            if !ok { failures += 1 }
        }

        // Parser: the bundled file
        let bundled = Changelog.bundled
        check(bundled.releases.count >= 10, "bundled CHANGELOG.md parses (\(bundled.releases.count) releases)")
        if let top = bundled.releases.first {
            check(!top.title.isEmpty && !top.sections.isEmpty, "newest release has a title and sections (\(top.label) — \(top.title))")
        }
        let versions = bundled.releases.map(\.version)
        check(zip(versions, versions.dropFirst()).allSatisfy { AppVersion.compare($0, $1) == .orderedDescending },
              "bundled releases are newest first, no duplicates")
        if let r168 = bundled.release(for: "1.6.8"), let new = r168.sections.first(where: { $0.heading == "New" }) {
            let nested = new.items.first { !$0.children.isEmpty }
            check(nested?.children.count == 4, "1.6.8 › New has a bullet with 4 nested bullets")
            check(new.items.first?.text.hasSuffix("on battery up to 120 fps too.") == true, "wrapped lines join their bullet")
        } else { check(false, "1.6.8 › New found") }
        if let old = bundled.releases.last {
            check(old.label == "1.1.2 and earlier" && old.title.isEmpty, "\"1.1.2 and earlier\" keeps its words in the label")
            check(old.sections.first?.items.first?.kind == .paragraph, "prose under a release is a paragraph")
        }
        if let r130 = bundled.release(for: "1.3.0") {
            check(r130.sections.last?.items.last?.kind == .note, "1.3.0 ends with a > note")
        }
        if let r113 = bundled.release(for: "1.1.3") {
            check(r113.sections.count == 1 && r113.sections[0].heading == nil && r113.sections[0].items.count == 3,
                  "1.1.3: bullets with no section heading")
        }

        // Parser: format drift
        let drift = Changelog.parse("""
        # Changelog
        ## [Unreleased]
        - not shipped yet
        ## [2.0.0] - 2026-12-01
        ### Whatever This Is
        * star bullet
            * deep child
        1. numbered
        ## v1.9.0: Colon title (2026-11-30)
        Some prose
        that wraps.
        #### Tiny
        - x
        ##
        ## 1.8.0 — Empty
        """)
        check(drift.releases.map(\.version) == ["2.0.0", "1.9.0", "1.8.0"], "skips Unreleased; brackets, v-prefix, colon")
        check(drift.releases.first?.date == "2026-12-01" && drift.releases[1].date == "2026-11-30", "dates from headings")
        check(drift.releases[1].title == "Colon title", "title after a colon, date removed")
        check(drift.releases.first?.sections.first?.heading == "Whatever This Is", "unknown section heading kept")
        check(drift.releases.first?.sections.first?.items.count == 2
              && drift.releases.first?.sections.first?.items.first?.children.count == 1, "star bullets, nesting, numbered")
        check(drift.releases[1].sections.first?.items.first?.text == "Some prose that wraps.", "prose lines join")
        check(drift.releases[2].isEmpty && drift.releases[2].title == "Empty", "an empty release keeps its title")

        // Media lines: kept on the release, never an item; mapped to a bundled film or nothing
        if let r170 = bundled.release(for: "1.7.0") {
            check(r170.media == Changelog.Media(alt: "Retro, assembled",
                                                url: "https://dotstudio.davidlam.online/media/whatsnew/1.7.0.webp"),
                  "1.7.0's media line parses (alt + URL)")
            func texts(_ items: [Changelog.Item]) -> [String] { items.flatMap { [$0.text] + texts($0.children) } }
            check(!r170.sections.flatMap { texts($0.items) }.contains { $0.contains("![") || $0.contains("whatsnew") },
                  "the media line isn't shown as a bullet or prose")
            check(r170.sections.first?.heading == "New", "1.7.0 still opens on New (no heading-less section for the image)")
            check(WhatsNewClip.filmName(for: r170, dark: true) == "theme-retro-dark"
                  && WhatsNewClip.filmName(for: r170, dark: false) == "theme-retro-light", "1.7.0 → theme-retro-light/-dark")
            for dark in [false, true] {
                let name = WhatsNewClip.filmName(for: r170, dark: dark) ?? "?"
                check(Bundle.main.url(forResource: name, withExtension: "jpg") != nil
                      && Bundle.main.url(forResource: name, withExtension: "mov") != nil, "\(name).mov + .jpg are bundled")
            }
        } else { check(false, "1.7.0 found") }
        check(bundled.releases.allSatisfy { $0.media == nil || WhatsNewClip.film(for: $0.media) != nil },
              "every bundled media line maps to a bundled film")
        if let r168 = bundled.release(for: "1.6.8") {
            check(r168.media == nil && WhatsNewClip.filmName(for: r168, dark: false) == nil, "no media line → no clip")
        }
        let pictures = Changelog.parse("""
        ## 3.0.0 — Pictures
        ![Some clip](https://example.com/media/whatsnew/9.9.9.webp)
        ### New
        - a bullet
        ![Second](media/whatsnew/1.7.0.webp)
        - another
        ## 2.9.0 — Titled
        ![Titled](<media/whatsnew/1.7.0.webp> "a title")
        - x
        ## 2.8.0 — Not an image
        - ![inline](a.webp) in a bullet stays a bullet

        Text with ![an inline image](b.webp) is prose
        """)
        if pictures.releases.count == 3 {
            let (p3, p2, p1) = (pictures.releases[0], pictures.releases[1], pictures.releases[2])
            check(p3.media?.alt == "Some clip" && p3.sections.count == 1 && p3.sections[0].items.count == 2,
                  "media line under the heading; a later image line dropped, not joined to the bullet")
            check(p3.sections[0].items[0].text == "a bullet", "an image line ends the bullet above it")
            check(WhatsNewClip.film(for: p3.media) == nil, "unknown whatsnew/<version> → no clip")
            check(p2.media?.url == "media/whatsnew/1.7.0.webp" && WhatsNewClip.film(for: p2.media) == "theme-retro",
                  "<url> \"title\" form; a relative URL maps too")
            check(p1.media == nil && p1.sections.first?.items.count == 2, "inline images stay in their text")
        } else { check(false, "media fixture parses (\(pictures.releases.count) releases)") }
        check(WhatsNewClip.film(for: Changelog.Media(alt: "", url: "https://x.example/media/1.7.0.webp")) == nil,
              "not under whatsnew/ → no clip")
        check(WhatsNewClip.film(for: nil) == nil, "no media → no clip")

        // Versions
        check(AppVersion.compare("1.6.10", "1.6.9") == .orderedDescending, "1.6.10 > 1.6.9")
        check(AppVersion.compare("1.7", "1.7.0") == .orderedSame, "1.7 == 1.7.0")
        check(AppVersion.compare("v1.5.0-beta.1", "1.5.0") == .orderedSame, "beta suffix ignored")

        // Decisions
        let log = Changelog.parse("""
        ## 1.6.9 — Nine
        - a
        ## 1.6.8 — Eight
        - b
        ## 1.6.7 — Seven
        - c
        ## 1.6.6 — Six
        - d
        ## 1.6.5 — Five
        - e
        """)
        func shown(_ d: Decision) -> [String] { d.show.map(\.version) }
        var d = decide(running: "1.6.9", seen: "1.6.8", priorUse: true, changelog: log)
        check(shown(d) == ["1.6.9"] && d.recordNow == nil, "one version up: that entry")
        d = decide(running: "1.6.9", seen: "1.6.5", priorUse: true, changelog: log)
        check(shown(d) == ["1.6.9", "1.6.8", "1.6.7", "1.6.6"], "skipped versions: every entry since, newest first")
        d = decide(running: "1.6.9", seen: "1.6.9", priorUse: true, changelog: log)
        check(d == Decision(), "same version: nothing")
        d = decide(running: "1.6.8", seen: "1.6.9", priorUse: true, changelog: log)
        check(d == Decision(), "downgrade: nothing, nothing recorded")
        d = decide(running: "1.6.9", seen: nil, priorUse: false, changelog: log)
        check(d.show.isEmpty && d.recordNow == "1.6.9", "fresh install: nothing shown, version recorded")
        d = decide(running: "1.6.9", seen: nil, priorUse: true, changelog: log)
        check(shown(d) == ["1.6.9"], "existing user, nothing recorded yet: the running version's entry")
        d = decide(running: "1.7.0", seen: "1.6.8", priorUse: true, changelog: log)
        check(d.show.isEmpty && d.recordNow == "1.7.0", "no entry for the running version: nothing, recorded")
        let long = Changelog.parse((0..<12).reversed().map { "## 2.\($0).0 — R\($0)\n- x" }.joined(separator: "\n"))
        d = decide(running: "2.11.0", seen: "1.0.0", priorUse: true, changelog: long)
        check(d.show.count == maxShown && d.show.first?.version == "2.11.0", "a long gap shows the newest \(maxShown)")

        // Recording, in a throwaway suite (never the app's own defaults)
        let suite = "com.davidlam.DotStudio.whatsnew-selftest-\(UUID().uuidString)"
        if let t = UserDefaults(suiteName: suite) {
            record("1.6.8", in: t)
            check(t.string(forKey: seenKey) == "1.6.8", "records the version")
            record("1.6.7", in: t)
            check(t.string(forKey: seenKey) == "1.6.8", "never records a lower version")
            record("1.6.10", in: t)
            check(t.string(forKey: seenKey) == "1.6.10", "raises to a newer one")
            let next = decide(running: "1.6.10", seen: t.string(forKey: seenKey), priorUse: true, changelog: log)
            check(next == Decision(), "after recording, the same version shows nothing (once only)")
            t.removePersistentDomain(forName: suite)
        } else { check(false, "temp defaults suite") }

        print(failures == 0 ? "whatsnew selftest: all passed" : "whatsnew selftest: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
