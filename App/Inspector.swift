//  Inspector.swift — edit a preset's source and effect stack.

import SwiftUI
import UniformTypeIdentifiers

struct InspectorView: View {
    @Binding var preset: Preset
    @Binding var source: SourceSpec
    @ObservedObject var model: AppModel
    @State private var importing = false
    @State private var importKind: SourceKind = .image

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sourceSection
                Divider()
                effectsSection
                Divider()
                saverSection
            }
            .padding(16)
        }
        .frame(minWidth: 320)
    }

    // MARK: Source (shared by every style)

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SOURCE").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("shared by all styles").font(.caption2).foregroundStyle(.tertiary)
            }
            Picker("", selection: $source.kind) {
                Text("Gradient").tag(SourceKind.gradient)
                Text("Image").tag(SourceKind.image)
                Text("Video").tag(SourceKind.video)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch source.kind {
            case .gradient:
                ColorPicker("Start", selection: bindColor(\.colorA))
                ColorPicker("End", selection: bindColor(\.colorB))
                labeledSlider("Angle", value: $source.gradientAngle, 0, 6.28)
            case .image, .video:
                HStack {
                    Button(source.mediaFilename == nil ? "Choose File…" : "Replace File…") {
                        importKind = source.kind
                        importing = true
                    }
                    if source.mediaFilename != nil {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                Picker("Fit", selection: $source.fillMode) {
                    Text("Cover").tag(1); Text("Fit").tag(0); Text("Stretch").tag(2)
                }
            }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: importKind == .video ? [.movie, .mpeg4Movie, .quickTimeMovie] : [.image],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                let ok = url.startAccessingSecurityScopedResource()
                model.importMedia(url, kind: importKind)
                if ok { url.stopAccessingSecurityScopedResource() }
            }
        }
    }

    // MARK: Effects

    private var effectsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("EFFECT STACK").font(.caption).foregroundStyle(.secondary)
                Spacer()
                addMenu
            }
            if preset.effects.isEmpty {
                Text("No effects. Add one above — they apply top to bottom.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(preset.effects.enumerated()), id: \.element.id) { idx, eff in
                effectCard(idx, eff)
            }
        }
    }

    private var addMenu: some View {
        Menu {
            ForEach(EffectCategory.allCases, id: \.self) { cat in
                Section(cat.rawValue) {
                    ForEach(EffectKind.allCases.filter { $0.category == cat }, id: \.self) { kind in
                        Button(kind.displayName) { preset.effects.append(EffectInstance(kind)) }
                    }
                }
            }
        } label: {
            Label("Add", systemImage: "plus.circle.fill")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func effectCard(_ idx: Int, _ eff: EffectInstance) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("", isOn: bindEnabled(idx)).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                Text(eff.kind.displayName).font(.system(.body, weight: .medium))
                Spacer()
                Button { move(idx, -1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless).disabled(idx == 0)
                Button { move(idx, 1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless).disabled(idx == preset.effects.count - 1)
                Button(role: .destructive) { preset.effects.remove(at: idx) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            if eff.enabled {
                ForEach(eff.kind.params) { spec in
                    if let options = spec.options {
                        Picker(spec.label, selection: indexParam(idx, spec, count: options.count)) {
                            ForEach(Array(options.enumerated()), id: \.offset) { i, name in
                                Text(name).tag(i)
                            }
                        }
                        .controlSize(.small)
                    } else if spec.isToggle {
                        Toggle(spec.label, isOn: boolParam(idx, spec))
                            .controlSize(.small)
                    } else {
                        labeledSlider(spec.label, value: param(idx, spec), spec.min, spec.max)
                    }
                }
                if eff.kind.usesColors {
                    HStack {
                        if eff.kind.defaultColorA != nil {
                            ColorPicker("A", selection: effColor(idx, isA: true)).labelsHidden()
                        }
                        if eff.kind.defaultColorB != nil {
                            ColorPicker("B", selection: effColor(idx, isA: false)).labelsHidden()
                        }
                        Text("palette").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: Screensaver (library-wide)

    private var saverSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SCREENSAVER").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("applies to all styles").font(.caption2).foregroundStyle(.tertiary)
            }
            Picker("Quality", selection: qualityBinding) {
                Text("Full").tag(1.0)
                Text("Balanced").tag(0.75)
                Text("Efficient").tag(0.5)
            }
            .controlSize(.small)
            Text("Lower quality renders at reduced resolution — much less memory and battery on Retina displays, with the same chunky look.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Rotate through styles", isOn: rotationEnabled)
                .controlSize(.small)
            if model.library.rotation?.enabled == true {
                Picker("Every", selection: rotation(\.intervalMinutes)) {
                    Text("1 min").tag(1.0)
                    Text("5 min").tag(5.0)
                    Text("15 min").tag(15.0)
                    Text("30 min").tag(30.0)
                    Text("1 hour").tag(60.0)
                }
                .controlSize(.small)
                Toggle("Shuffle order", isOn: rotation(\.shuffle))
                    .controlSize(.small)
                labeledSlider("Crossfade (s)", value: rotation(\.transitionSeconds), 0, 3)
            }

            Toggle("Day / night styles", isOn: scheduleEnabled)
                .controlSize(.small)
            if model.library.schedule?.enabled == true {
                presetPicker("Day", selection: schedule(\.dayPresetID))
                presetPicker("Night", selection: schedule(\.nightPresetID))
                Text("Follows the sun at your location — switches at sunrise and sunset.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func presetPicker(_ label: String, selection: Binding<UUID?>) -> some View {
        Picker(label, selection: selection) {
            Text("—").tag(UUID?.none)
            ForEach(model.library.presets) { p in
                Text(p.name).tag(UUID?.some(p.id))
            }
        }
        .controlSize(.small)
    }

    private var qualityBinding: Binding<Double> {
        Binding(get: { model.library.renderScale ?? 1.0 },
                set: { model.library.renderScale = $0 >= 1.0 ? nil : $0; model.save() })
    }

    /// Binding into Library.rotation, materializing the spec on first edit.
    private func rotation<T>(_ kp: WritableKeyPath<RotationSpec, T>) -> Binding<T> {
        Binding(get: { (model.library.rotation ?? RotationSpec())[keyPath: kp] },
                set: {
                    var spec = model.library.rotation ?? RotationSpec()
                    spec[keyPath: kp] = $0
                    model.library.rotation = spec
                    model.save()
                })
    }

    /// Binding into Library.schedule, materializing the spec on first edit.
    private func schedule<T>(_ kp: WritableKeyPath<ScheduleSpec, T>) -> Binding<T> {
        Binding(get: { (model.library.schedule ?? ScheduleSpec())[keyPath: kp] },
                set: {
                    var spec = model.library.schedule ?? ScheduleSpec()
                    spec[keyPath: kp] = $0
                    model.library.schedule = spec
                    model.save()
                })
    }

    // Rotation and day/night are mutually exclusive — enabling one disables the other.
    private var rotationEnabled: Binding<Bool> {
        Binding(get: { model.library.rotation?.enabled ?? false },
                set: {
                    var spec = model.library.rotation ?? RotationSpec()
                    spec.enabled = $0
                    model.library.rotation = spec
                    if $0 { model.library.schedule?.enabled = false }
                    model.save()
                })
    }
    private var scheduleEnabled: Binding<Bool> {
        Binding(get: { model.library.schedule?.enabled ?? false },
                set: {
                    var spec = model.library.schedule ?? ScheduleSpec()
                    spec.enabled = $0
                    model.library.schedule = spec
                    if $0 { model.library.rotation?.enabled = false }
                    model.save()
                })
    }

    // MARK: Helpers

    private func move(_ idx: Int, _ delta: Int) {
        let j = idx + delta
        guard j >= 0, j < preset.effects.count else { return }
        preset.effects.swapAt(idx, j)
    }

    private func labeledSlider(_ label: String, value: Binding<Double>, _ lo: Double, _ hi: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: lo...hi)
        }
    }

    private func bindColor(_ kp: WritableKeyPath<SourceSpec, RGBA>) -> Binding<Color> {
        Binding(get: { Color(source[keyPath: kp]) }, set: { source[keyPath: kp] = RGBA($0) })
    }
    private func bindEnabled(_ idx: Int) -> Binding<Bool> {
        Binding(get: { preset.effects[safe: idx]?.enabled ?? false },
                set: { if preset.effects.indices.contains(idx) { preset.effects[idx].enabled = $0 } })
    }
    private func param(_ idx: Int, _ spec: ParamSpec) -> Binding<Double> {
        Binding(get: { preset.effects[safe: idx]?.params[spec.key] ?? spec.def },
                set: { if preset.effects.indices.contains(idx) { preset.effects[idx].params[spec.key] = $0 } })
    }
    private func indexParam(_ idx: Int, _ spec: ParamSpec, count: Int) -> Binding<Int> {
        Binding(get: { Int((preset.effects[safe: idx]?.params[spec.key] ?? spec.def).rounded()) },
                set: { if preset.effects.indices.contains(idx) { preset.effects[idx].params[spec.key] = Double($0) } })
    }
    private func boolParam(_ idx: Int, _ spec: ParamSpec) -> Binding<Bool> {
        Binding(get: { (preset.effects[safe: idx]?.params[spec.key] ?? spec.def) > 0.5 },
                set: { if preset.effects.indices.contains(idx) { preset.effects[idx].params[spec.key] = $0 ? 1 : 0 } })
    }
    private func effColor(_ idx: Int, isA: Bool) -> Binding<Color> {
        Binding(
            get: {
                guard let e = preset.effects[safe: idx] else { return .black }
                let c = isA ? (e.colorA ?? e.kind.defaultColorA) : (e.colorB ?? e.kind.defaultColorB)
                return Color(c ?? .black)
            },
            set: {
                guard preset.effects.indices.contains(idx) else { return }
                if isA { preset.effects[idx].colorA = RGBA($0) } else { preset.effects[idx].colorB = RGBA($0) }
            })
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
