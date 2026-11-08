//  LibraryView.swift — the gallery: setup status, playback, and every style as a tile.
//
//  Styles split into two kinds:
//    • Scenes — self-contained generative pieces (Universe, Black Hole…). Pick and go.
//    • Looks  — effect stacks that restyle the shared source (gradient/photo/video).

import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSource = false

    private var scenes: [Preset] { model.library.presets.filter(\.isScene) }
    private var looks: [Preset] { model.library.presets.filter { !$0.isScene } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if model.setupStatus != .ready {
                    SetupBanner(status: model.setupStatus)
                }
                PlaybackPanel()

                section(title: "Scenes",
                        subtitle: "Ready-made generative pieces. Nothing to set up.",
                        presets: scenes) {
                    EmptyView()
                } newTile: {
                    NewSceneTile()
                }

                section(title: "Looks",
                        subtitle: "Effects that restyle your source — a gradient, photo, or video.",
                        presets: looks) {
                    sourceButton
                } newTile: {
                    NewTile(title: "New Look", symbol: "plus") { model.addPreset() }
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 22)
            .frame(maxWidth: 1400)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("DotStudio")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                UpdateReadyButton()
                Menu {
                    Button("New Look") { model.addPreset() }
                    Menu("New Scene") {
                        ForEach(EffectKind.allCases.filter { $0.isScene && !$0.isRetired }, id: \.self) { kind in
                            Button(kind.displayName) { model.addScene(kind) }
                        }
                    }
                    Divider()
                    Button("Add Built-in Styles") { model.addDemoPack() }
                    Button("Import Style…") { model.importPresetsViaPanel() }
                } label: {
                    Label("New", systemImage: "plus")
                }
                .help("New Look or Scene, or import a style")

                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Transitions, performance, setup, updates (⌘,)")
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            var found = false
            for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                found = true
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.pathExtension.lowercased() == "dotstudiopreset" else { return }
                    DispatchQueue.main.async { model.importPresets(from: [url]) }
                }
            }
            return found
        }
    }

    private var sourceButton: some View {
        Button { showSource.toggle() } label: {
            HStack(spacing: 8) {
                SourceSwatch(source: model.library.source)
                    .frame(width: 30, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(0.15)))
                Text("Source: \(model.library.source.displayName)")
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.bordered)
        .help("The gradient, photo, or video every Look restyles")
        .popover(isPresented: $showSource, arrowEdge: .bottom) {
            SourceEditor(source: model.sourceBinding, model: model)
                .padding(16)
                .frame(width: 320)
        }
    }

    @ViewBuilder
    private func section<Accessory: View, New: View>(
        title: String, subtitle: String, presets: [Preset],
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder newTile: () -> New
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title2.weight(.semibold))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                accessory()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 340), spacing: 18, alignment: .top)],
                      alignment: .leading, spacing: 20) {
                ForEach(presets) { preset in
                    StyleTile(preset: preset)
                }
                newTile()
            }
        }
    }
}

// MARK: - Tile

struct StyleTile: View {
    @EnvironmentObject var model: AppModel
    let preset: Preset
    @State private var hovering = false
    @State private var live = false
    @State private var confirmDelete = false

