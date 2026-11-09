//  DestinationCards.swift — the two glass cards at the top of the gallery that say
//  where styles play: the Screensaver (a playlist + optional night style, plus setup)
//  and the live Wallpaper. See Destinations.swift for how they map onto library.json.

import SwiftUI

/// The gallery's snapshot of who plays where, computed once per render.
struct GalleryState {
    let lineup: ScreensaverLineup
    let nowPlaying: UUID?
    let wallpaperID: UUID?

    init(model: AppModel, wallpaperID: UUID?) {
        lineup = model.screensaverLineup
        nowPlaying = model.nowPlayingID
        self.wallpaperID = wallpaperID
    }

    /// Styles on any destination (the "Playing" filter).
    var playingIDs: Set<UUID> {
        var s = Set(lineup.playlist)
        if let n = lineup.night { s.insert(n) }
        if let w = wallpaperID { s.insert(w) }
        return s
    }

    func badges(for id: UUID) -> TileBadges {
        TileBadges(onScreensaver: lineup.playlist.contains(id),
                   inRotation: lineup.rotates && lineup.playlist.contains(id),
                   playingNow: nowPlaying == id,
                   night: lineup.night == id,
                   wallpaper: wallpaperID == id)
    }
}

struct TileBadges: Equatable {
    var onScreensaver = false
    var inRotation = false
    var playingNow = false
    var night = false
    var wallpaper = false
    var isEmpty: Bool { !onScreensaver && !night && !wallpaper }
}

// MARK: - Row

struct DestinationRow: View {
    let state: GalleryState

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ScreensaverCard(state: state)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if WallpaperSlot.shared.isAvailable {
                WallpaperCard(state: state)
                    .frame(width: 292)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Screensaver

struct ScreensaverCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    let state: GalleryState

    private var lineup: ScreensaverLineup { state.lineup }
    private var playing: Preset? { state.nowPlaying.flatMap(model.preset) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                hero
                VStack(alignment: .leading, spacing: 14) {
                    header
                    playlistRow
                    if lineup.rotates {
                        rotationControls
                            .transition(.reveal(reduceMotion: reduceMotion))
                    }
                    Spacer(minLength: 0)
                    nightRow
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)

            if model.setupStatus != .ready {
                SetupStrip(status: model.setupStatus)
                    .padding([.horizontal, .bottom], 10)
                    .transition(.reveal(reduceMotion: reduceMotion, edge: .bottom))
            }
        }
        .glassCard(cornerRadius: 26)
        .motion(Motion.smooth, value: lineup)
        .motion(Motion.smooth, value: model.setupStatus)
    }

