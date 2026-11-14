//  SceneInputRows.swift — the Inspector's rows for a Custom Scene's live inputs
//  (docs/signals-design.md §7): one row per input the package declares,
//  "Air quality  [Air quality ▾]  87 AQI" — the signal it's connected to (or "Not connected")
//  and the value the scene draws with now (eased, as the renderer last drew it; the input's
//  default, dimmed, while it isn't connected or its signal is stale).

import SwiftUI

/// The inputs block under a Custom Scene's params (nothing when the package declares none).
struct SceneInputsSection: View {
    @Binding var effect: EffectInstance
    var model: AppModel?
    @Environment(\.layout) private var layout

    var body: some View {
        let inputs = effect.inputSpecs
        if !inputs.isEmpty {
            VStack(alignment: .leading, spacing: layout.inspectorRowGap) {
                Text("Live inputs")
                    .textRole(.caption).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                // (one clock for every row: the values refresh each second while they show)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let shown = shownValues(inputs, now: ctx.date)
                    VStack(alignment: .leading, spacing: layout.inspectorRowGap) {
                        ForEach(Array(inputs.enumerated()), id: \.element.key) { i, input in
                            SceneInputRow(input: input, signal: binding(input.key), signals: userSignals,
                                          value: Double(shown.value[i]), live: Double(shown.live[i]))
                        }
                    }
                }
            }
        }
    }

    private var userSignals: [Signal] { model?.library.signals ?? [] }

    /// What the scene draws with: the live renderer's eased values, else where they're heading.
    private func shownValues(_ inputs: [CustomSceneManifest.Input], now: Date) -> SceneInputValues {
        if let v = SignalLink.lastDrawn(effect.id) { return v }
        return SignalLink.target(inputs, bindings: effect.inputs, state: SignalService.shared.snapshot(), wall: now, forced: nil)
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { effect.inputs?[key]?.signal ?? "" },
                set: { id in
                    var m = effect.inputs ?? [:]
                    m[key] = id.isEmpty ? nil : InputBinding(signal: id)
                    effect.inputs = m.isEmpty ? nil : m
                })
    }
}

/// One input: its label, the signal menu, the value now.
struct SceneInputRow: View {
    let input: CustomSceneManifest.Input
    @Binding var signal: String
    let signals: [Signal]
    let value: Double
    let live: Double
    @Environment(\.layout) private var layout

    var body: some View {
        InspectorRow(label: input.label) {
            HStack(spacing: layout.controlGap) {
                SignalPickerMenu(title: input.label, selection: $signal, signals: signals, suggest: input.suggest)
                Text(valueText)
                    .textRole(.value)
                    .foregroundStyle(signal.isEmpty || live < 0.5 ? .tertiary : .secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .help(help)
                    .accessibilityLabel("\(input.label) now")
                    .accessibilityValue(valueText)
            }
        }
    }

    private var valueText: String { SignalValue.format(value) + RuleText.unitSuffix(input.unit) }

    private var help: String {
        let def = SignalValue.format(input.def) + RuleText.unitSuffix(input.unit)
        if signal.isEmpty { return "Not connected: the scene uses its default, \(def)." }
        if live < 0.5 { return "No fresh value: the scene eases back to its default, \(def)." }
        return "What the scene draws with now (changes ease in over about 20 seconds)."
    }
}

/// The signal menu, drawn like the Inspector's other menus (InspectorMenu): "Not connected",
/// then the suggested built-in, the built-ins and the user's own signals (numbers and yes/no
/// values only — a word can't drive an input).
struct SignalPickerMenu: View {
    let title: String
    @Binding var selection: String
    let signals: [Signal]
    var suggest: String?
    @ScaledLength(relativeTo: .body) private var height: CGFloat = InspectorMetrics.segmentHeight

    private var builtIns: [BuiltInSignal] { BuiltInSignals.all.filter { $0.type != .string } }
    private var mine: [Signal] { signals.filter { $0.valueType != .string } }

    private var currentTitle: String {
        if selection.isEmpty { return "Not connected" }
        if let b = BuiltInSignals.find(selection) { return b.name }
        if let s = signals.first(where: { Library.sameSignal($0.key, selection) }) { return s.name }
        return "Missing signal"
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: height / 2, style: .continuous)
        let current = currentTitle
        Menu {
            Picker(title, selection: picked) {
                Text("Not connected").tag("")
                if let sg = suggest, let b = builtIns.first(where: { $0.id == sg }) {
                    Section("Suggested") { Text(b.name).tag(b.id + "#suggested") }
                }
                Section("Built in") {
                    ForEach(builtIns, id: \.id) { b in Text(b.name).tag(b.id) }
                }
                if !mine.isEmpty {
                    Section("Your signals") {
                        ForEach(mine) { s in Text(s.enabled ? s.name : "\(s.name) (off)").tag(s.key) }
                    }
                }
                if current == "Missing signal" { Text("Missing signal").tag(selection) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: Space.xs) {
                Text(current)
                    .textRole(.body)
                    .foregroundStyle(selection.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)          // ("Not connected" reads whole in a narrow inspector)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .textRole(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, height / 2)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(shape.fill(Color.primary.opacity(0.078)))
            .contentShape(shape)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
        .help("\(title) follows: \(current)")
        .accessibilityLabel("\(title) signal")
        .accessibilityValue(current)
    }

    /// The Suggested entry is the same built-in: store its plain id.
    private var picked: Binding<String> {
        Binding(get: { selection },
                set: { selection = $0.hasSuffix("#suggested") ? String($0.dropLast("#suggested".count)) : $0 })
    }
}
