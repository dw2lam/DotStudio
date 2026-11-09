//  MusicSlots.swift — where the music feature plugs into the app's chrome (the call sites
//  place these types; MusicUI.swift has the model and the shared pieces).
//
//  ┌ MUSIC SLOT: menu bar ─────────────────────────────────────────────────────────────────┐
//  │ MenuBarMusicSlot — the TOP of the DotStudio menu-bar menu (MenuBarMenu.swift,          │
//  │ DotStudioMenu): the current track as a disabled line ("Song — Artist", one line),     │
//  │ Play/Pause (Space), Previous, Next, and — when the player refused Automation — the     │
//  │ controls disabled plus "Allow DotStudio to Control <app>…"; then a Divider. While      │
//  │ nothing is playing (or lingering paused) it renders nothing, not even the divider.    │
//  │ Real menus can't scale text; UIShots renders it as a column (MenuPreview).            │
//  └───────────────────────────────────────────────────────────────────────────────────────┘
//  ┌ MUSIC SLOT: Settings ─────────────────────────────────────────────────────────────────┐
//  │ MusicSettingsSlot — the Music section, right after Settings › General: each player's  │
//  │ status and permission (with its fix-it), what's playing with controls, the card       │
//  │ (on / corner / size / also on the wallpaper), take-over, the paused linger, the       │
//  │ source, and the privacy note. Same pieces as WallpaperSettingsSection.               │
//  └───────────────────────────────────────────────────────────────────────────────────────┘

import SwiftUI

// MARK: - Menu bar

/// MUSIC SLOT (menu bar): track + Play/Pause, Previous, Next, then its own Divider().
struct MenuBarMusicSlot: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var now = MusicNow.shared

    var body: some View {
        if now.isVisible(model.library.musicSettings) {
            Text(menuName(now.trackLine))
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

// MARK: - Settings

/// MUSIC SLOT (Settings): the Music section, after General.
struct MusicSettingsSlot: View {
    var body: some View { MusicSettingsSection() }
}

struct MusicSettingsSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var now = MusicNow.shared
    @ScaledLength(relativeTo: .body) private var segmentWidth: CGFloat = SettingsMetrics.segmentWidth

    private var spec: MusicSpec { model.library.musicSettings }

    var body: some View {
        let spec = self.spec
        Section {
            if now.isMonitoring {
                MusicPlayerRow(status: now.spotify, now: now)
                MusicPlayerRow(status: now.music, now: now)
            } else {
                Text("DotStudio isn't watching Spotify or Music right now — turn on an option below.")
                    .textRole(.caption)
                    .foregroundStyle(.secondary)
                    .wrapping()
            }
            if now.isVisible(spec) {
                MusicSettingsNowPlaying(now: now)
            }
            Toggle("Show what's playing on the screensaver", isOn: binding(\.isCardEnabled) { $0.cardEnabled = $1 })
                .formSwitchSize()
            LabeledContent("Corner") {
                SettingsPopUp(title: "Corner", selection: binding(\.corner) { $0.cardCorner = $1 },
                              options: MusicSpec.Corner.allCases.map { ($0.label, $0) })
            }
            .disabled(!spec.isCardEnabled)
            SettingsValueRow("Card Size", valueWidth: segmentWidth) {
                ScaledSegmentedPicker(title: "Card Size", selection: binding(\.cardSizePreference) { $0.cardSize = $1 },
                                      options: MusicSpec.CardSize.allCases.map { ($0.label, $0) }, fills: true)
            }
            .disabled(!spec.isCardEnabled)
            Toggle("Also on the live wallpaper", isOn: binding(\.showsCardOnWallpaper) { $0.cardOnWallpaper = $1 })
                .formSwitchSize()
                .disabled(!spec.isCardEnabled)
            Toggle("Switch to Now Playing while music plays", isOn: binding(\.takesOver) { $0.takeOver = $1 })
                .formSwitchSize()
            LabeledContent("Keep a paused song for") {
                SettingsPopUp(title: "Keep a paused song for", selection: binding(\.linger) { $0.lingerMinutes = $1 },
                              options: lingerOptions(spec.linger).map { (Self.lingerLabel($0), $0) })
            }
            SettingsValueRow("Source", valueWidth: segmentWidth) {
                ScaledSegmentedPicker(title: "Source", selection: binding(\.sourcePreference) { $0.source = $1 },
                                      options: MusicSpec.SourcePreference.allCases.map { ($0.label, $0) }, fills: true)
            }
        } header: {
            SettingsHeader("Music")
        } footer: {
            VStack(alignment: .leading, spacing: Space.xs) {
                SettingsNote("While a song plays in Spotify or Music, the screensaver shows it in a corner card, and the Now Playing style shows it full screen. DotStudio has to be running to know what's playing — closing its window keeps it in the menu bar.")
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

/// One player's line: its icon and name, what it's doing, and whether DotStudio may control
/// it — with the fix-it when it may not. The permission moves under the status when the row
/// runs out of room (large text, a long song name).
struct MusicPlayerRow: View {
    @Environment(\.layout) private var layout
    let status: MusicPlayerStatus
    @ObservedObject var now: MusicNow

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
        let isShown = now.source == status.source && now.state.hasTrack
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
                        .help("Opens System Settings › Privacy & Security › Automation — turn on \(status.source.displayName) under DotStudio.")
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
