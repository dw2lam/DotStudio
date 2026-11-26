//  AppearancePicker.swift — Settings › General › Theme: Classic and Retro as live close-ups
//  built from each theme's real controls, playing on their own (owner, 2026-11-26): Retro's
//  dials turn, a key presses and lets go, a switch flips green, a segment moves along;
//  Classic's switch flips, its slider slides, its filter moves and its button presses
//  (Classic's switch and slider are drawn: AppKit's don't draw true scaled or out of focus). Each
//  fills half the row, in the light or dark the app wears now, with its name under it. The
//  pictures are props: they never take a click (a click anywhere on a card picks its theme),
//  never tick the trackpad, and stand still under Reduce Motion and in offscreen renders.

import SwiftUI
import AppKit

/// Settings › General › Theme: a live close-up of each theme, with its name.
struct ThemePictureChoices: View {
    @Binding var selection: Appearance
    @Environment(\.consoleSettings) private var console
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The demo's clock: every beat moves something. DOTSTUDIO_THEME_DEMO_BEAT starts it on a
    /// given beat (offscreen renders of the later states).
    @State private var beat = Int(ProcessInfo.processInfo.environment["DOTSTUDIO_THEME_DEMO_BEAT"] ?? "") ?? 0
    /// A key's press, held for a moment within a beat.
    @State private var pressing = false

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.m))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Space.m))
        layout {
            ForEach(Appearance.allCases) { theme in
                card(theme)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Theme")
        .task(id: reduceMotion) { await play() }
    }

    /// Advances the demo while the pane is on screen (the task ends with the view).
    private func play() async {
        guard !reduceMotion, !Appearance.isHeadlessRun else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1.3))
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: 0.9)) { beat += 1 }
            if beat % 2 == 1 {
                try? await Task.sleep(for: .seconds(0.35))
                withAnimation(.easeOut(duration: 0.08)) { pressing = true }
                try? await Task.sleep(for: .seconds(0.22))
                withAnimation(.easeOut(duration: 0.12)) { pressing = false }
            }
        }
    }

    private func card(_ theme: Appearance) -> some View {
        let on = theme == selection
        let ring = console ? ConsoleInk.signal : Color.accentColor
        let corner: CGFloat = theme == .console ? 6 : 10
        return VStack(spacing: Space.xs) {
            ThemeStage(theme: theme, beat: beat, pressing: pressing)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: corner + 4, style: .continuous)
                    .strokeBorder(on ? ring : .clear, lineWidth: 3))
            Text(theme.title)
                .settingsText(console ? (on ? .consoleBodySmallEmphasis : .consoleBodySmall)
                                      : (on ? .calloutEmphasis : .callout))
                .foregroundStyle(on ? .primary : .secondary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { selection = theme }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(theme.title)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { selection = theme }
    }
}

/// One theme's close-up: a fixed design canvas of its real controls, scaled to the card's
/// width (16:10), drawn in that theme whatever the app wears.
private struct ThemeStage: View {
    let theme: Appearance
    let beat: Int
    let pressing: Bool
    static let canvas = CGSize(width: 340, height: 212)

    var body: some View {
        Color.clear
            .aspectRatio(Self.canvas.width / Self.canvas.height, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    let k = geo.size.width / Self.canvas.width
                    Group {
                        if theme == .console {
                            RetroStage(beat: beat, pressing: pressing)
                                .environment(\.console, true)
                                .environment(\.consoleSettings, true)
                        } else {
                            ClassicStage(beat: beat, pressing: pressing)
                                .environment(\.console, false)
                                .environment(\.consoleSettings, false)
                        }
                    }
                    .frame(width: Self.canvas.width, height: Self.canvas.height)
                    .scaleEffect(k, anchor: .topLeading)
                }
            }
            .dynamicTypeSize(.large)          // a picture: it keeps its proportions
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Retro

private struct RetroStage: View {
    let beat: Int
    let pressing: Bool
    private static let dialValues: [[Double]] = [[0.35, 0.7, 0.5], [0.8, 0.3, 0.65], [0.15, 0.55, 0.9], [0.6, 0.85, 0.25]]
    private static let modes = ["auto", "light", "dark"]