    // MARK: Live preview

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let p = playing {
                    // Live while the gallery is up front; a still otherwise (no GPU in the background).
                    if model.editingID == nil && activeState != .inactive && !DemoHooks.stillPreviews {
                        MetalPreview(preset: p, source: model.library.source,
                                     location: model.locationTuple, store: model.store, maxFPS: 30)
                            .allowsHitTesting(false)
                    } else {
                        StyleThumb(preset: p)
                    }
                } else {
                    Color.black
                }
            }
            .id(playing?.id)
            .transition(.opacity)

            if lineup.night != nil {
                Label(model.isNightNow ? "Night" : "Day",
                      systemImage: model.isNightNow ? "moon.fill" : "sun.max.fill")
                    .font(.caption2.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .glassSurface(.clear, in: Capsule())
                    .padding(8)
            }
        }
        .frame(width: 264, height: 165)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture(count: 2) { if let p = playing { model.edit(p.id) } }
        .help(playing.map { "\($0.name) — double-click to edit" } ?? "")
        .motion(Motion.smooth, value: playing?.id)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("SCREENSAVER")
                        .font(.caption.weight(.semibold))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                    StatusDot(status: model.setupStatus)
                }
                Text(playing?.name ?? "Nothing yet")
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                if let p = playing {
                    ScreensaverPreviewController.shared.present(
                        preset: p, source: model.library.source, store: model.store)
                }
            } label: {
                Label("Preview", systemImage: "play.fill")
            }
            .glassButton()
            .controlSize(.large)
            .disabled(playing == nil)
            .help("Full-screen preview of what's playing now — move the mouse or press a key to exit")
        }
    }

    private var subtitle: String {
        let n = lineup.playlist.count
        if n <= 1 { return lineup.night == nil ? "Plays all the time" : "Plays by day" }
        return lineup.night == nil ? "Now playing · one of \(n) styles" : "Now playing · \(n) styles by day"
    }

    // MARK: Playlist

    private var playlistRow: some View {
        HStack(spacing: 10) {
            PlaylistStack(ids: lineup.playlist, current: state.nowPlaying)
            AddToPlaylistButton(lineup: lineup)
            if lineup.playlist.count == 1 {
                Text("Add styles to rotate between them")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .transition(.opacity)
            }
        }
    }

    private var rotationControls: some View {
        HStack(spacing: 8) {
            Text("Change every").foregroundStyle(.secondary)
            Picker("Interval", selection: Binding(get: { model.rotation.intervalMinutes },
                                                  set: { model.setRotationInterval($0) })) {
                ForEach(intervalOptions, id: \.self) { m in Text(intervalLabel(m)).tag(m) }
            }
            .labelsHidden()
            .fixedSize()
            Text("·").foregroundStyle(.tertiary)
            Toggle(isOn: Binding(get: { model.rotation.shuffle }, set: { model.setShuffle($0) })) {
                Label("Shuffle", systemImage: "shuffle")
            }
            .toggleStyle(.button)
            .help("Play the playlist in a random order")
        }
        .font(.callout)
        .controlSize(.small)
    }

    private var intervalOptions: [Double] {
        var opts: [Double] = [1, 5, 15, 30, 60]
        let cur = model.rotation.intervalMinutes
        if !opts.contains(cur) { opts.append(cur); opts.sort() }
        return opts
    }

    private func intervalLabel(_ m: Double) -> String {
        if m >= 60, m.truncatingRemainder(dividingBy: 60) == 0 {
            return m == 60 ? "hour" : "\(Int(m / 60)) hours"
        }
        if m < 1 { return "\(Int(m * 60)) sec" }
        return m == 1 ? "minute" : "\(Int(m)) min"
    }

    // MARK: Night

    private var nightRow: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { lineup.night != nil },
                                 set: { on in Motion.run { model.setNightEnabled(on) } })) {
                Label("Different style at night", systemImage: "moon.stars")
                    .font(.callout)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if let nightID = lineup.night, let night = model.preset(nightID) {
                StylePickerMenu(current: night, title: night.name) { model.setNight($0) }
                    .transition(.lift(reduceMotion: reduceMotion))
                Text(model.isNightNow ? "Playing now" : "After sunset")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 10)
        .overlay(alignment: .top) {
            Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
        }
    }
}

/// Green / orange / grey dot + word for the screensaver's install state.
struct StatusDot: View {
    let status: Installer.Status

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.6), radius: 3)
            Text(text).font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        switch status {
        case .ready: return .green
        case .notChosen: return .orange
        case .notInstalled: return .secondary
        }
    }

    private var text: String {
        switch status {
        case .ready: return "On"
        case .notChosen: return "Not selected"
        case .notInstalled: return "Not installed"
        }
    }
}

/// Folded-in setup step, at the foot of the Screensaver card until it's on.
struct SetupStrip: View {
    @EnvironmentObject var model: AppModel
    let status: Installer.Status

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: status == .notInstalled ? "arrow.down.circle.fill" : "hand.point.up.left.fill")
                .font(.system(size: 20))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(status == .notInstalled ? "Install the screensaver to start playing"
                                             : "One more step: choose DotStudio in System Settings")
                    .font(.callout.weight(.semibold))
                Text(status == .notInstalled
                     ? "It's added to your Mac once — after that, everything is controlled from here."
                     : "Wallpaper ▸ Screen Saver ▸ DotStudio. Repeat for each display you want it on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if status == .notInstalled {
                Button("Install") { model.installScreensaver() }
                    .glassButton(.prominent)
                    .controlSize(.large)
            } else {
                Button("Open Settings") { Installer.openScreenSaverSettings() }
                    .glassButton(.prominent)
                    .controlSize(.large)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.accentColor.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(0.22)))
    }
}

// MARK: - Playlist stack

