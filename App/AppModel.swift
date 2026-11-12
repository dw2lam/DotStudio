//  AppModel.swift — observable state for the playground app.

import SwiftUI
import Combine
import UniformTypeIdentifiers

extension UTType {
    /// Sharable preset document (declared in project.yml's exported types).
    static let dotstudioPreset = UTType(exportedAs: "com.davidlam.dotstudio.preset")
}

/// On-disk format of a .dotstudiopreset share file.
struct PresetExport: Codable {
    var formatVersion: Int = 1
    var preset: Preset
    /// Included only for gradient sources — media files don't travel with presets.
    var source: SourceSpec?
}

/// A user-facing problem worth an alert (corrupt library, failed import/save).
struct StoreAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var backupURL: URL?          // when set, the alert offers "Reveal Backup in Finder"
}

final class AppModel: ObservableObject {
    let store = SharedStore(role: .app)
    /// The gallery's stills and their Metal renderer: made when a window first needs them,
    /// dropped when the last window closes (menu-bar mode keeps none of it — tens of MB of
    /// stills, textures and pipelines for a window nobody has open).
    var thumbnailer: Thumbnailer {
        if let t = _thumbnailer { return t }
        let t = Thumbnailer(store: store)
        t.location = { [weak self] in self?.locationTuple }   // live sky, Universe, weather tiles
        _thumbnailer = t
        return t
    }
    private var _thumbnailer: Thumbnailer?

    /// Every window closed (AppPresence): let the stills go; the next window renders them again
    /// (in the background, Thumbnailer.prewarm).
    func releaseThumbnails() {
        _thumbnailer = nil
        BlurCache.shared.removeAll()
    }
    @Published var library: Library
    @Published var selectedID: UUID? {
        didSet { if selectedID != oldValue { Breadcrumbs.note("select \(crumbName(selectedID))") } }
    }
    /// The style open in the editor; nil = the library gallery is showing.
    @Published var editingID: UUID? {
        didSet {
            guard editingID != oldValue else { return }
            Breadcrumbs.note(editingID == nil ? "close editor" : "edit \(crumbName(editingID))")
        }
    }

    /// A style's name for the crash reporter's breadcrumbs (kind too: names are the user's).
    func crumbName(_ id: UUID?) -> String {
        guard let id else { return "none" }
        guard let p = library.presets.first(where: { $0.id == id }) else { return "unknown style" }
        let kinds = p.effects.filter(\.enabled).map { "\($0.kind)" }.joined(separator: "+")
        return "“\(p.name)” [\(p.isScene ? "scene" : "look") \(kinds.isEmpty ? "-" : kinds)]"
    }
    @Published var storeAlert: StoreAlert?
    /// Shows the welcome sheet (first launch, or Help ▸ Welcome to DotStudio…).
    @Published var showOnboarding = false
    /// Whether DotStudio is installed and picked in System Settings.
    @Published private(set) var setupStatus: Installer.Status = DemoHooks.setupOverride ?? Installer.status

