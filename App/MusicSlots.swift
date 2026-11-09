//  MusicSlots.swift — where the music feature plugs into the app's chrome (the call sites
//  place these types; MusicUI.swift has the model and the shared pieces).
//
//  ┌ MUSIC SLOT: menu bar ─────────────────────────────────────────────────────────────────┐
//  │ MenuBarMusicSlot — the TOP of the DotStudio menu-bar menu (MenuBarMenu.swift,          │
//  │ DotStudioMenu): the current track as a disabled line with its cover ("Song — Artist", │
//  │ one line, each part shortened on its own — menuTrackLine),                            │
//  │ Play/Pause (Space), Previous, Next, and — when the player refused Automation — the     │
//  │ controls disabled plus "Allow DotStudio to Control <app>…"; then a Divider. While      │
//  │ nothing is playing (or lingering paused) it renders nothing, not even the divider.    │
//  │ Real menus can't scale text; UIShots renders it as a column (MenuPreview).            │
//  └───────────────────────────────────────────────────────────────────────────────────────┘
//  ┌ MUSIC SLOT: Settings ─────────────────────────────────────────────────────────────────┐
//  │ MusicSettingsSlot — the Music section, right after Settings › General: each player's  │
//  │ status and permission (with its fix-it), what's playing with controls, Show music     │
//  │ (Off / Corner / Full Screen) and that mode's options — corner + size, or what's       │
//  │ layout (Album/Stage/Cover miniatures) + behind the music — then, while music shows,   │
//  │ also on the wallpaper,                                                                 │
//  │ the paused linger and the source; the privacy note. As WallpaperSettingsSection.      │
//  └───────────────────────────────────────────────────────────────────────────────────────┘

import SwiftUI

// MARK: - Menu bar

/// MUSIC SLOT (menu bar): track + Play/Pause, Previous, Next, then its own Divider().
struct MenuBarMusicSlot: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var now = MusicNow.shared

    var body: some View {
        let _ = Perf.body("MenuBarMusicSlot")
        if now.isVisible(model.library.musicSettings) {
            Label {
                Text(menuTrackLine(title: now.title, artist: now.artist))
            } icon: {
                if let art = MenuArt.image(now.artwork, palette: now.state.palette ?? []) {
                    Image(nsImage: art)
                } else {
                    Image(systemName: "music.note")
                }
            }
            Button(now.isPlaying ? "Pause" : "Play") { now.playPause() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!now.canControl)
            Button("Previous") { now.previous() }
                .disabled(!now.canControl)
            Button("Next") { now.next() }
                .disabled(!now.canControl)
            if now.needsAutomationFix, let source = now.source {
                Button("Allow DotStudio to Control \(source.displayName)\u{2026}") { now.allowControl(source) }
            }
            Divider()
        }
    }
}

/// "Song — Artist" short enough for one menu line (real menu items never wrap). Each part is
/// shortened on its own, from its end, so the separator and the start of the artist's name
/// always survive (menuName's middle cut would run the song into the artist's last word).
func menuTrackLine(title: String, artist: String, limit: Int = 40) -> String {
    func clip(_ s: String, _ n: Int) -> String {
        guard s.count > n else { return s }
        var head = String(s.prefix(max(n - 1, 1)))
        // End on a whole word when one ends close enough, never on a dangling "&" or "(".
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) >= n * 3 / 5 {
            head = String(head[..<space])
        }
        let dangling = CharacterSet.whitespaces.union(.punctuationCharacters).union(.symbols)
        while let last = head.unicodeScalars.last, dangling.contains(last), head.count > 1 { head.removeLast() }
        return head + "\u{2026}"
    }
    guard !artist.isEmpty else { return clip(title, limit) }
    let room = limit - 3                                    // " — "
    guard title.count + artist.count > room else { return "\(title) \u{2014} \(artist)" }
    // The artist keeps up to 16 characters (more beside a short title); the song gets the rest.
    let a = clip(artist, max(16, room - title.count))
    let t = clip(title, max(12, room - a.count))
    return "\(t) \u{2014} \(a)"
}

/// The cover as a menu item's image: a small rounded square at the menu's icon size (menu
/// items draw their image at its own size). Cached for the current cover.
enum MenuArt {
    static let side: CGFloat = 18
    private static var last: (art: CGImage, image: NSImage)?