/// The playlist as a small deck of thumbnails that fans out on hover.
struct PlaylistStack: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let ids: [UUID]
    let current: UUID?
    @State private var fanned = false

    private let maxShown = 7
    private let size = CGSize(width: 64, height: 40)

    var body: some View {
        let shown = Array(ids.prefix(maxShown))
        let overlap: CGFloat = fanned || shown.count <= 3 ? 6 : -26
        HStack(spacing: overlap) {
            ForEach(Array(shown.enumerated()), id: \.element) { i, id in
                if let p = model.preset(id) {
                    PlaylistChip(preset: p, isCurrent: ids.count > 1 && id == current,
                                 canRemove: ids.count > 1, size: size)
                        .zIndex(Double(shown.count - i))
                        .transition(.lift(reduceMotion: reduceMotion))
                }
            }
            if ids.count > maxShown {
                Text("+\(ids.count - maxShown)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(height: size.height)
                    .padding(.horizontal, 10)
                    .glassSurface(.regular, in: Capsule())
                    .padding(.leading, fanned ? 0 : 30)
            }
        }
        .padding(.vertical, 2)
        .onHover { h in fanned = h }
        .motion(Motion.smooth, value: fanned)
        .motion(Motion.smooth, value: ids)
    }
}

private struct PlaylistChip: View {
    @EnvironmentObject var model: AppModel
    let preset: Preset
    let isCurrent: Bool
    let canRemove: Bool
    let size: CGSize
    @State private var hovering = false

    var body: some View {
        StyleThumb(preset: preset)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isCurrent ? Color.accentColor : Color.white.opacity(0.55),
                              lineWidth: isCurrent ? 2 : 1))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .overlay(alignment: .topTrailing) {
                if hovering && canRemove {
                    Button { Motion.run { model.removeFromPlaylist(preset.id) } } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 5, y: -5)
                    .help("Remove from Screensaver")
                    .transition(.opacity)
                }
            }
            .scaleEffect(hovering ? 1.06 : 1)
            .onHover { hovering = $0 }
            .motion(Motion.snappy, value: hovering)
            .onTapGesture(count: 2) { model.edit(preset.id) }
            .onTapGesture { model.selectedID = preset.id }
            .help(preset.name)
            .contextMenu {
                Button("Play Only This") { Motion.run { model.playAsScreensaver(preset.id) } }
                Button("Remove from Screensaver") { Motion.run { model.removeFromPlaylist(preset.id) } }
                    .disabled(!canRemove)
                Divider()
                Button("Edit") { model.edit(preset.id) }
            }
    }
}

/// "+" — a popover to tick styles in and out of the playlist.
private struct AddToPlaylistButton: View {
    @EnvironmentObject var model: AppModel
    let lineup: ScreensaverLineup
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .glassSurface(.regular, in: Circle(), interactive: true)
        .help("Choose which styles the screensaver plays")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            PlaylistEditor()
        }
    }
}

