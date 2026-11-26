//  AppearancePicker.swift — Settings › General's Theme and Mode choices as pictures: each
//  option is a small drawing of the main window in that look, with its name under it (like
//  macOS's own Appearance picker). Drawn, not captured, so they're crisp at any scale and
//  never go stale. Classic and Console both use it; the selection ring follows the theme.

import SwiftUI

/// One look to draw: which theme, light or dark.
private struct Look {
    var theme: Appearance
    var dark: Bool

    // Window palette (fixed colours: a thumbnail shows a look, whatever the app wears now).
    var chassis: Color {
        switch theme {
        case .classic: dark ? Color(white: 0.16) : Color(white: 0.93)
        case .console: dark ? hex(0x131316) : hex(0xEAEAE5)
        }
    }
    var panel: Color {
        switch theme {
        case .classic: dark ? Color(white: 0.23) : .white
        case .console: dark ? hex(0x1B1B1E) : hex(0xF3F3EE)
        }
    }
    var line: Color {
        switch theme {
        case .classic: dark ? Color(white: 1, opacity: 0.1) : Color(white: 0, opacity: 0.08)
        case .console: dark ? hex(0x353438) : hex(0xC8C8C0)
        }
    }
    var ink: Color {
        switch theme {
        case .classic: dark ? Color(white: 0.9) : Color(white: 0.15)
        case .console: dark ? hex(0xE4E1E6) : hex(0x141416)
        }
    }
    var key: Color { dark ? hex(0x2A2A2D) : hex(0xD8D8D1) }
    var accent: Color { theme == .console ? hex(0xFF7300) : Color(red: 0.0, green: 0.48, blue: 1.0) }
    var radius: CGFloat { theme == .console ? 1 : 6 }

    /// The pictures on the decks and tiles: the same few gradients in every look.
    static let pictures: [[Color]] = [
        [hex(0xF3B37A), hex(0x6A4C7D)], [hex(0x8FD3F4), hex(0x3D7A3A)], [hex(0x0B1026), hex(0x3B4BA8)],
        [hex(0xE7D9C4), hex(0xB59B7A)], [hex(0x111111), hex(0x444444)], [hex(0xC9E4FF), hex(0x7FA7D9)],
        [hex(0x2B1B3D), hex(0xD9608F)], [hex(0x1E3B2F), hex(0x7DC48E)],
    ]
}

private func hex(_ v: UInt32) -> Color {
    Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
}

/// A miniature of the main window: title strip, the two decks, a filter row, a grid of tiles.
private struct WindowMiniature: View {
    let look: Look

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let pad = w * 0.05
            let r = look.radius
            ZStack(alignment: .topLeading) {
                look.chassis
                VStack(alignment: .leading, spacing: h * 0.045) {
                    titleStrip(w: w, h: h)
                    HStack(spacing: w * 0.035) {
                        deck(picture: Look.pictures[0], w: w, h: h, r: r, lit: true)
                        deck(picture: Look.pictures[1], w: w, h: h, r: r, lit: false)
                    }
                    if look.theme == .console { filterRow(w: w, h: h) }
                    tiles(w: w, h: h, r: r)
                }
                .padding(.horizontal, pad)
                .padding(.top, h * 0.05)
            }
        }
        .accessibilityHidden(true)
    }

    private func titleStrip(w: CGFloat, h: CGFloat) -> some View {
        HStack(spacing: w * 0.02) {
            ForEach(0..<3, id: \.self) { _ in
                Circle().fill(look.line).frame(width: w * 0.028, height: w * 0.028)
            }
            if look.theme == .console {
                Circle().fill(look.accent).frame(width: w * 0.03, height: w * 0.03).padding(.leading, w * 0.02)
                Capsule().fill(look.ink.opacity(0.85)).frame(width: w * 0.16, height: h * 0.035)
            } else {
                Spacer(minLength: 0)
                Capsule().fill(look.ink.opacity(0.6)).frame(width: w * 0.14, height: h * 0.03)
                    .padding(.leading, w * 0.06)
            }
            Spacer(minLength: 0)
            if look.theme == .console {
                ForEach(0..<3, id: \.self) { _ in
                    Rectangle().fill(look.key).frame(width: w * 0.045, height: w * 0.045)
                }
            } else {
                Capsule().fill(look.accent).frame(width: w * 0.1, height: w * 0.04)
            }
        }
        .frame(height: h * 0.07)
    }

    @ViewBuilder
    private func deck(picture: [Color], w: CGFloat, h: CGFloat, r: CGFloat, lit: Bool) -> some View {
        if look.theme == .classic {
            RoundedRectangle(cornerRadius: r)
                .fill(LinearGradient(colors: picture, startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: h * 0.02) {
                        Capsule().fill(.white.opacity(0.95)).frame(width: w * 0.13, height: h * 0.035)
                        Capsule().fill(.white.opacity(0.6)).frame(width: w * 0.09, height: h * 0.025)
                    }
                    .padding(w * 0.025)
                }
                .overlay(alignment: .topTrailing) {
                    if lit { Capsule().fill(look.accent).frame(width: w * 0.07, height: h * 0.04).padding(w * 0.02) }
                }
                .frame(height: h * 0.26)
                .shadow(color: .black.opacity(look.dark ? 0.35 : 0.12), radius: 2, y: 1)
        } else {
            consoleDeck(picture: picture, w: w, h: h, r: r, lit: lit)
        }
    }

    private func consoleDeck(picture: [Color], w: CGFloat, h: CGFloat, r: CGFloat, lit: Bool) -> some View {
        HStack(spacing: w * 0.02) {
            VStack(alignment: .leading, spacing: h * 0.025) {
                if look.theme == .console {
                    Capsule().fill((lit ? look.accent : hex(0x0088E8)).opacity(0.9))
                        .frame(width: w * 0.08, height: h * 0.025)
                }
                Capsule().fill(look.ink).frame(width: w * 0.12, height: h * 0.035)
                Capsule().fill(look.ink.opacity(0.35)).frame(width: w * 0.09, height: h * 0.025)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            RoundedRectangle(cornerRadius: r * 0.8)
                .fill(LinearGradient(colors: picture, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: w * 0.22)
                .overlay(alignment: .bottomTrailing) {
                    if look.theme == .console && lit {
                        Rectangle().fill(look.accent).frame(width: w * 0.06, height: h * 0.03).padding(w * 0.01)
                    }
                }
        }
        .padding(w * 0.02)
        .frame(height: h * 0.26)
        .background(RoundedRectangle(cornerRadius: r).fill(look.panel))
        .overlay(RoundedRectangle(cornerRadius: r).strokeBorder(look.line, lineWidth: 0.5))
    }

    private func filterRow(w: CGFloat, h: CGFloat) -> some View {
        HStack(spacing: w * 0.012) {
            Rectangle().fill(look.accent).frame(width: w * 0.06, height: h * 0.04)
            ForEach(0..<6, id: \.self) { _ in
                Rectangle().fill(look.key).frame(width: w * 0.075, height: h * 0.04)
            }
        }
    }

    private func tiles(w: CGFloat, h: CGFloat, r: CGFloat) -> some View {
        let cols = 4
        return VStack(spacing: w * 0.025) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: w * 0.025) {
                    ForEach(0..<cols, id: \.self) { col in
                        let pic = Look.pictures[2 + (row * cols + col) % 6]
                        VStack(alignment: .leading, spacing: h * 0.015) {
                            RoundedRectangle(cornerRadius: r * 0.6)
                                .fill(LinearGradient(colors: pic, startPoint: .top, endPoint: .bottom))
                            Capsule().fill(look.ink.opacity(0.7)).frame(width: w * 0.08, height: h * 0.022)
                        }
                        .padding(look.theme == .console ? w * 0.008 : 0)
                        .background(look.theme == .console ? AnyShapeStyle(look.panel) : AnyShapeStyle(.clear),
                                    in: RoundedRectangle(cornerRadius: r))
                    }
                }
                .frame(height: h * 0.2)
            }
        }
    }
}