    static func image(_ art: CGImage?, palette: [RGBA]) -> NSImage? {
        guard let art else { return nil }
        if let last, last.art === art { return last.image }
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: 3.5, yRadius: 3.5)
            path.addClip()
            NSGraphicsContext.current?.imageInterpolation = .high
            NSImage(cgImage: art, size: .zero).draw(in: rect)
            NSColor.black.withAlphaComponent(0.12).setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
        last = (art, img)
        return img
    }
}

// MARK: - Settings

/// MUSIC SLOT (Settings): the Music section, after General.
struct MusicSettingsSlot: View {
    var body: some View { MusicSettingsSection() }
}

struct MusicSettingsSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var now = MusicNow.shared
    @ObservedObject private var presence = AppPresence.shared
    @ScaledLength(relativeTo: .body) private var segmentWidth: CGFloat = SettingsMetrics.segmentWidth

    private var spec: MusicSpec { model.library.musicSettings }

    var body: some View {
        let spec = self.spec
        let showsTrack = now.isVisible(spec)
        Section {
            if now.isMonitoring {
                // The song itself is on the row below while it shows; the player rows say only
                // what each player is doing.
                MusicPlayerRow(status: now.spotify, now: now, showsTrack: !showsTrack)
                MusicPlayerRow(status: now.music, now: now, showsTrack: !showsTrack)
            } else {
                Text("DotStudio isn't watching Spotify or Apple Music right now — choose Corner or Full Screen below.")
                    .textRole(.caption)
                    .foregroundStyle(.secondary)
                    .wrapping()
            }
            if showsTrack {
                MusicSettingsNowPlaying(now: now)
            }
            // "Show music", then only the options of the mode picked.
            SettingsValueRow("Show music", valueWidth: segmentWidth) {
                ScaledSegmentedPicker(title: "Show music", selection: binding(\.displayMode) { $0.setDisplay($1) },
                                      options: MusicSpec.Display.allCases.map { ($0.label, $0) }, fills: true)
            }
            if spec.displayMode == .corner {
                LabeledContent("Corner") {
                    SettingsPopUp(title: "Corner", selection: binding(\.corner) { $0.cardCorner = $1 },
                                  options: MusicSpec.Corner.allCases.map { ($0.label, $0) })
                }
                SettingsValueRow("Size", valueWidth: segmentWidth) {
                    ScaledSegmentedPicker(title: "Size", selection: binding(\.cardSizePreference) { $0.cardSize = $1 },
                                          options: MusicSpec.CardSize.allCases.map { ($0.label, $0) }, fills: true)
                }
            }
            if spec.displayMode == .fullScreen {
                // The layout as small pictures of the screen (they show the backdrop picked
                // below); Cover is the artwork itself, so "Behind the music" leaves with it.
                SettingsValueRow("Layout", valueWidth: segmentWidth) {
                    MusicLayoutChoice(selection: binding(\.layout) { $0.fullLayout = $1 }, backdrop: spec.backdrop)
                }
                if spec.layout.usesBackdrop {
                    SettingsValueRow("Behind the music", valueWidth: segmentWidth) {
                        ScaledSegmentedPicker(title: "Behind the music", selection: binding(\.backdrop) { $0.fullBackdrop = $1 },
                                              options: MusicSpec.Backdrop.allCases.map { ($0.label, $0) }, fills: true)
                    }
                }
            }
            if spec.displayMode != .off {
                // Reads off (and is off — MusicSpec.drawsOnWallpaper) only with Show music off,
                // where it's hidden; the stored choice comes back with music.
                Toggle("Also on the live wallpaper", isOn: binding(\.drawsOnWallpaper) { $0.cardOnWallpaper = $1 })
                    .formSwitchSize()
                LabeledContent("Keep a paused song for") {
                    SettingsPopUp(title: "Keep a paused song for", selection: binding(\.linger) { $0.lingerMinutes = $1 },
                                  options: lingerOptions(spec.linger).map { (Self.lingerLabel($0), $0) })
                }
                SettingsValueRow("Source", valueWidth: segmentWidth) {
                    ScaledSegmentedPicker(title: "Source", selection: binding(\.sourcePreference) { $0.source = $1 },
                                          options: MusicSpec.SourcePreference.allCases.map { ($0.label, $0) }, fills: true)
                }
            }
            // The same switch as General's: the screensaver only knows what's playing while
            // DotStudio runs.
            Toggle("Keep running in the menu bar", isOn: $presence.menuBarMode)
                .formSwitchSize()
        } header: {
            SettingsHeader("Music")
        } footer: {
            VStack(alignment: .leading, spacing: Space.xs) {
                SettingsNote("While a song plays in Spotify or Apple Music, the screensaver shows it over whatever style is playing — in a corner, or full screen: over the album's living art or your screensaver, softly blurred, or on the cover itself. When the music stops, the screensaver is all that's left.")
                // What closing the window does (AppPresence.windowClosed), as General says.
                SettingsNote(presence.menuBarMode
                    ? "DotStudio has to be running to know what's playing — closing its window keeps it in the menu bar."
                    : "DotStudio has to be running to know what's playing. With Keep running in the menu bar off, closing its window quits DotStudio — unless a live wallpaper is playing — and the screensaver stops showing what's playing.")
                SettingsNote("Song details come from the players on this Mac. When a player doesn't hand over the cover, DotStudio looks it up in Spotify's or Apple's public catalog — only the song's ID, or its artist and album, is sent.")
            }
        }
        .onAppear { now.refreshAutomation() }
    }

    /// A binding to one music setting: reads the resolved value, writes the stored field.
    private func binding<V>(_ get: KeyPath<MusicSpec, V>, _ set: @escaping (inout MusicSpec, V) -> Void) -> Binding<V> {
        Binding(get: { model.library.musicSettings[keyPath: get] },
                set: { v in
                    var m = model.library.musicSettings
                    set(&m, v)
                    guard m != model.library.music else { return }
                    model.library.music = m
                    model.save()
                })
    }

    private func lingerOptions(_ current: Double) -> [Double] {
        var opts: [Double] = [1, 5, 15]
        if !opts.contains(current) { opts.append(current); opts.sort() }
        return opts
    }

    static func lingerLabel(_ m: Double) -> String {
        if m < 1 { return "\(Int((m * 60).rounded())) seconds" }
        let n = Int(m.rounded())
        return n == 1 ? "1 minute" : "\(n) minutes"
    }
}

