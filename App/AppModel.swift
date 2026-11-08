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
    /// Whether DotStudio is installed and picked in System Settings.
    @Published private(set) var setupStatus: Installer.Status = Installer.status

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
                message: "Your latest edit couldn't be written to disk. Check free space and permissions on your home folder.")
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

    /// Promote any old per-style source up to the shared global source.
    private static func migrate(_ lib: Library) -> Library {
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
        for i in lib.presets.indices { lib.presets[i].source = nil }   // strip legacy field
        return lib
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
        let s = Installer.status
        if s != setupStatus { setupStatus = s }
    }

    // MARK: Playback

    enum PlaybackMode: String, CaseIterable, Identifiable {
        case single = "One Style"
        case rotate = "Rotate"
        case dayNight = "Day & Night"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .single: return "play.rectangle"
            case .rotate: return "arrow.triangle.2.circlepath"
            case .dayNight: return "sun.horizon"
            }
        }
    }

    /// Rotation and day/night collapse into one mode, so they never fight.
    var playbackMode: PlaybackMode {
        get {
            if library.schedule?.enabled == true { return .dayNight }
            if library.rotation?.enabled == true { return .rotate }
            return .single
        }
        set {
            var rot = library.rotation ?? RotationSpec()
            var sch = library.schedule ?? ScheduleSpec()
            rot.enabled = (newValue == .rotate)
            sch.enabled = (newValue == .dayNight)
            if newValue == .dayNight {
                // Seed sensible picks so the mode works the moment it's chosen.
                if sch.dayPresetID == nil { sch.dayPresetID = library.activeID ?? library.presets.first?.id }
                if sch.nightPresetID == nil {
                    sch.nightPresetID = library.presets.first { $0.isScene }?.id ?? library.presets.last?.id
                }
            }
            library.rotation = rot
            library.schedule = sch
            save()
        }
    }

    var rotation: RotationSpec { library.rotation ?? RotationSpec() }
    var schedule: ScheduleSpec { library.schedule ?? ScheduleSpec() }

    func updateRotation(_ change: (inout RotationSpec) -> Void) {
        var r = rotation; change(&r); library.rotation = r; save()
    }

    func updateSchedule(_ change: (inout ScheduleSpec) -> Void) {
        var s = schedule; change(&s); library.schedule = s; save()
    }

    /// nil presetIDs = every style rotates.
    func isInRotation(_ id: UUID) -> Bool {
        guard let ids = rotation.presetIDs, !ids.isEmpty else { return true }
        return ids.contains(id)
    }

    func toggleRotation(_ id: UUID) {
        updateRotation { r in
            var ids = r.presetIDs.flatMap { $0.isEmpty ? nil : $0 } ?? library.presets.map(\.id)
            if let i = ids.firstIndex(of: id) {
                guard ids.count > 1 else { return }          // keep at least one style rotating
                ids.remove(at: i)
            } else {
                ids.append(id)
            }
            ids = library.presets.map(\.id).filter(ids.contains)   // library order, no strays
            r.presetIDs = ids.count == library.presets.count ? nil : ids
        }
    }

    var rotationCount: Int { library.presets.filter { isInRotation($0.id) }.count }

    /// What the screensaver shows for a style, in the current mode (for tile badges).
    enum Role { case none, active, rotating, day, night, dayAndNight }
    func role(of id: UUID) -> Role {
        switch playbackMode {
        case .single: return library.activeID == id ? .active : .none
        case .rotate: return isInRotation(id) ? .rotating : .none
        case .dayNight:
            let d = schedule.dayPresetID == id, n = schedule.nightPresetID == id
            return d && n ? .dayAndNight : d ? .day : n ? .night : .none
        }
    }

    /// One-click "show this one": switches to single mode and makes it active.
    func useAsScreensaver(_ id: UUID) {
        library.activeID = id
        if playbackMode != .single { playbackMode = .single } else { save() }
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

    /// Append the built-in demo screensavers that aren't already present (by name).
    func addDemoPack() {
        let existing = Set(library.presets.map(\.name))
        let toAdd = DefaultPresets.coolPack().filter { !existing.contains($0.name) }
        guard !toAdd.isEmpty else { return }
        library.presets.append(contentsOf: toAdd)
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
        if let ids = library.rotation?.presetIDs, ids.contains(id) { library.rotation?.presetIDs?.append(copy.id) }
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
        library.presets.remove(at: idx)
        if library.activeID == id { library.activeID = library.presets.first?.id }
        library.rotation?.presetIDs?.removeAll { $0 == id }
        if library.schedule?.dayPresetID == id { library.schedule?.dayPresetID = nil }
        if library.schedule?.nightPresetID == id { library.schedule?.nightPresetID = nil }
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
}
