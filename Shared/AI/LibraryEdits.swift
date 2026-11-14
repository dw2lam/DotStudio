//  LibraryEdits.swift — pure library edits shared by the app (AppModel) and dotstudio-mcp.
//
//  The app runs these on its in-memory library (then saves and does its UI side effects:
//  selection, wallpaper, thumbnails); dotstudio-mcp runs the same functions on library.json
//  when the app isn't running. One implementation, so the AI's edits land exactly as a click
//  in the app would.

import Foundation

/// The screensaver's lineup (Destinations.swift): what plays by day, and an optional night style.
struct ScreensaverLineup: Equatable {
    /// What plays by day (or all day), in library order. Never empty for a non-empty library.
    var playlist: [UUID]
    /// A different single style after sunset; nil = the playlist plays all day.
    var night: UUID?

    var rotates: Bool { playlist.count > 1 }
    func contains(_ id: UUID) -> Bool { playlist.contains(id) || night == id }
}

extension Library {
    /// A style a newer DotStudio wrote (kept in unknownPresets): this build lists it but must
    /// never edit, copy or delete it — that would duplicate its id or lose what it can't read.
    func newerBuildStyle(_ id: UUID) -> Preset? { unknownPresets.first { $0.preset.id == id }?.preset }

    static func newerBuildMessage(_ name: String) -> String {
        "“\(name)” was made with a newer version of DotStudio, so this version can't change, copy or delete it. Ask the user to update DotStudio."
    }

    /// The screensaver's lineup, derived from the stored fields exactly as the saver reads them.
    var screensaverLineup: ScreensaverLineup {
        let day = Playback.pool(in: self, night: false).map(\.id)
        let nightPool = Playback.pool(in: self, night: true).map(\.id)
        // A night pool that equals the day pool is "no night style". A multi-style night
        // pool can't come out of any UI that ever shipped; show it as no night style.
        let night = (nightPool != day && nightPool.count == 1) ? nightPool.first : nil
        return ScreensaverLineup(playlist: day, night: night)
    }

    /// Write a lineup in canonical stored form. Interval, shuffle and crossfade are kept.
    mutating func applyLineup(_ lineup: ScreensaverLineup) {
        guard let first = presets.first?.id else { return }
        let wanted = Set(lineup.playlist)
        var day = presets.map(\.id).filter(wanted.contains)   // library order, no strays
        if day.isEmpty { day = [first] }

        var rot = rotation ?? RotationSpec()
        rot.presetIDs = day
        rot.enabled = day.count > 1
        rotation = rot
        if day.count == 1 || !(activeID.map(day.contains) ?? false) {
            activeID = day[0]
        }

        var sch = schedule ?? ScheduleSpec()
        sch.dayPresetID = nil   // by day, fall through to the playlist
        if let n = lineup.night, presets.contains(where: { $0.id == n }) {
            sch.enabled = true
            sch.nightPresetID = n
        } else {
            sch.enabled = false
        }
        schedule = sch
    }

    /// Remove a style and move every reference to it (active, rotation, schedule, lineup,
    /// per-display pins). False = no such style.
    @discardableResult
    mutating func removePreset(_ id: UUID) -> Bool {
        guard let idx = presets.firstIndex(where: { $0.id == id }) else { return false }
        // Read the lineup before the style disappears, then write it back without it.
        let before = screensaverLineup
        presets.remove(at: idx)
        if activeID == id { activeID = presets.first?.id }
        rotation?.presetIDs?.removeAll { $0 == id }
        if schedule?.dayPresetID == id { schedule?.dayPresetID = nil }
        if schedule?.nightPresetID == id { schedule?.nightPresetID = nil }
        if before.contains(id), !presets.isEmpty {
            var after = before
            after.playlist.removeAll { $0 == id }
            if after.night == id { after.night = nil }
            applyLineup(after)
        }
        pruneDisplayStyles()
        pruneRules()           // When rules lose the style; a rule left with none goes
        return true
    }