/// Full Screen's layouts as labelled miniatures of the screen — Album (art left, type right),
/// Stage (art centred, type below), Cover (the art fills it, type bottom-left) — drawn over the
/// backdrop "Behind the music" picks, so the pair reads as the screen you'll get. Equal columns
/// across the value column; the selected one gets an accent ring and a semibold label.
private struct MusicLayoutChoice: View {
    @Binding var selection: MusicSpec.FullLayout
    let backdrop: MusicSpec.Backdrop
    @Environment(\.layout) private var layout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: layout.controlGap) {
            ForEach(MusicSpec.FullLayout.allCases) { option in
                cell(option)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? Motion.reduced : Motion.snappy, value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Layout")
    }

    private func cell(_ option: MusicSpec.FullLayout) -> some View {
        let isOn = option == selection
        let shape = RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
        return Button { selection = option } label: {
            VStack(spacing: layout.labelGap) {
                MusicLayoutMiniature(layout: option, backdrop: backdrop)
                    .aspectRatio(16.0 / 10.0, contentMode: .fit)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Color.primary.opacity(0.12)))
                    .padding(3)
                    .overlay(RoundedRectangle(cornerRadius: Radius.concentric(Radius.s, inset: -3), style: .continuous)
                        .strokeBorder(isOn ? Color.accentColor : .clear, lineWidth: 2))
                // The semibold copy (hidden) sizes every label, so picking one never re-wraps it.
                ZStack {
                    Text(option.label).textRole(.calloutEmphasis).hidden()
                    Text(option.label).textRole(isOn ? .calloutEmphasis : .callout)
                        .foregroundStyle(isOn ? .primary : .secondary)
                }
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Self.help(option))
        .accessibilityLabel(option.label)
        .accessibilityHint(Self.help(option))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private static func help(_ option: MusicSpec.FullLayout) -> String {
        switch option {
        case .album: return "Album — the cover on the left, the song in big type beside it"
        case .stage: return "Stage — the cover in the middle, the song centred under it"
        case .cover: return "Cover — the cover fills the screen, the song at the bottom left"
        }
    }
}

/// A schematic of one Full Screen layout: the backdrop, the artwork and three lines of type
/// (title, artist, progress), in the proportions MusicOverlayLayer uses.
private struct MusicLayoutMiniature: View {
    let layout: MusicSpec.FullLayout
    let backdrop: MusicSpec.Backdrop