    private var role: AppModel.Role { model.role(of: preset.id) }
    private var selected: Bool { model.selectedID == preset.id }
    private var excluded: Bool { model.playbackMode == .rotate && role == .none }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                thumbnail
                overlays
            }
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12),
                                  lineWidth: selected ? 3 : 1))
            .shadow(color: .black.opacity(hovering ? 0.25 : 0.12), radius: hovering ? 10 : 4, y: hovering ? 5 : 2)
            .scaleEffect(hovering ? 1.015 : 1)
            .opacity(excluded ? 0.5 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name).font(.body.weight(.medium)).lineLimit(1)
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { h in
            hovering = h
            // Animate the tile live after a short dwell; one live preview at a time.
            if h {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { if hovering { live = true } }
            } else {
                live = false
            }
        }
        .onTapGesture(count: 2) { model.edit(preset.id) }
        .onTapGesture { model.selectedID = preset.id }
        .contextMenu { menu }
        .help("Double-click to edit")
        .confirmationDialog("Delete “\(preset.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.delete(preset.id) }
        } message: {
            Text("This can't be undone.")
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if live {
            MetalPreview(preset: preset, source: model.library.source,
                         location: model.locationTuple, store: model.store)
                .allowsHitTesting(false)
        } else if let img = model.thumbnailer.image(for: preset, source: model.library.source) {
            Image(nsImage: img).resizable().scaledToFill()
        } else {
            Color.black
        }
    }

    @ViewBuilder private var overlays: some View {
        VStack {
            HStack(alignment: .top) {
                RoleBadge(role: role)
                Spacer()
                if model.playbackMode == .rotate {
                    Button { model.toggleRotation(preset.id) } label: {
                        Image(systemName: role == .rotating ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, role == .rotating ? Color.accentColor : Color.black.opacity(0.35))
                            .shadow(radius: 2)
                    }
                    .buttonStyle(.plain)
                    .help(role == .rotating ? "In rotation — click to skip" : "Skipped — click to include in rotation")
                }
            }
            Spacer()
            if hovering {
                HStack(spacing: 8) {
                    Spacer()
                    tileButton("Preview", "play.fill") {
                        ScreensaverPreviewController.shared.present(
                            preset: preset, source: model.library.source, store: model.store)
                    }
                    tileButton("Edit", "slider.horizontal.3") { model.edit(preset.id) }
                }
                .transition(.opacity)
            }
        }
        .padding(8)
    }

    private func tileButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var summary: String {
        let names = preset.effects.filter(\.enabled).map(\.kind.displayName)
        if preset.isScene { return names.count > 1 ? "Scene · " + names.dropFirst().joined(separator: " · ") : "Scene" }
        return names.isEmpty ? "Source only" : names.joined(separator: " · ")
    }

    @ViewBuilder private var menu: some View {
        Button("Edit") { model.edit(preset.id) }
        Button("Preview Full Screen") {
            ScreensaverPreviewController.shared.present(
                preset: preset, source: model.library.source, store: model.store)
        }
        Divider()
        switch model.playbackMode {
        case .single:
            Button("Use as Screensaver") { model.useAsScreensaver(preset.id) }
                .disabled(role == .active)
        case .rotate:
            Button(role == .rotating ? "Skip in Rotation" : "Include in Rotation") { model.toggleRotation(preset.id) }
        case .dayNight:
            Button("Show During the Day") { model.updateSchedule { $0.dayPresetID = preset.id } }
            Button("Show at Night") { model.updateSchedule { $0.nightPresetID = preset.id } }
        }
        Divider()
        Button("Duplicate") { model.duplicate(preset.id) }
        Button("Export Style…") { model.exportPreset(preset.id) }
        Button("Save Image…") { model.exportSelectedAsImage(preset.id) }
        Button("Set as Desktop Picture") { model.setSelectedAsWallpaper(preset.id) }
        Divider()
        Button("Delete…", role: .destructive) { confirmDelete = true }
    }
}

// MARK: - New tiles

struct NewTile: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) { label }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
    }

    var label: some View {
        NewTileFace(title: title, symbol: symbol, hovering: hovering)
    }
}

struct NewTileFace: View {
    let title: String
    let symbol: String
    var hovering: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(hovering ? Color.accentColor : Color.secondary.opacity(0.5))
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.05 : 0.025)))
                .overlay(Image(systemName: symbol).font(.title2.weight(.medium))
                    .foregroundStyle(hovering ? Color.accentColor : .secondary))
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
            Text(title).font(.body.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 2)
            Text(" ").font(.caption)   // keep baseline with sibling tiles
        }
        .contentShape(Rectangle())
    }
}

struct NewSceneTile: View {
    @EnvironmentObject var model: AppModel
    @State private var hovering = false
    @State private var picking = false

    var body: some View {
        Button { picking = true } label: {
            NewTileFace(title: "New Scene", symbol: "sparkles", hovering: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            AddEffectPicker(source: model.library.source, thumbnailer: model.thumbnailer,
                            include: { $0.isScene }, prompt: "Search scenes") { kind in
                picking = false
                model.addScene(kind)
            }
        }
    }
}

// MARK: - Setup

struct SetupBanner: View {
    @EnvironmentObject var model: AppModel
    let status: Installer.Status

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: status == .notInstalled ? "sparkles.tv" : "hand.point.up.left")
                .font(.system(size: 26))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(status == .notInstalled
                     ? "Install the DotStudio screensaver"
                     : "Almost there — choose DotStudio as your screensaver")
                    .font(.headline)
                Text(status == .notInstalled
                     ? "One step adds it to your Mac. Then pick it once in Wallpaper settings — after that, everything is controlled from here."
                     : "In Wallpaper settings, open Screen Saver and pick DotStudio. Repeat for each display you want it on.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if status == .notInstalled {
                Button("Install") { model.installScreensaver() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                Button("Open Wallpaper Settings") { Installer.openScreenSaverSettings() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentColor.opacity(0.25)))
    }
}

// MARK: - Playback