    /// A name no style has yet: `base`, else "base 2", "base 3"…
    func uniqueName(_ base: String) -> String {
        let names = Set(presets.map(\.name) + unknownPresets.map(\.preset.name))
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// A copy of a style with fresh ids, inserted after it. Returns the copy.
    mutating func duplicatePreset(_ id: UUID, name: String? = nil) -> Preset? {
        guard let i = presets.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = presets[i]
        copy.id = UUID()
        copy.name = uniqueName(name ?? presets[i].name + " Copy")
        copy.effects = copy.effects.map { var e = $0; e.id = UUID(); return e }
        presets.insert(copy, at: i + 1)
        return copy
    }

    /// The screensaver plays only this style (the night pick stays unless it's this style).
    /// `onlyDisplay`: the single connected display's key — a style of its own there is cleared
    /// first (AppModel.playAsScreensaver).
    mutating func playAsScreensaver(_ id: UUID, onlyDisplay: String? = nil) {
        if let key = onlyDisplay, displayStyles?[key] != nil {
            displayStyles?[key] = nil
            if displayStyles?.isEmpty == true { displayStyles = nil }
        }
        var l = screensaverLineup
        l.playlist = [id]
        if l.night == id { l.night = nil }
        applyLineup(l)
    }
}

// MARK: - Signals and When rules (docs/signals-design.md) — the app's Settings and editor, and
// dotstudio-mcp's create_signal / set_rule (via the app or on the file), all edit through these.

extension Library {
    /// Add a signal, or replace the one with its id. nil = done; else why not (nothing changed).
    /// `forAI`: an assistant asks (the stricter host policy, SignalPolicy).
    mutating func upsertSignal(_ signal: Signal, forAI: Bool) -> String? {
        var s = signal
        s.name = s.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.kind == .web { s.file = nil } else { s.url = nil; s.auth = nil; s.pollMinutes = nil }
        var list = signals ?? []
        let i = list.firstIndex { $0.id == s.id }
        if i == nil, list.count >= Signal.maxCount {
            return "DotStudio keeps at most \(Signal.maxCount) signals. Delete one first (delete_signal)."
        }
        if list.contains(where: { $0.id != s.id && $0.name.caseInsensitiveCompare(s.name) == .orderedSame }) {
            return "A signal is already named “\(s.name)”. Pick another name."
        }
        // The AI host policy for a URL an assistant chose (a new signal, or a changed URL) — not
        // for the user's own local service when the AI only renames or pauses it.
        let strict = forAI && (i == nil || list[i!].url != s.url)
        let problems = SignalPolicy.validate(s, forAI: strict)
        if !problems.isEmpty { return problems.joined(separator: " ") }
        if let i {
            // Who made it never changes, and only the user's Settings change a key.
            s.createdBy = list[i].createdBy
            list[i] = s
        } else {
            if forAI { s.createdBy = "ai" }
            list.append(s)
        }
        signals = list
        return nil
    }

    /// Remove a signal. While a rule tests it or a style's scene input is bound to it: refused,
    /// unless `force`, which also removes those tests (and a rule left with none) and those
    /// bindings (the inputs fall back to their defaults). nil = done.
    mutating func deleteSignal(_ id: UUID, force: Bool) -> String? {
        guard let s = signal(id) else { return "No such signal." }
        let users = rules(using: s.key)
        let bound = inputBindings(using: s.key)
        if !(users.isEmpty && bound.isEmpty), !force {
            var parts: [String] = []
            if !users.isEmpty {
                parts.append((users.count == 1 ? "the rule " : "the rules ") + users.map { "“\($0.name)”" }.joined(separator: ", "))
            }
            if !bound.isEmpty {
                parts.append((bound.count == 1 ? "the scene input " : "the scene inputs ") + bound.map { "“\($0.style.name)” \($0.input)" }.joined(separator: ", "))
            }
            return "“\(s.name)” is used by " + parts.joined(separator: " and ")
                + ". Delete or change \(users.count + bound.count == 1 ? "it" : "them") first, or pass force: true to remove the signal and what uses it (rule tests go, inputs fall back to their defaults)."
        }
        if force { unbindSignal(s.key) }
        if force, var list = rules {
            for i in list.indices {
                list[i].when.all = list[i].when.all?.filter { $0.signal != s.key }
                list[i].when.any = list[i].when.any?.filter { $0.signal != s.key }
                if list[i].when.all?.isEmpty == true { list[i].when.all = nil }
                if list[i].when.any?.isEmpty == true { list[i].when.any = nil }
            }
            list.removeAll { $0.when.clauses.isEmpty }
            rules = list.isEmpty ? nil : list
        }
        signals?.removeAll { $0.id == id }
        if signals?.isEmpty == true { signals = nil }
        return nil
    }