    /// A stand-in cover: warm, with a bright corner, like most album art.
    private static let art = LinearGradient(colors: [Color(red: 0.98, green: 0.62, blue: 0.36),
                                                     Color(red: 0.78, green: 0.27, blue: 0.48),
                                                     Color(red: 0.32, green: 0.18, blue: 0.52)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing)
    /// Living art: the cover's colours as soft fields.
    private static let livingArt = LinearGradient(colors: [Color(red: 0.55, green: 0.24, blue: 0.40),
                                                           Color(red: 0.26, green: 0.14, blue: 0.36),
                                                           Color(red: 0.62, green: 0.34, blue: 0.24)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing)
    /// The screensaver, blurred and dimmed: cool and quiet.
    private static let veil = LinearGradient(colors: [Color(red: 0.20, green: 0.27, blue: 0.33),
                                                      Color(red: 0.10, green: 0.12, blue: 0.16)],
                                             startPoint: .top, endPoint: .bottom)

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .topLeading) {
                background(w, h)
                switch layout {
                case .album:
                    let s = h * 0.5
                    artTile(s).offset(x: w * 0.14, y: (h - s) / 2)
                    lines(width: w * 0.36, scale: h).offset(x: w * 0.14 + s + w * 0.07, y: h * 0.36)
                case .stage:
                    let s = h * 0.42
                    artTile(s).offset(x: (w - s) / 2, y: h * 0.12)
                    lines(width: w * 0.36, scale: h, centred: true).offset(x: w * 0.32, y: h * 0.12 + s + h * 0.07)
                case .cover:
                    lines(width: w * 0.4, scale: h).offset(x: w * 0.08, y: h * 0.58)
                }
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private func background(_ w: CGFloat, _ h: CGFloat) -> some View {
        if layout == .cover {
            ZStack {
                Self.art
                // The shader's scrim under the type.
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            }
        } else if backdrop == .albumArt {
            ZStack {
                Self.livingArt
                Circle().fill(Color(red: 0.95, green: 0.55, blue: 0.35).opacity(0.45))
                    .frame(width: h * 0.9).blur(radius: h * 0.18).offset(x: w * 0.45, y: -h * 0.2)
            }
        } else {
            ZStack {
                Self.veil
                // A hint of the style behind, softly blurred.
                Circle().fill(Color(red: 0.55, green: 0.70, blue: 0.80).opacity(0.25))
                    .frame(width: h * 0.7).blur(radius: h * 0.16).offset(x: -w * 0.1, y: h * 0.35)
            }
        }
    }

    private func artTile(_ s: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: s * 0.08, style: .continuous)
            .fill(Self.art)
            .frame(width: s, height: s)
            .shadow(color: .black.opacity(0.35), radius: s * 0.08, y: s * 0.04)
    }

    /// Title, artist and a progress bar, as white bars.
    private func lines(width: CGFloat, scale h: CGFloat, centred: Bool = false) -> some View {
        VStack(alignment: centred ? .center : .leading, spacing: h * 0.045) {
            Capsule().fill(.white.opacity(0.95)).frame(width: width * 0.8, height: h * 0.07)
            Capsule().fill(.white.opacity(0.7)).frame(width: width * 0.55, height: h * 0.045)
            Capsule().fill(.white.opacity(0.45)).frame(width: width, height: h * 0.02)
                .padding(.top, h * 0.03)
        }
        .frame(width: width, alignment: centred ? .center : .leading)
    }
}

/// One player's line: its icon and name, what it's doing, and whether DotStudio may control
/// it — with the fix-it when it may not. The permission moves under the status when the row
/// runs out of room (large text, a long song name).
struct MusicPlayerRow: View {
    @Environment(\.layout) private var layout
    let status: MusicPlayerStatus
    @ObservedObject var now: MusicNow
    /// Name the song in the status — off while Settings shows it on its own row.
    var showsTrack = true

