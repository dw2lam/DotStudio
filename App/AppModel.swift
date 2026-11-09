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
    lazy var thumbnailer: Thumbnailer = {
        let t = Thumbnailer(store: store)
        t.onUpdate = { [weak self] in self?.objectWillChange.send() }   // repaint when a video poster lands
        return t
    }()
    @Published var library: Library
    @Published var selectedID: UUID?
    /// The style open in the editor; nil = the library gallery is showing.
    @Published var editingID: UUID?
    @Published var storeAlert: StoreAlert?
    /// Shows the welcome sheet (first launch, or Help ▸ Welcome to DotStudio…).
    @Published var showOnboarding = false
    /// Whether DotStudio is installed and picked in System Settings.
    @Published private(set) var setupStatus: Installer.Status = DemoHooks.setupOverride ?? Installer.status

    init() {
        switch store.loadLibrary() {
        case .loaded(let loaded):
            library = AppModel.migrate(loaded)
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
        resolveLocation()
    }

    /// Persist the library, surfacing a write failure instead of dropping it silently.
    func save() {
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

    /// Resolve the device location once (IP geolocation) and cache it in the library.
    private func resolveLocation() {
        guard library.locationLat == nil else { return }
        LocationFetcher.fetch { [weak self] lat, lon in
            guard let self = self else { return }
            self.library.locationLat = lat
            self.library.locationLon = lon
            self.save()
        }
    }

    /// Bring a library written by an older build up to date (every launch; idempotent).
    static func migrate(_ lib: Library) -> Library {
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
        lib = offerNewBuiltIns(lib)
        if lib.version < 4 { lib.version = 4 }
        return lib
    }

    // MARK: Built-ins (library migration v4)

    /// Featured built-ins every library gets once, even one from before seenBuiltIns existed.
    /// (Now Playing was one until music became a presentation over any style — it's retired:
    /// never added, and a library that has it keeps it.)
    static let promotedBuiltIns = ["Tidewater"]

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
        var have = Set(lib.presets.map(\.name))
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
            result = migrate(before)
            let old = Set(before.presets.map(\.name))
            out += "version: \(before.version) → \(result.version)\n"
            out += "seenBuiltIns: \(before.seenBuiltIns.map { String($0.count) } ?? "none") → \(result.seenBuiltIns?.count ?? 0)\n"
            out += "added: \(result.presets.map(\.name).filter { !old.contains($0) })\n"
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

    func setActive(_ id: UUID) {
        library.activeID = id
        save()
    }

    var activeName: String {
        library.presets.first { $0.id == library.activeID }?.name ?? "—"
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

    func updateSchedule(_ change: (inout ScheduleSpec) -> Void) {
        var s = schedule; change(&s); library.schedule = s; save()
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

    func deleteSelected() {
        guard let id = selectedID else { return }
        delete(id)
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
        if WallpaperSlot.shared.styleID == id { WallpaperSlot.shared.stop() }
        if editingID == id { editingID = nil }
        let neighbor = library.presets.indices.contains(idx) ? idx : library.presets.count - 1
        selectedID = neighbor >= 0 ? library.presets[neighbor].id : nil
        save()
        thumbnailer.retain(ids: Set(library.presets.map(\.id)))
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

    /// Decode a share file, dropping effects whose kind this build doesn't know
    /// (files from newer app versions import instead of failing outright).
    static func decodeShared(_ data: Data) throws -> (Preset, skippedEffects: Int, source: SourceSpec?) {
        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var presetObj = obj["preset"] as? [String: Any]
        else { throw CocoaError(.fileReadCorruptFile) }
        var skipped = 0
        if let effects = presetObj["effects"] as? [[String: Any]] {
            let known = Set(EffectKind.allCases.map(\.rawValue))
            let kept = effects.filter { ($0["kind"] as? String).map(known.contains) ?? false }
            skipped = effects.count - kept.count
            presetObj["effects"] = kept
            obj["preset"] = presetObj
        }
        let cleaned = try JSONSerialization.data(withJSONObject: obj)
        let doc = try JSONDecoder().decode(PresetExport.self, from: cleaned)
        return (doc.preset, skipped, doc.source)
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

    /// Switch the slideshow back to the built-in photo set.
    func useBuiltInPhotos() {
        library.source.kind = .collection
        library.source.mediaFilenames = nil
        save()
    }
}