/// Multi-select of every style, grouped Scenes / Looks.
struct PlaylistEditor: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""

    var body: some View {
        let lineup = model.screensaverLineup
        let q = query.lowercased()
        let presets = model.library.presets.filter { q.isEmpty || StyleMatcher.searchText(for: $0).contains(q) }
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Screensaver Playlist").font(.headline)
                Text(lineup.rotates ? "\(lineup.playlist.count) styles take turns." : "One style plays. Tick more to rotate.")
                    .font(.caption).foregroundStyle(.secondary)
                SearchField(text: $query, prompt: "Filter styles")
            }
            .padding(14)
            Divider()
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 12) {
                    ForEach(presets) { p in
                        let on = lineup.playlist.contains(p.id)
                        Button {
                            Motion.run { on ? model.removeFromPlaylist(p.id) : model.addToPlaylist(p.id) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                StyleThumb(preset: p)
                                    .aspectRatio(16.0 / 10.0, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(on ? Color.accentColor : .primary.opacity(0.1), lineWidth: on ? 2.5 : 1))
                                    .overlay(alignment: .topTrailing) {
                                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, on ? Color.accentColor : .black.opacity(0.35))
                                            .font(.system(size: 15))
                                            .shadow(radius: 2)
                                            .padding(5)
                                    }
                                Text(p.name).font(.caption).lineLimit(1)
                                    .foregroundStyle(on ? .primary : .secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(on && lineup.playlist.count == 1)
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 420, height: 460)
    }
}

/// A compact menu button showing a style's thumbnail + name, listing every style.
struct StylePickerMenu: View {
    @EnvironmentObject var model: AppModel
    let current: Preset?
    let title: String
    let onPick: (UUID) -> Void

    var body: some View {
        Menu {
            let scenes = model.library.presets.filter(\.isScene)
            let looks = model.library.presets.filter { !$0.isScene }
            Section("Scenes") { ForEach(scenes) { p in item(p) } }
            Section("Looks") { ForEach(looks) { p in item(p) } }
        } label: {
            HStack(spacing: 7) {
                if let current {
                    StyleThumb(preset: current)
                        .frame(width: 30, height: 19)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                Text(title).lineLimit(1)
            }
        }
        .menuStyle(.button)
        .glassButton()
        .controlSize(.small)
        .fixedSize()
    }

    @ViewBuilder private func item(_ p: Preset) -> some View {
        Button {
            Motion.run { onPick(p.id) }
        } label: {
            if p.id == current?.id { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
        }
    }
}

// MARK: - Wallpaper

struct WallpaperCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var slot = WallpaperSlot.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: GalleryState

    private var style: Preset? { slot.styleID.flatMap(model.preset) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("WALLPAPER")
                    .font(.caption.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    Circle().fill(style != nil ? Color.green : Color.secondary.opacity(0.6))
                        .frame(width: 7, height: 7)
                    Text(style != nil ? "Live" : "Off")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                Spacer()
            }

            ZStack {
                if let style {
                    StyleThumb(preset: style)
                        .transition(.opacity)
                } else {
                    DesktopGlyph()
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 92)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.08)))

            VStack(alignment: .leading, spacing: 2) {
                Text(style?.name ?? "Your desktop, alive")
                    .font(.headline)
                    .lineLimit(1)
                Text(style != nil ? "Playing behind your windows" : "Play any style behind your windows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                StylePickerMenu(current: style, title: style == nil ? "Choose Style" : "Change") { slot.set($0) }
                if style != nil {
                    Button("Stop") { Motion.run { slot.stop() } }
                        .glassButton()
                        .controlSize(.small)
                        .transition(.lift(reduceMotion: reduceMotion))
                }
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 26)
        .motion(Motion.smooth, value: slot.styleID)
    }
}

/// A tiny drawn desktop: menu bar, dock, a soft gradient — the "off" state.
private struct DesktopGlyph: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.accentColor.opacity(0.28), Color.purple.opacity(0.18), Color.orange.opacity(0.14)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 0) {
                Rectangle().fill(.primary.opacity(0.10)).frame(height: 7)
                Spacer()
                Capsule().fill(.primary.opacity(0.10)).frame(width: 96, height: 12).padding(.bottom, 8)
            }
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Shared bits

/// A style's cached thumbnail (black until it renders).
struct StyleThumb: View {
    @EnvironmentObject var model: AppModel
    let preset: Preset

    var body: some View {
        // Takes exactly the size it's offered; the image fills it and is clipped, so a
        // thumbnail never pushes its container's layout around.
        Color.black
            .overlay {
                if let img = model.thumbnailer.image(for: preset, source: model.library.source) {
                    Image(nsImage: img).resizable().scaledToFill()
                }
            }
            .clipped()
    }
}

/// Inline glass search field.
struct SearchField: View {
    @Binding var text: String
    var prompt = "Search"
    var focus: FocusState<Bool>.Binding? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            field
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .glassSurface(.regular, in: Capsule())
    }

    @ViewBuilder private var field: some View {
        if let focus {
            TextField(prompt, text: $text).textFieldStyle(.plain).focused(focus)
        } else {
            TextField(prompt, text: $text).textFieldStyle(.plain)
        }
    }
}

/// The blurred, color-washed backdrop behind the gallery and editor.
struct AmbientBackdrop: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    let presetID: UUID?

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if let p = presetID.flatMap(model.preset),
               let img = model.thumbnailer.image(for: p, source: model.library.source) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 70, opaque: true)
                    .saturation(1.35)
                    .opacity(scheme == .dark ? 0.8 : 0.6)
                    .id(p.id)
                    .transition(.opacity)
            }
            // Keep the top calm under the toolbar and fade the wash out down the page.
            LinearGradient(stops: [
                .init(color: Color(nsColor: .windowBackgroundColor).opacity(0.05), location: 0),
                .init(color: Color(nsColor: .windowBackgroundColor).opacity(scheme == .dark ? 0.45 : 0.5), location: 0.45),
                .init(color: Color(nsColor: .windowBackgroundColor).opacity(0.88), location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 0.6), value: presetID)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