    var body: some View {
        ReflowStack(rowAlignment: .center, columnAlignment: .trailing, spacing: layout.itemGap) {
            HStack(alignment: .center, spacing: layout.iconGap) {
                MusicAppIcon(source: status.source)
                VStack(alignment: .leading, spacing: layout.labelGap) {
                    Text(status.source.displayName)
                        .textRole(.bodyEmphasis)
                    Text(detail)
                        .textRole(.caption)
                        .foregroundStyle(.secondary)
                        .truncating(detail, lines: 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            permission
        }
        .accessibilityElement(children: .contain)
    }

    private var detail: String {
        if !status.isInstalled { return "Not installed" }
        if !status.isRunning { return "Not open" }
        let isShown = showsTrack && now.source == status.source && now.state.hasTrack
        if status.isPlaying {
            return isShown ? "Playing \u{201C}\(now.title)\u{201D}" + (now.artist.isEmpty ? "" : " \u{2014} \(now.artist)") : "Playing"
        }
        if status.hasTrack {
            return isShown ? "Paused \u{00B7} \u{201C}\(now.title)\u{201D}" : "Paused"
        }
        return "Open \u{00B7} nothing playing"
    }

    @ViewBuilder private var permission: some View {
        if status.isRunning {
            switch status.automation {
            case .allowed:
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .textRole(.caption)
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .fixedSize()
                    .help("DotStudio can read exact progress and artwork, and play or pause \(status.source.displayName).")
            case .denied:
                HStack(spacing: layout.controlGap) {
                    Label("Needs permission", systemImage: "exclamationmark.triangle.fill")
                        .textRole(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .fixedSize()
                    Button(scaled: "Allow\u{2026}") { now.allowControl(status.source) }
                        .help("Opens System Settings › Privacy & Security › Automation — turn on \(status.source.automationName) under DotStudio.")
                }
            case .notDetermined:
                Button(scaled: "Allow\u{2026}") { now.allowControl(status.source) }
                    .help("Lets DotStudio read exact progress and artwork, and play or pause \(status.source.displayName). macOS asks once.")
            case .unknown:
                EmptyView()
            }
        }
    }
}

/// What's playing, with its cover and the controls — in Settings while a song shows.
private struct MusicSettingsNowPlaying: View {
    @Environment(\.layout) private var layout
    @ObservedObject var now: MusicNow
    @ScaledLength(relativeTo: .body) private var art: CGFloat = 40

    var body: some View {
        ReflowStack(rowAlignment: .center, columnAlignment: .trailing, spacing: layout.itemGap) {
            HStack(alignment: .center, spacing: layout.iconGap) {
                MusicArtThumb(image: now.artwork, palette: now.state.palette ?? [], side: art)
                VStack(alignment: .leading, spacing: layout.labelGap) {
                    Text(now.title)
                        .textRole(.bodyEmphasis)
                        .truncating(now.title)
                    let sub = [now.artist, now.isPlaying ? now.sourceName : "Paused"].filter { !$0.isEmpty }
                        .joined(separator: " \u{00B7} ")
                    Text(sub)
                        .textRole(.caption)
                        .foregroundStyle(.secondary)
                        .truncating(sub)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MusicTransport(now: now, glass: false)
                .adaptiveControlSize(.regular)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now playing")
    }
}

/// A player's own app icon (read from disk; the app is never launched), or a note glyph.
struct MusicAppIcon: View {
    let source: MusicSource
    @ScaledLength(relativeTo: .body) private var side: CGFloat = 24

    var body: some View {
        Group {
            if let img = Self.icon(source) {
                Image(nsImage: img).resizable().interpolation(.high)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: side * 0.6))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    private static var cache: [MusicSource: NSImage] = [:]

    static func icon(_ source: MusicSource) -> NSImage? {
        if let hit = cache[source] { return hit }
        guard let id = source.bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        cache[source] = img
        return img
    }
}

/// A Settings pop-up: the stock pop-up while its 13-pt title matches the row labels; from
/// .xxLarge a pull-down whose title follows the text size (as the wallpaper's Style row).
struct SettingsPopUp<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(title: String, value: Value)]
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize < SettingsMetrics.scaledControlsFrom {
            picker.labelsHidden().fixedSize()
        } else {
            Menu {
                picker.pickerStyle(.inline).labelsHidden()
            } label: {
                Text(options.first { $0.value == selection }?.title ?? "")
                    .textRole(.body)
                    .lineLimit(1)
            }
            .menuStyle(.button)
            .fixedSize()
        }
    }

    private var picker: some View {
        Picker(title, selection: $selection) {
            ForEach(options.indices, id: \.self) { i in Text(options[i].title).tag(options[i].value) }
        }
    }
}