    var body: some View {
        let v = Self.dialValues[beat % Self.dialValues.count]
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { i in
                    ConsoleKnob(label: ["speed", "glow", "size"][i], value: .constant(v[i]), range: 0...1,
                                defaultValue: 0.5, colorIndex: [0, 1, 3][i],
                                format: { "\(Int(($0 * 100).rounded()))%" })
                }
            }
            HStack(spacing: 10) {
                Button {} label: {
                    Label("preview", systemImage: "play.fill").labelStyle(.titleAndIcon)
                        .textRole(.consoleKey).lineLimit(1).fixedSize()
                }
                .buttonStyle(.keycap(.signal, latched: pressing))
                ConsoleSwitch(isOn: .constant(beat % 4 >= 2))
                ConsoleSegments(title: "Mode", selection: .constant(Self.modes[(beat / 2) % 3]),
                                options: Self.modes.map { ($0, $0) })
            }
        }
        .padding(12)
        .frame(width: ThemeStage.canvas.width, height: ThemeStage.canvas.height)
        .background(ConsoleInk.panel)
    }
}

// MARK: - Classic

private struct ClassicStage: View {
    let beat: Int
    let pressing: Bool
    private static let chips = ["All", "Scenes", "Looks"]
    private static let sliderValues: [Double] = [0.3, 0.75, 0.5, 0.9]

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            // a style card: a picture with its name, the blue Preview on it
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.95, green: 0.66, blue: 0.45),
                                              Color(red: 0.36, green: 0.27, blue: 0.52)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(height: 70)
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Golden Hour").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        Text("Plays all the time").font(.system(size: 11)).foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(10)
                }
                .overlay(alignment: .bottomTrailing) {
                    Label("Preview", systemImage: "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11).padding(.vertical, 5)
                        .background(Capsule().fill(Color.accentColor))
                        .overlay(Capsule().fill(Color.black.opacity(pressing ? 0.2 : 0)))
                        .scaleEffect(pressing ? 0.94 : 1)
                        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                        .padding(10)
                }
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            // the filter chips, the chosen one moving along
            HStack(spacing: 6) {
                ForEach(Self.chips.indices, id: \.self) { i in
                    let on = i == (beat / 2) % Self.chips.count
                    Text(Self.chips[i])
                        .font(.system(size: 12, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(on ? Color.accentColor : Color.primary.opacity(0.07)))
                }
            }
            // a grouped settings box: a switch and a slider, as macOS draws them
            VStack(spacing: 0) {
                HStack {
                    Text("Keep running").font(.system(size: 12))
                    Spacer()
                    ClassicSwitch(isOn: beat % 4 >= 2)
                }
                .padding(.horizontal, 10).frame(height: 30)
                Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5).padding(.leading, 10)
                HStack(spacing: 10) {
                    Text("Speed").font(.system(size: 12))
                    ClassicSlider(value: Self.sliderValues[beat % Self.sliderValues.count])
                }
                .padding(.horizontal, 10).frame(height: 30)
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
        .padding(14)
        .frame(width: ThemeStage.canvas.width, height: ThemeStage.canvas.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The macOS switch, drawn (a picture: an NSSwitch only lights in a key window).
private struct ClassicSwitch: View {
    let isOn: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Capsule()
            .fill(isOn ? Color.accentColor : Color.primary.opacity(scheme == .dark ? 0.25 : 0.12))
            .frame(width: 32, height: 18)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .frame(width: 16, height: 16)
                    .padding(1)
            }
    }
}

/// The macOS slider, drawn (a picture of one — an NSSlider doesn't draw reliably scaled).
private struct ClassicSlider: View {
    let value: Double
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, knob: CGFloat = 16
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(scheme == .dark ? 0.22 : 0.12)).frame(height: 4)
                Capsule().fill(Color.accentColor).frame(width: max(knob / 2, (w - knob) * value + knob / 2), height: 4)
                Circle().fill(scheme == .dark ? Color(white: 0.85) : .white)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
                    .frame(width: knob, height: knob)
                    .offset(x: (w - knob) * value)
            }
            .frame(height: geo.size.height)
        }
        .frame(height: 18)
    }
}
