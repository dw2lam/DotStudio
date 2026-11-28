//  AdjustKey.swift — the editor's Adjust key: one control beside Add Effect that opens the
//  style's Brightness, Contrast, Saturation, Exposure, Highlights, Shadows, Warmth, Tint,
//  Vibrance and Fade sliders (owner, 2026-11-27: "a single dropdown", not an effect to dig
//  out of the Add Effect picker).
//
//  Under the hood it is an ordinary effect layer (EffectKind.adjust, shader 81) — so the
//  renderer, the saver, share files and the MCP server need nothing new — kept as the LAST
//  layer of the stack, so it grades the finished picture: a scene and every look over it.
//  The Effects list doesn't show that trailing layer (Preset.layers); this key edits it. The
//  first change adds it, and it goes again as soon as every slider is back at 0 (Reset, a
//  double-click on a fader, ⌫), so an untouched style draws exactly what it did.
//
//  Classic: a large bordered button opening a popover of the inspector's slider rows (each
//  with its own reset). Retro: a keycap, LED lit while the style is adjusted, opening the
//  same rows as faders on the panel colour — the Source key's pattern (LibraryView).

import SwiftUI

extension Preset {
    /// Where the style's Adjust layer is: its last effect, when that is an Adjust.
    var adjustIndex: Int? {
        guard let i = effects.indices.last, effects[i].kind == .adjust else { return nil }
        return i
    }

    /// The stack as the Effects list shows and reorders it: everything but the Adjust layer,
    /// which stays last whatever is added, moved or removed.
    var layers: [EffectInstance] {
        get { adjustIndex.map { Array(effects[..<$0]) } ?? effects }
        set {
            let adjust = adjustIndex.map { effects[$0] }
            effects = newValue + (adjust.map { [$0] } ?? [])
        }
    }

    /// True while an Adjust layer is on and changes something.
    var isAdjusted: Bool {
        guard let i = adjustIndex, effects[i].enabled else { return false }
        return !Self.isNeutral(effects[i])
    }

    static func isNeutral(_ e: EffectInstance) -> Bool {
        EffectKind.adjust.params.allSatisfy { abs((e.params[$0.key] ?? $0.def) - $0.def) <= 1e-6 }
    }

    /// One Adjust value: the layer's, or the neutral default.
    func adjustValue(_ spec: ParamSpec) -> Double {
        adjustIndex.flatMap { effects[$0].params[spec.key] } ?? spec.def
    }

    /// Sets one Adjust value: adds the layer on the first change, drops it once every value
    /// is neutral again.
    mutating func setAdjust(_ spec: ParamSpec, _ value: Double) {
        if adjustIndex == nil {
            if abs(value - spec.def) <= 1e-6 { return }
            effects.append(EffectInstance(.adjust))
        }
        guard let i = adjustIndex else { return }
        effects[i].params[spec.key] = value
        effects[i].enabled = true
        if Self.isNeutral(effects[i]) { effects.remove(at: i) }
    }

    mutating func resetAdjust() {
        if let i = adjustIndex { effects.remove(at: i) }
    }
}

/// The key beside Add Effect, and its popover.
struct AdjustKey: View {
    @Binding var preset: Preset
    @Environment(\.console) private var console
    @State private var open = false
    /// Console: the key's margins, as Add Effect's (consoleKeyLarge).
    @ScaledInsets(relativeTo: .callout) private var keyPadding = EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14)
    @ScaledLength(relativeTo: .caption2) private var dot: CGFloat = 6

    var body: some View {
        let adjusted = preset.isAdjusted
        Group {
            if console {
                Button { open.toggle() } label: {
                    HStack(spacing: Space.xs) {
                        ConsoleLED(on: adjusted)
                        Text("Adjust").textRole(.consoleKeyLarge)
                        Image(systemName: "chevron.down")
                            .textRole(.consoleBodySmall)
                            .fontWeight(.semibold)
                            .foregroundStyle(ConsoleInk.legend)
                    }
                }
                .buttonStyle(.keycap(padding: keyPadding))
            } else {
                Button { open.toggle() } label: {
                    HStack(spacing: Space.xs) {
                        ScaledControlLabel(title: "Adjust", systemImage: "slider.horizontal.3")
                        if adjusted {
                            Circle().fill(Color.accentColor).frame(width: dot, height: dot)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .adaptiveControlSize(.large)
            }
        }
        .fixedSize()
        .help(adjusted ? "Adjust — brightness, contrast, color and tone (changed)"
                       : "Adjust brightness, contrast, saturation, exposure, highlights, shadows, warmth, tint and vibrance")
        .accessibilityLabel("Adjust")
        .accessibilityValue(adjusted ? "Changed" : "No changes")
        .popover(isPresented: $open, arrowEdge: .leading) {
            AdjustPanel(preset: $preset)
                .adaptiveLayout()   // the popover is its own root
        }
    }
}

/// The popover's content: a title with Reset, then one slider row per value.
struct AdjustPanel: View {
    @Binding var preset: Preset
    @Environment(\.layout) private var layout
    @Environment(\.console) private var console

    var body: some View {
        let range = layout.popoverWidth
        let content = VStack(alignment: .leading, spacing: console ? Space.s : layout.itemGap) {
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                Text("Adjust")
                    .textRole(console ? .consoleHeadline : .headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                resetButton
            }
            VStack(alignment: .leading, spacing: console ? 0 : layout.inspectorRowGap) {
                ForEach(EffectKind.adjust.params) { spec in
                    ParamRow(spec: spec, value: binding(spec))
                }
            }
            .overlay(alignment: .top) {
                if console { Rectangle().fill(ConsoleInk.hairline).frame(height: 1) }
            }
            Text(console ? "Grades the whole style, after every effect. Double-click a fader to zero it."
                         : "Grades the whole style, after every effect.")
                .modifier(InspectorNote())
                .wrapping()
        }
        .padding(layout.cardPadding)
        .frame(width: min(max(layout.scaled(340), range.lowerBound), range.upperBound))
        if console {
            content
                .background(ConsoleInk.panel)
                .presentationBackground(ConsoleInk.panel)
                .foregroundStyle(ConsoleInk.ink, ConsoleInk.legend)
        } else {
            content
        }
    }

    @ViewBuilder private var resetButton: some View {
        let changed = preset.adjustIndex != nil
        if console {
            Button("Reset") { preset.resetAdjust() }
                .buttonStyle(.keycap(padding: HubMetrics.smallKey))
                .disabled(!changed)
                .help("Set every slider back to 0")
        } else {
            Button("Reset") { preset.resetAdjust() }
                .adaptiveControlSize(.small)
                .disabled(!changed)
                .help("Set every slider back to 0")
        }
    }

    private func binding(_ spec: ParamSpec) -> Binding<Double> {
        Binding(get: { preset.adjustValue(spec) },
                set: { preset.setAdjust(spec, $0) })
    }
}