struct PlaybackPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Text("Screensaver").font(.headline)
                Picker("Mode", selection: Binding(get: { model.playbackMode }, set: { model.playbackMode = $0 })) {
                    ForEach(AppModel.PlaybackMode.allCases) { m in
                        Label(m.rawValue, systemImage: m.symbol).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if let nowID = nowPlayingID, let p = model.preset(nowID) {
                    Button {
                        ScreensaverPreviewController.shared.present(
                            preset: p, source: model.library.source, store: model.store)
                    } label: {
                        Label("Preview", systemImage: "play.fill")
                    }
                    .help("Full-screen preview of what's playing now — move the mouse or press a key to exit")
                }
            }
            detail
                .font(.callout)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary))
    }

    private var nowPlayingID: UUID? {
        switch model.playbackMode {
        case .single: return model.library.activeID
        case .rotate: return model.library.presets.first { model.isInRotation($0.id) }?.id
        case .dayNight:
            let deg = MetalRenderer.solarElevation(location: model.locationTuple) * 180 / .pi
            return deg >= -0.833 ? model.schedule.dayPresetID : model.schedule.nightPresetID
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.playbackMode {
        case .single:
            HStack(spacing: 8) {
                Text("Plays")
                    .foregroundStyle(.secondary)
                stylePicker(selection: Binding(get: { model.library.activeID },
                                               set: { if let id = $0 { model.useAsScreensaver(id) } }),
                            allowNone: false)
                Text("· Right-click any style to switch.").foregroundStyle(.tertiary)
            }
        case .rotate:
            HStack(spacing: 10) {
                Text("Rotating \(model.rotationCount) of \(model.library.presets.count) styles, every")
                    .foregroundStyle(.secondary)
                Picker("Interval", selection: Binding(get: { model.rotation.intervalMinutes },
                                                      set: { v in model.updateRotation { $0.intervalMinutes = v } })) {
                    Text("minute").tag(1.0)
                    Text("5 minutes").tag(5.0)
                    Text("15 minutes").tag(15.0)
                    Text("30 minutes").tag(30.0)
                    Text("hour").tag(60.0)
                }
                .labelsHidden().fixedSize()
                Toggle("Shuffle", isOn: Binding(get: { model.rotation.shuffle },
                                                set: { v in model.updateRotation { $0.shuffle = v } }))
                Text("· Tick tiles to choose which play.").foregroundStyle(.tertiary)
            }
        case .dayNight:
            HStack(spacing: 10) {
                Label("Day", systemImage: "sun.max.fill").foregroundStyle(.secondary)
                stylePicker(selection: Binding(get: { model.schedule.dayPresetID },
                                               set: { v in model.updateSchedule { $0.dayPresetID = v } }),
                            allowNone: true)
                Label("Night", systemImage: "moon.fill").foregroundStyle(.secondary).padding(.leading, 6)
                stylePicker(selection: Binding(get: { model.schedule.nightPresetID },
                                               set: { v in model.updateSchedule { $0.nightPresetID = v } }),
                            allowNone: true)
                Text("· Switches at sunrise and sunset — \(sunStatus).").foregroundStyle(.tertiary)
            }
        }
    }

    private func stylePicker(selection: Binding<UUID?>, allowNone: Bool) -> some View {
        Picker("Style", selection: selection) {
            if allowNone || selection.wrappedValue == nil { Text("None").tag(UUID?.none) }
            ForEach(model.library.presets) { p in
                Text(p.name).tag(UUID?.some(p.id))
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    private var sunStatus: String {
        let deg = MetalRenderer.solarElevation(location: model.locationTuple) * 180 / .pi
        return deg >= -0.833 ? "it's day now" : "it's night now"
    }
}

// MARK: - Source swatch

/// Tiny visual of the shared source for buttons and headers.
struct SourceSwatch: View {
    @EnvironmentObject var model: AppModel
    let source: SourceSpec
    /// Fixed id so the thumbnail cache reuses one slot for the raw-source image.
    static let sourceOnly = Preset(id: UUID(uuidString: "00000000-0000-0000-0000-00000000D07E")!, name: "Source")

    var body: some View {
        switch source.kind {
        case .gradient:
            LinearGradient(colors: [Color(source.colorA), Color(source.colorB)],
                           startPoint: .leading, endPoint: .trailing)
        case .image, .video:
            if let img = model.thumbnailer.image(for: SourceSwatch.sourceOnly, source: source) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                Color.secondary.opacity(0.3)
            }
        }
    }
}

extension SourceSpec {
    var displayName: String {
        switch kind {
        case .gradient: return "Gradient"
        case .image: return mediaFilename == nil ? "Photo (none)" : "Photo"
        case .video: return mediaFilename == nil ? "Video (none)" : "Video"
        }
    }
}