    init() {
        switch store.loadLibrary() {
        case .loaded(let loaded):
            let (migrated, retirement) = AppModel.migrateReporting(
                loaded, wallpaperPick: WallpaperController.pickedPresetID(storeDir: store.baseDir),
                wallpaperPins: WallpaperController.pinnedPresetIDs(storeDir: store.baseDir))
            library = migrated
            // The wallpaper's own pick (wallpaper.json, read by WallpaperController.attach
            // after this) follows a style the 1.4.2 retirement removed.
            if let retirement {
                WallpaperController.followRetirement(storeDir: store.baseDir, retirement.replacements)
            }
        case .missing:
            library = DefaultPresets.makeLibrary()
        case .corrupt(let backup):
            library = DefaultPresets.makeLibrary()
            storeAlert = StoreAlert(
                title: "Screensaver Library Couldn't Be Read",
                message: backup != nil
                    ? "Your library file was damaged, so DotStudio started with the default screensavers. The damaged file was saved as “\(backup!.lastPathComponent)” — if this happened after an update, a newer version of DotStudio may be able to restore it."
                    : "Your library file was damaged and couldn't be backed up. DotStudio started with the default screensavers.",
                backupURL: backup)
        }
        selectedID = library.activeID ?? library.presets.first?.id
        save()
        // A cached location resolved within the day waits out the rest of it; otherwise ask now.
        let age = Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: Self.locationResolvedAtKey)
        if locationTuple != nil, age >= 0, age < Self.locationRefreshInterval {
            scheduleLocation(after: Self.locationRefreshInterval - age)
        } else {
            resolveLocation()
        }
        // A display back under a new UUID adopts its pin; old unplugged ones are capped.
        rosterSub = DisplayRoster.shared.$displays
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.reconcileDisplayPins($0) }
    }

    private var rosterSub: AnyCancellable?

    /// The screensaver's per-display styles against the displays connected now (DisplayPins.reconcile).
    private func reconcileDisplayPins(_ displays: [DisplayInfo]) {
        guard let pins = library.displayStyles,
              let next = DisplayPins.reconcile(pins, connected: displays.map { ($0.key, $0.name) }) else { return }
        library.displayStyles = next.isEmpty ? nil : next
        save()
    }

    /// Persist the library, surfacing a write failure instead of dropping it silently.
    func save() {
        Perf.count("AppModel.save")
        library.pruneDisplayStyles()   // a deleted style's display pins go (Shared/DisplayPins.swift)
        if !store.save(library) && storeAlert == nil {
            storeAlert = StoreAlert(
                title: "Couldn't Save Changes",
                message: "Your latest edit couldn't be written to disk.\n\n\(store.lastSaveError ?? "Unknown error")")
        }
    }

    var locationTuple: (lat: Double, lon: Double)? {
        if let la = library.locationLat, let lo = library.locationLon { return (la, lo) }
        return nil
    }

    // MARK: Location (IP geolocation, cached in the library for the saver)

    /// A resolved location is refreshed about once a day (a laptop travels); a failed lookup
    /// retries with backoff instead of leaving the sky, the Universe marker and the weather
    /// without a place for the rest of the session.
    static let locationRefreshInterval: TimeInterval = 24 * 3600
    private static let locationBackoff: [TimeInterval] = [30, 120, 600, 1800, 3600]
    private var locationWork: DispatchWorkItem?
    private var locationInFlight = false
    private var locationFailures = 0
    private var locationAttempt = 0
    private static let locationResolvedAtKey = "locationResolvedAt"
    /// Offscreen renders and headless runs never go to the network.
    private static let locationDisabled = ProcessInfo.processInfo.environment["DOTSTUDIO_UI_SHOTS"] != nil
        || ProcessInfo.processInfo.environment["DOTSTUDIO_SHOTS"] != nil
        || ProcessInfo.processInfo.environment["DOTSTUDIO_PERF_PROBE"] != nil

    /// Resolve the device location now (launch: also refreshes a cached one) and cache it in
    /// the library; then again about daily, or sooner with backoff after a failure.
    private func resolveLocation() {
        guard !Self.locationDisabled, !locationInFlight else { return }
        locationWork?.cancel(); locationWork = nil
        locationInFlight = true
        locationAttempt += 1
        let attempt = locationAttempt
        LocationFetcher.fetch { [weak self] lat, lon in
            guard let self else { return }
            // A late answer after its attempt was written off still counts.
            self.locationInFlight = false
            self.locationFailures = 0
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.locationResolvedAtKey)
            if self.library.locationLat != lat || self.library.locationLon != lon {
                self.library.locationLat = lat
                self.library.locationLon = lon
                self.save()
            }
            self.scheduleLocation(after: Self.locationRefreshInterval)
        }
        // LocationFetcher only ever reports success (its request times out after 8 s): no answer
        // by now is a failure — retry with backoff.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.locationInFlight, self.locationAttempt == attempt else { return }
            self.locationInFlight = false
            let delay = Self.locationBackoff[min(self.locationFailures, Self.locationBackoff.count - 1)]
            self.locationFailures += 1
            self.scheduleLocation(after: delay)
        }
    }

    private func scheduleLocation(after seconds: TimeInterval) {
        locationWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.locationWork = nil
            self?.resolveLocation()
        }
        locationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Bring a library written by an older build up to date (every launch; idempotent).
    static func migrate(_ lib: Library) -> Library { migrateReporting(lib).library }

    /// migrate, plus what the 1.4.2 retirement did (nil: it had already run on this library).
    /// `wallpaperPick`: the live wallpaper's own style (wallpaper.json), so the 1.4.5 Tidewater
    /// fold knows it was in use there too.
    static func migrateReporting(_ lib: Library, wallpaperPick: UUID? = nil, wallpaperPins: [UUID] = [])
        -> (library: Library, retirement: DefaultPresets.Retirement?) {
        var lib = lib
        if lib.version < 2 {
            // Prefer the active style's old source, else the first non-gradient one.
            let active = lib.presets.first { $0.id == lib.activeID }
            let candidate = active?.source
                ?? lib.presets.compactMap(\.source).first { $0.kind != .gradient }
                ?? lib.presets.compactMap(\.source).first
            if let candidate { lib.source = candidate }
            lib.version = 2
        }
        if lib.version < 3 {
            // An untouched default gradient becomes the built-in photo slideshow.
            if DefaultPresets.legacyDefaultSources.contains(lib.source) { lib.source = .builtInPhotos }
            lib.version = 3
        }
        for i in lib.presets.indices { lib.presets[i].source = nil }   // strip legacy field
        // Live weather (Ocean Horizon's new Weather menu defaults to Live): Afterlight keeps its
        // clear sky. Only where the param is missing, so a user's own pick sticks.
        for i in lib.presets.indices where lib.presets[i].name == "Afterlight" {
            for j in lib.presets[i].effects.indices where lib.presets[i].effects[j].kind == .oceanHorizon
                && lib.presets[i].effects[j].params["weather"] == nil {
                lib.presets[i].effects[j].params["weather"] = 1
            }
        }
        // Sand Garden became Zen Garden (1.4): same scene kind, new compositions. Rename the
        // built-in style and map its retired patterns (Rosette/Twist/Petals/Spiral) to Surprise.
        // Runs until "Zen Garden" is recorded as seen (offerNewBuiltIns, just below), i.e. once,
        // so a later rename back to "Sand Garden" by the user sticks.
        if !(lib.seenBuiltIns ?? []).contains("Zen Garden") {
            for i in lib.presets.indices where lib.presets[i].name == "Sand Garden"
                && lib.presets[i].effects.first?.kind == .sandGarden {
                lib.presets[i].name = "Zen Garden"
                for j in lib.presets[i].effects.indices where lib.presets[i].effects[j].kind == .sandGarden {
                    var p = lib.presets[i].effects[j].params
                    if (p["pattern"] ?? 0) > 0.5 { p["pattern"] = 0 }
                    if p["height"] == 18 { p["height"] = 26 }   // the old default light → the new one
                    lib.presets[i].effects[j].params = p
                }
            }
        }
        lib = offerNewBuiltIns(lib)
        // 1.4.2, once per library (after offerNewBuiltIns, so the new clocks are in): untouched
        // copies of the retired styles leave and their references move (DefaultPresets
        // .retireUntouched). And Zen Garden comes to a library that never got it: a 1.3 library
        // had it marked seen on its first 1.4 launch without adding it (it wasn't promoted then).
        var retirement: DefaultPresets.Retirement?
        if !(lib.seenBuiltIns ?? []).contains(DefaultPresets.retirementMarker) {
            let have = Set(lib.presets.map(\.name) + lib.unknownPresets.map(\.preset.name))
            if !have.contains("Zen Garden"),
               let zen = DefaultPresets.offeredBuiltIns().first(where: { $0.name == "Zen Garden" }) {
                insertBuiltIn(zen, into: &lib.presets)
            }
            let (retired, report) = DefaultPresets.retireUntouched(lib)
            lib = retired
            retirement = report
            lib.seenBuiltIns = (lib.seenBuiltIns ?? []) + [DefaultPresets.retirementMarker]
        }
        // 1.4.5, once per library: Tidewater (Golden Hour with Follow the Sun on) folds into
        // Golden Hour. Its moves join the report, so the wallpaper's pick follows them too.
        if !(lib.seenBuiltIns ?? []).contains(DefaultPresets.tidewaterMarker) {
            let (folded, report) = DefaultPresets.foldTidewater(lib, wallpaperPick: wallpaperPick, wallpaperPins: wallpaperPins)
            lib = folded
            lib.seenBuiltIns = (lib.seenBuiltIns ?? []) + [DefaultPresets.tidewaterMarker]
            if !report.removed.isEmpty || !report.remapped.isEmpty || !report.kept.isEmpty {
                var r = retirement ?? DefaultPresets.Retirement()
                r.removed += report.removed
                r.kept += report.kept
                r.remapped += report.remapped
                r.replacements.merge(report.replacements) { a, _ in a }
                retirement = r
            }
        }
        if lib.version < 4 { lib.version = 4 }
        return (lib, retirement)
    }

    // MARK: Built-ins (library migration v4)

    /// Featured built-ins every library gets once, even one from before seenBuiltIns existed.
    /// (Now Playing was one until music became a presentation over any style — it's retired:
    /// never added, and a library that has it keeps it.)
    // The 1.4 highlights 1.3 users get once on upgrade (Zen Garden, Shallows), Bounce
    // (new after 1.4) and the 1.4.2 clocks (a 1.4 library gets those as new featured built-ins).
    // Sunray was one until 1.4.2 retired it (DefaultPresets.retiredStyles); Tidewater until 1.4.5
    // folded it into Golden Hour (DefaultPresets.foldTidewater).
    static let promotedBuiltIns = ["Zen Garden", "Shallows", "Bounce",
                                   "StandBy", "Minimal", "Chronometer", "Meadow", "Tall Grass",
                                   "Blue Bloom", "Baby's Breath", "Penguin"]

    /// New built-in styles reach existing libraries exactly once (runs on every launch):
    ///  • no `seenBuiltIns` (a library from before 1.4): everything shipping now counts as
    ///    seen WITHOUT being added — a curated library isn't flooded — except the promoted
    ///    styles, added if no style has their name;
    ///  • `seenBuiltIns`: every FEATURED built-in not seen yet is added (unless a style already
    ///    has its name); new pack styles only become "seen" (Add Built-in Styles has them).
    /// Added styles go after the last style of their kind. Then every offered built-in is
    /// recorded as seen, so deleting one sticks.
    static func offerNewBuiltIns(_ lib: Library) -> Library {
        var lib = lib
        let offered = DefaultPresets.offeredBuiltIns()
        let candidates: [Preset]
        if let seen = lib.seenBuiltIns.map(Set.init) {
            candidates = DefaultPresets.featuredPresets().filter { !seen.contains($0.name) }
        } else {
            candidates = offered.filter { promotedBuiltIns.contains($0.name) }
        }
        // (A style this build can't draw still holds its name: no duplicate once the newer
        // DotStudio that wrote it reads the library again.)
        var have = Set(lib.presets.map(\.name) + lib.unknownPresets.map(\.preset.name))
        for p in candidates where have.insert(p.name).inserted {
            insertBuiltIn(p, into: &lib.presets)
        }
        var seen = lib.seenBuiltIns ?? []
        var known = Set(seen)
        for name in offered.map(\.name) where known.insert(name).inserted { seen.append(name) }
        lib.seenBuiltIns = seen
        return lib
    }

    /// Puts a built-in after the last style of its kind (scenes before looks), so it lands at
    /// the end of its own gallery section without reordering anything.
    static func insertBuiltIn(_ p: Preset, into presets: inout [Preset]) {
        if let last = presets.lastIndex(where: { $0.isScene == p.isScene }) {
            presets.insert(p, at: last + 1)
        } else if p.isScene {
            presets.insert(p, at: presets.firstIndex(where: { !$0.isScene }) ?? presets.count)
        } else {
            presets.append(p)
        }
    }

    /// DOTSTUDIO_MIGRATE_ONLY (dev): migrate library.json in DOTSTUDIO_STORE_DIR exactly as a
    /// launch does (a missing one becomes a new library), save it, print what changed, exit.
    static func migrateOnly() -> Never {
        let store = SharedStore(role: .app)
        var out = "store: \(store.baseDir.path)\n"
        let result: Library
        switch store.loadLibrary() {
        case .loaded(let before):
            let (migrated, retirement) = migrateReporting(
                before, wallpaperPick: WallpaperController.pickedPresetID(storeDir: store.baseDir),
                wallpaperPins: WallpaperController.pinnedPresetIDs(storeDir: store.baseDir))
            result = migrated
            let old = Set(before.presets.map(\.name))
            out += "version: \(before.version) → \(result.version)\n"
            out += "seenBuiltIns: \(before.seenBuiltIns.map { String($0.count) } ?? "none") → \(result.seenBuiltIns?.count ?? 0)\n"
            out += "added: \(result.presets.map(\.name).filter { !old.contains($0) })\n"
            if let retirement {
                out += "retired: \(retirement.removed)\n"
                out += "kept (edited): \(retirement.kept)\n"
                out += "remapped: \(retirement.remapped)\n"
                if let w = WallpaperController.followRetirement(storeDir: store.baseDir, retirement.replacements) {
                    func name(_ id: UUID?, in lib: Library) -> String {
                        id.flatMap { i in lib.presets.first { $0.id == i }?.name } ?? "none"
                    }
                    out += "wallpaper: \(name(w.old, in: before)) → \(name(w.new, in: result))\n"
                }
            } else {
                out += "retirement: already done\n"
            }
            let unknown = before.unknownCounts
            if unknown.effects + unknown.presets > 0 {
                out += "kept for a newer build: \(unknown.effects) unknown effect(s) in shown styles, \(unknown.presets) style(s) of unknown effects only: \(before.unknownPresets.map(\.preset.name))\n"
            }
        case .missing:
            result = DefaultPresets.makeLibrary()
            out += "new library: version \(result.version), seenBuiltIns \(result.seenBuiltIns?.count ?? 0)\n"
        case .corrupt(let backup):
            out += "corrupt (backup: \(backup?.lastPathComponent ?? "none")) — left untouched\n"
            FileHandle.standardOutput.write(Data(out.utf8))
            exit(1)
        }
        out += "styles (\(result.presets.count)): \(result.presets.map { ($0.isScene ? "S:" : "L:") + $0.name }.joined(separator: " | "))\n"
        out += store.save(result) ? "saved\n" : "SAVE FAILED: \(store.lastSaveError ?? "?")\n"
        FileHandle.standardOutput.write(Data(out.utf8))
        exit(0)
    }

    var selected: Preset? { library.presets.first { $0.id == selectedID } }

    /// Binding to the one shared source. Editing it re-renders every style.
    var sourceBinding: Binding<SourceSpec> {
        Binding(get: { self.library.source },
                set: { self.library.source = $0; self.save() })
    }

    /// Stable, id-based binding to a preset that persists on every edit.
    func presetBinding(_ id: UUID) -> Binding<Preset> {
        Binding(
            get: { self.library.presets.first { $0.id == id } ?? Preset(name: "—") },
            set: { newValue in
                if let i = self.library.presets.firstIndex(where: { $0.id == id }) {
                    self.library.presets[i] = newValue
                    self.save()
                }
            })
    }

    // MARK: Navigation

    func edit(_ id: UUID) {
        selectedID = id
        editingID = id
    }

    func closeEditor() {
        if let id = editingID { selectedID = id }
        editingID = nil
    }

    /// Copy the bundled .saver into ~/Library/Screen Savers, then send the user
    /// straight to the one place macOS lets them pick it.
    func installScreensaver() {
        switch Installer.install() {
        case .success:
            refreshSetupStatus()
            if setupStatus != .ready { Installer.openScreenSaverSettings() }
        case .failure(let e):
            storeAlert = StoreAlert(title: "Couldn't Install the Screensaver",
                                    message: e.localizedDescription)
        }
    }

    func refreshSetupStatus() {
        let s = DemoHooks.setupOverride ?? Installer.status
        if s != setupStatus { setupStatus = s }
    }

    // MARK: Playback (stored form)
    //
    // The UI speaks in destinations — see Destinations.swift for the Screensaver
    // playlist / night pick model and how it maps onto `activeID`, `rotation` and
    // `schedule`. These are the raw accessors it builds on.

    var rotation: RotationSpec { library.rotation ?? RotationSpec() }
    var schedule: ScheduleSpec { library.schedule ?? ScheduleSpec() }

    func updateRotation(_ change: (inout RotationSpec) -> Void) {
        var r = rotation; change(&r); library.rotation = r; save()
    }

    func preset(_ id: UUID) -> Preset? { library.presets.first { $0.id == id } }

    // MARK: Preset CRUD

    /// New Look: a blank-ish stack on the shared source, opened straight in the editor.
    func addPreset() {
        var p = Preset(name: uniqueName("New Look"))
        p.effects = [EffectInstance(.dither)]
        library.presets.append(p)
        save()
        edit(p.id)
    }

    /// Onboarding's "Create Your Own": add the draft (or update it if it was already
    /// added, matched by id) and make it what plays. Returns the name it was saved under.
    @discardableResult
    func saveCreated(_ draft: Preset) -> String {
        var p = draft
        if let i = library.presets.firstIndex(where: { $0.id == draft.id }) {
            library.presets[i] = p
        } else {
            p.name = uniqueName(p.name.trimmingCharacters(in: .whitespaces).isEmpty ? "My Style" : p.name)
            library.presets.append(p)
        }
        playAsScreensaver(p.id)
        save()
        return p.name
    }

    /// New Scene from a generator effect.
    func addScene(_ kind: EffectKind) {
        var p = Preset(name: uniqueName(kind.displayName))
        p.effects = [EffectInstance(kind)]
        library.presets.append(p)
        save()
        edit(p.id)
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(library.presets.map(\.name))
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// File › Add Built-in Styles: every built-in style the library is missing (by name),
    /// featured and pack alike, each after the last style of its kind.
    func addDemoPack() {
        let existing = Set(library.presets.map(\.name))
        let toAdd = DefaultPresets.offeredBuiltIns().filter { !existing.contains($0.name) }
        guard !toAdd.isEmpty else { return }
        for p in toAdd { AppModel.insertBuiltIn(p, into: &library.presets) }
        var seen = library.seenBuiltIns ?? []
        for p in toAdd where !seen.contains(p.name) { seen.append(p.name) }
        library.seenBuiltIns = seen
        selectedID = toAdd.first?.id
        save()
    }

    func duplicateSelected() {
        guard let id = selectedID else { return }
        duplicate(id)
    }

    @discardableResult
    func duplicate(_ id: UUID) -> UUID? {
        guard let sel = preset(id) else { return nil }
        var copy = sel
        copy.id = UUID()
        copy.name = sel.name + " Copy"
        copy.effects = sel.effects.map { var e = $0; e.id = UUID(); return e }
        let at = (library.presets.firstIndex { $0.id == id } ?? library.presets.count - 1) + 1
        library.presets.insert(copy, at: at)
        selectedID = copy.id
        save()
        return copy.id
    }

    func delete(_ id: UUID) {
        guard let idx = library.presets.firstIndex(where: { $0.id == id }) else { return }
        // Read the lineup before the style disappears, then write it back without it.
        let before = screensaverLineup
        library.presets.remove(at: idx)
        if library.activeID == id { library.activeID = library.presets.first?.id }
        library.rotation?.presetIDs?.removeAll { $0 == id }
        if library.schedule?.dayPresetID == id { library.schedule?.dayPresetID = nil }
        if library.schedule?.nightPresetID == id { library.schedule?.nightPresetID = nil }
        if before.contains(id), !library.presets.isEmpty {
            var after = before
            after.playlist.removeAll { $0 == id }
            if after.night == id { after.night = nil }
            applyLineup(after, persist: false)
        }
        // A wallpaper showing exactly this style stops — unless a connected display still plays a
        // wallpaper of its own: then the others move on (WallpaperPick.sharedReplacement). Not
        // one matching the screensaver: its style is whatever the lineup shows now
        // (WallpaperController.libraryChanged moves it on).
        let slot = WallpaperSlot.shared
        if !WallpaperController.shared.followsScreensaver, slot.styleID == id {
            if let next = WallpaperPick.sharedReplacement(pins: slot.pins, library,
                                                          connected: DisplayRoster.shared.displays.map(\.key)) {
                slot.setShared(next)
            } else {
                slot.stop()
            }
        }
        // Displays that played it as a style of their own go back to the shared pick (the
        // screensaver's pins are dropped by save()).
        WallpaperSlot.shared.forget(id)
        if editingID == id { editingID = nil }
        let neighbor = library.presets.indices.contains(idx) ? idx : library.presets.count - 1
        selectedID = neighbor >= 0 ? library.presets[neighbor].id : nil
        save()
        _thumbnailer?.retain(ids: Set(library.presets.map(\.id)))
    }

    // MARK: Preset sharing (.dotstudiopreset)

    func exportSelected() {
        guard let id = selectedID else { return }
        exportPreset(id)
    }

    func exportPreset(_ id: UUID) {
        guard let sel = preset(id) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.dotstudioPreset]
        panel.nameFieldStringValue = sel.name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var doc = PresetExport(preset: sel)
        if library.source.kind == .gradient { doc.source = library.source }
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(doc).write(to: url, options: .atomic)
        } catch {
            storeAlert = StoreAlert(title: "Couldn't Export “\(sel.name)”",
                                    message: error.localizedDescription)
        }
    }

    func importPresetsViaPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.dotstudioPreset, .json]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        importPresets(from: panel.urls)
    }

    func importPresets(from urls: [URL]) {
        var added = 0, skippedEffects = 0
        for url in urls {
            do {
                let (preset, skipped, source) = try AppModel.decodeShared(try Data(contentsOf: url))
                var p = preset
                p.id = UUID()                                    // never collide with existing ids
                p.effects = p.effects.map { var e = $0; e.id = UUID(); return e }
                library.presets.append(p)
                selectedID = p.id
                if let source, library.source.kind == .gradient { library.source = source }
                added += 1
                skippedEffects += skipped
            } catch {
                storeAlert = StoreAlert(title: "Couldn't Import “\(url.lastPathComponent)”",
                                        message: error.localizedDescription)
            }
        }
        if added > 0 { save() }
        if skippedEffects > 0 {
            storeAlert = StoreAlert(
                title: "Imported with Warnings",
                message: "\(skippedEffects) effect\(skippedEffects == 1 ? "" : "s") from a newer version of DotStudio weren't recognized and were skipped.")
        }
    }

    /// Decode a share file. Effects whose kind this build doesn't know are skipped (files from
    /// newer app versions import instead of failing outright) — and kept with the style
    /// (Preset.unknownEffects) for a newer build; a style made only of those can't import.
    static func decodeShared(_ data: Data) throws -> (Preset, skippedEffects: Int, source: SourceSpec?) {
        let doc = try JSONDecoder().decode(PresetExport.self, from: data)
        if doc.preset.isUnknownToThisBuild {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey:
                "“\(doc.preset.name)” was made with a newer version of DotStudio: none of its effects are available in this version."])
        }
        // A shared file can say anything: every param clamped to its range (SafeNumbers).
        var preset = doc.preset
        preset.sanitize()
        var source = doc.source
        if let s = source?.slideSeconds, !s.isFinite { source?.slideSeconds = nil }
        if let m = source?.motion, !m.isFinite { source?.motion = nil }
        return (preset, preset.unknownEffects.count, source)
    }

    // MARK: Still-image export / wallpaper

    /// Save the selected screensaver as a PNG (rendered at screen resolution).
    func exportSelectedAsImage(_ id: UUID? = nil) {
        guard let sel = preset(id ?? selectedID ?? UUID()) else { return }
        do {
            try Exporter.exportImagePanel(preset: sel, library: library, store: store)
        } catch {
            storeAlert = StoreAlert(title: "Couldn't Export Image",
                                    message: error.localizedDescription)
        }
    }

    /// Render the selected screensaver and set it as the desktop wallpaper.
    func setSelectedAsWallpaper(_ id: UUID? = nil) {
        guard let sel = preset(id ?? selectedID ?? UUID()) else { return }
        do {
            try Exporter.setAsWallpaper(preset: sel, library: library, store: store)
        } catch {
            storeAlert = StoreAlert(title: "Couldn't Set Wallpaper",
                                    message: error.localizedDescription)
        }
    }

    // MARK: Media

    func importMedia(_ url: URL, kind: SourceKind) {
        do {
            let name = try store.importMedia(from: url)
            library.source.kind = kind
            library.source.mediaFilename = name
            save()
        } catch {
            NSLog("DotStudio import failed: \(error)")
            storeAlert = StoreAlert(
                title: "Couldn't Import \(kind == .video ? "Video" : "Image")",
                message: "“\(url.lastPathComponent)” couldn't be copied into your library: \(error.localizedDescription)")
        }
    }

    /// Make the slideshow play the user's own photos (copied into the media folder).
    func importSlideshowPhotos(_ urls: [URL]) {
        var names: [String] = []
        var failures: [String] = []
        for url in urls {
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            do { names.append(try store.importMedia(from: url)) } catch { failures.append(url.lastPathComponent) }
        }
        if !names.isEmpty {
            library.source.kind = .collection
            library.source.mediaFilenames = names
            save()
        }
        if !failures.isEmpty {
            storeAlert = StoreAlert(
                title: "Couldn't Import \(failures.count == 1 ? "a Photo" : "\(failures.count) Photos")",
                message: failures.joined(separator: ", ") + " couldn't be copied into your library.")
        }
    }

    /// A Bounce logo image, copied into the shared media folder (where the screensaver can read
    /// it): its stored name, or nil after telling the user why not.
    func importLogo(_ url: URL) -> String? {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        do {
            return try store.importMedia(from: url)
        } catch {
            storeAlert = StoreAlert(
                title: "Couldn't Import Logo",
                message: "“\(url.lastPathComponent)” couldn't be copied into your library: \(error.localizedDescription)")
            return nil
        }
    }

    /// Switch the slideshow back to the built-in photo set.
    func useBuiltInPhotos() {
        library.source.kind = .collection
        library.source.mediaFilenames = nil
        save()
    }
}