    /// Add a rule (at the end: the first match in list order wins), or replace the one with its
    /// id in place. nil = done.
    mutating func upsertRule(_ rule: PlayRule) -> String? {
        var r = rule
        r.name = r.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<UUID>()
        r.play = r.play.filter { seen.insert($0).inserted }
        let problems = RuleEngine.validate(r, in: self)
        if !problems.isEmpty { return problems.joined(separator: " ") }
        var list = rules ?? []
        if let i = list.firstIndex(where: { $0.id == r.id }) { list[i] = r }
        else {
            guard list.count < PlayRule.maxCount else { return "DotStudio keeps at most \(PlayRule.maxCount) When rules." }
            list.append(r)
        }
        rules = list
        return nil
    }

    @discardableResult
    mutating func deleteRule(_ id: UUID) -> Bool {
        guard rules?.contains(where: { $0.id == id }) == true else { return false }
        rules?.removeAll { $0.id == id }
        if rules?.isEmpty == true { rules = nil }
        return true
    }
}

/// The signal and When-rule requests (upsertSignal, deleteSignal, upsertRule, deleteRule) on a
/// library — the same edit for the running app (AIBridgeHost) and dotstudio-mcp's offline path
/// (LibraryExecutor). Gates: signal edits need AISettings.allowSignals; rule edits change what
/// plays, so they need allowPlaybackChanges, exactly like set_screensaver.
enum SignalEdits {
    static let signalsOff = "The user has turned off “Let AI add live data signals” in DotStudio ▸ Settings ▸ AI. Ask the user to add the signal themselves in Settings ▸ Signals, or to turn that setting on."
    static let playbackOff = "The user has turned off “Let AI change what plays” in DotStudio ▸ Settings ▸ AI. Styles can still be created; ask the user to set it themselves, or to turn that setting on."

    static func run(_ req: BridgeRequest, library lib: inout Library, settings: AISettings) -> BridgeResponse {
        switch req.op {
        case .upsertSignal:
            guard settings.allowSignals else { return .fail(signalsOff) }
            guard let s = req.signal else { return .fail("no signal given") }
            let isNew = lib.signal(s.id) == nil
            if let why = lib.upsertSignal(s, forAI: true) { return .fail(why) }
            let name = lib.signal(s.id)?.name ?? s.name
            return BridgeResponse(ok: true, id: s.id, name: name, message: isNew ? "Added the signal “\(name)”." : "Updated the signal “\(name)”.")
        case .deleteSignal:
            guard settings.allowSignals else { return .fail(signalsOff) }
            guard let id = req.id, let s = lib.signal(id) else { return .fail("No such signal. Call list_signals.") }
            if let why = lib.deleteSignal(id, force: req.force ?? false) { return .fail(why) }
            return BridgeResponse(ok: true, id: id, name: s.name, message: "Deleted the signal “\(s.name)”.")
        case .testSignal:
            return .fail("testSignal is answered by the app")
        case .upsertRule:
            guard settings.allowPlaybackChanges else { return .fail(playbackOff) }
            guard var r = req.rule else { return .fail("no rule given") }
            let isNew = !(lib.rules ?? []).contains { $0.id == r.id }
            if isNew { r.createdBy = "ai" } else { r.createdBy = lib.rules?.first { $0.id == r.id }?.createdBy }
            if let why = lib.upsertRule(r) { return .fail(why) }
            return BridgeResponse(ok: true, id: r.id, name: r.name,
                                  message: (isNew ? "Added the When rule “\(r.name)”: " : "Updated the When rule “\(r.name)”: ") + RuleText.summary(r, in: lib) + ".")
        case .deleteRule:
            guard settings.allowPlaybackChanges else { return .fail(playbackOff) }
            guard let id = req.id, let r = lib.rules?.first(where: { $0.id == id }) else { return .fail("No such rule. Call list_rules.") }
            lib.deleteRule(id)
            return BridgeResponse(ok: true, id: id, name: r.name, message: "Deleted the When rule “\(r.name)”.")
        default:
            return .fail("not a signal request")
        }
    }
}