/// The miniature for a theme in a mode: Auto is split, light on the left, dark on the right.
private struct LookThumbnail: View {
    let theme: Appearance
    let mode: ColorMode
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            switch mode {
            case .light: WindowMiniature(look: Look(theme: theme, dark: false))
            case .dark: WindowMiniature(look: Look(theme: theme, dark: true))
            case .auto:
                ZStack {
                    WindowMiniature(look: Look(theme: theme, dark: false))
                    WindowMiniature(look: Look(theme: theme, dark: true))
                        .mask(DiagonalHalf())
                }
            }
        }
    }
}

private struct DiagonalHalf: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.maxX * 0.62, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX * 0.38, y: rect.maxY))
            p.closeSubpath()
        }
    }
}

/// A row of picture choices with names under them.
private struct PictureChoices<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(name: String, value: Value, theme: Appearance, mode: ColorMode)]
    @Environment(\.consoleSettings) private var console
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledLength(relativeTo: .body) private var thumbWidth: CGFloat = 112

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Space.m))
        layout {
            ForEach(options.indices, id: \.self) { i in
                choice(options[i])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func choice(_ o: (name: String, value: Value, theme: Appearance, mode: ColorMode)) -> some View {
        let on = o.value == selection
        let ring = console ? ConsoleInk.signal : Color.accentColor
        let corner: CGFloat = console ? 4 : 7
        return Button {
            selection = o.value
        } label: {
            VStack(spacing: Space.xs) {
                LookThumbnail(theme: o.theme, mode: o.mode)
                    .frame(width: thumbWidth, height: thumbWidth * 0.625)
                    .clipShape(RoundedRectangle(cornerRadius: corner))
                    .overlay(RoundedRectangle(cornerRadius: corner)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .padding(3)
                    .overlay(RoundedRectangle(cornerRadius: corner + 3)
                        .strokeBorder(on ? ring : .clear, lineWidth: 2.5))
                Text(o.name)
                    .settingsText(console ? (on ? .consoleBodySmallEmphasis : .consoleBodySmall)
                                          : (on ? .calloutEmphasis : .callout))
                    .foregroundStyle(on ? .primary : .secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: thumbWidth + 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(o.name)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

/// Settings › General › Theme: Classic and Console, each drawn in the current mode.
struct ThemePictureChoices: View {
    @Binding var selection: Appearance
    let mode: ColorMode
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // Each theme as it would look right now (Auto resolves to what macOS shows).
        let shown: ColorMode = mode != .auto ? mode : (scheme == .dark ? .dark : .light)
        PictureChoices(title: "Theme", selection: $selection,
                       options: Appearance.allCases.map { ($0.title, $0, $0, shown) })
    }
}

/// Settings › General › Mode: Auto, Light and Dark, drawn in the chosen theme.
struct ModePictureChoices: View {
    @Binding var selection: ColorMode
    let theme: Appearance

    var body: some View {
        PictureChoices(title: "Mode", selection: $selection,
                       options: ColorMode.allCases.map { ($0.title, $0, theme, $0) })
    }
}
