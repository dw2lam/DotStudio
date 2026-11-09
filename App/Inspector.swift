//  Inspector.swift — the editor's right-hand panel: effect stack + shared source.

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Effect stack

struct EffectStackView: View {
    @Binding var preset: Preset
    @ObservedObject var model: AppModel
    @State private var expanded: Set<UUID> = []
    @State private var showAdd = false

    var body: some View {
        List {
            Section {
                ForEach($preset.effects) { $effect in
                    EffectRow(effect: $effect,
                              isExpanded: expandedBinding(effect.id),
                              isFirst: preset.effects.first?.id == effect.id,
                              onDuplicate: { duplicate(effect.id) },
                              onRemove: { remove(effect.id) })
                }
                .onMove { preset.effects.move(fromOffsets: $0, toOffset: $1) }
            } header: {
                HStack {
                    Text(preset.isScene ? "Scene & Layers" : "Effects")
                    Spacer()
                    Text("Drag to reorder · top runs first").font(.caption2).foregroundStyle(.tertiary)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 14) {
                    if preset.effects.isEmpty {
                        Text("No effects yet — this style shows the source as-is.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button { showAdd = true } label: {
                        Label("Add Effect", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .popover(isPresented: $showAdd, arrowEdge: .leading) {
                        AddEffectPicker(source: model.library.source, thumbnailer: model.thumbnailer,
                                        include: { !$0.isScene }) { kind in
                            let e = EffectInstance(kind)
                            preset.effects.append(e)
                            expanded = [e.id]
                            showAdd = false
                        }
                    }
                }
                .padding(.top, 6)
            }

            Section("Motion") {
                Picker("Frame rate", selection: $preset.fps) {
                    ForEach(fpsOptions, id: \.self) { Text("\($0) fps").tag($0) }
                }
                Text(preset.fps > 60
                     ? "120 fps needs a ProMotion display; elsewhere it plays at the screen's rate. Costs more GPU and battery."
                     : "Lower frame rates save battery; most styles look the same at 30.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .onAppear {
            // Open the first effect so the main knobs are right there.
            if expanded.isEmpty, let first = preset.effects.first { expanded = [first.id] }
        }
    }

    private var fpsOptions: [Int] {
        var opts = [15, 24, 30, 60, 120]
        if !opts.contains(preset.fps) { opts.append(preset.fps); opts.sort() }
        return opts
    }

    private func expandedBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) },
                set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }

    private func duplicate(_ id: UUID) {
        guard let i = preset.effects.firstIndex(where: { $0.id == id }) else { return }
        var copy = preset.effects[i]
        copy.id = UUID()
        preset.effects.insert(copy, at: i + 1)
        expanded.insert(copy.id)
    }

    private func remove(_ id: UUID) {
        preset.effects.removeAll { $0.id == id }
        expanded.remove(id)
    }
}

struct EffectRow: View {
    @Binding var effect: EffectInstance
    @Binding var isExpanded: Bool
    let isFirst: Bool
    let onDuplicate: () -> Void
    let onRemove: () -> Void

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(effect.kind.params) { spec in
                    ParamRow(spec: spec, value: paramBinding(spec))
                }
                if effect.kind.usesColors { colorsRow }
            }
            .padding(.vertical, 6)
            .disabled(!effect.enabled)
            .opacity(effect.enabled ? 1 : 0.45)
        } label: {
            HStack(spacing: 8) {
                Button { effect.enabled.toggle() } label: {
                    Image(systemName: effect.enabled ? "eye" : "eye.slash")
                        .foregroundStyle(effect.enabled ? Color.primary : Color.secondary)
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
                .help(effect.enabled ? "Hide this effect" : "Show this effect")

                Text(effect.kind.displayName)
                    .font(.body.weight(.medium))
                    .help(effect.kind.blurb)
                    .foregroundStyle(effect.enabled ? .primary : .secondary)
                    .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() } }
                if effect.kind.isScene {
                    Text("SCENE").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder(.secondary.opacity(0.5)))
                }
                Spacer()
                Menu {
                    Button("Reset to Defaults") { reset() }
                        .disabled(isDefault)
                    Button("Duplicate") { onDuplicate() }
                    Divider()
                    Button("Remove", role: .destructive) { onRemove() }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .contextMenu {
            Button("Reset to Defaults") { reset() }.disabled(isDefault)
            Button("Duplicate") { onDuplicate() }
            Divider()
            Button("Remove", role: .destructive) { onRemove() }
        }
    }

    private var isDefault: Bool {
        effect.params == effect.kind.defaultParams
            && effect.colorA == effect.kind.defaultColorA
            && effect.colorB == effect.kind.defaultColorB
    }

    private func reset() {
        effect.params = effect.kind.defaultParams
        effect.colorA = effect.kind.defaultColorA
        effect.colorB = effect.kind.defaultColorB
    }

    private var colorsRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("Colors").font(.callout).frame(width: 92, alignment: .leading).padding(.top, 3)
            if effect.kind.defaultColorA != nil { swatch(effect.kind.colorALabel, isA: true) }
            if effect.kind.defaultColorB != nil { swatch(effect.kind.colorBLabel, isA: false) }
            Spacer()
        }
    }

    private func swatch(_ title: String, isA: Bool) -> some View {
        VStack(spacing: 3) {
            ColorPicker(title, selection: colorBinding(isA: isA)).labelsHidden()
            Text(title).font(.caption2).foregroundStyle(.secondary).fixedSize()
        }
        .help(title)
    }

    private func paramBinding(_ spec: ParamSpec) -> Binding<Double> {
        Binding(get: { effect.params[spec.key] ?? spec.def },
                set: { effect.params[spec.key] = $0 })
    }

    private func colorBinding(isA: Bool) -> Binding<Color> {
        Binding(
            get: {
                let c = isA ? (effect.colorA ?? effect.kind.defaultColorA) : (effect.colorB ?? effect.kind.defaultColorB)
                return Color(c ?? .black)
            },
            set: { if isA { effect.colorA = RGBA($0) } else { effect.colorB = RGBA($0) } })
    }
}

/// One parameter: menu, switch, or labeled slider with a readable value and reset.
struct ParamRow: View {
    let spec: ParamSpec
    @Binding var value: Double

    var body: some View {
        if let options = spec.options {
            Picker(spec.label, selection: Binding(get: { Int(value.rounded()) }, set: { value = Double($0) })) {
                ForEach(Array(options.enumerated()), id: \.offset) { i, name in Text(name).tag(i) }
            }
            .font(.callout)
        } else if spec.isToggle {
            Toggle(spec.label, isOn: Binding(get: { value > 0.5 }, set: { value = $0 ? 1 : 0 }))
                .font(.callout)
        } else {
            HStack(spacing: 8) {
                Text(spec.label).font(.callout).frame(width: 92, alignment: .leading).lineLimit(1)
                if spec.step > 0 {
                    Slider(value: $value, in: spec.min...spec.max, step: spec.step)
                } else {
                    Slider(value: $value, in: spec.min...spec.max)
                }
                Text(formatted)
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
                Button { value = spec.def } label: {
                    Image(systemName: "arrow.counterclockwise").font(.caption2)
                }
                .buttonStyle(.borderless)
                .opacity(abs(value - spec.def) > 1e-6 ? 1 : 0)
                .disabled(abs(value - spec.def) <= 1e-6)
                .help("Reset to \(format(spec.def))")
            }
            .controlSize(.small)
        }
    }

    private var formatted: String { format(value) }

    private func format(_ v: Double) -> String {
        let key = spec.key.lowercased()
        if key == "angle" || spec.label.lowercased().contains("angle") {
            return String(format: "%.0f°", v * 180 / .pi)
        }
        if spec.step >= 1 || spec.max - spec.min >= 20 { return String(format: "%.0f", v) }
        if spec.max <= 1.0 && spec.min >= 0 { return String(format: "%.0f%%", v * 100) }
        return String(format: "%.2f", v)
    }
}

// MARK: - Add effect picker

struct AddEffectPicker: View {
    let source: SourceSpec
    let thumbnailer: Thumbnailer
    var include: (EffectKind) -> Bool = { _ in true }
    var prompt = "Search effects"
    /// Highlights one cell (onboarding's creator); nil in the editor's add-popover.
    var selected: EffectKind? = nil
    /// Popover size; nil lets the picker fill its container.
    var size: CGSize? = CGSize(width: 430, height: 500)
    /// List Looks before Scenes (onboarding starts people on a Look).
    var scenesLast = false
    let onPick: (EffectKind) -> Void
    @State private var query = ""

    private var groups: [(EffectCategory, [EffectKind])] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let cats = scenesLast
            ? EffectCategory.allCases.filter { !$0.isScenes } + EffectCategory.allCases.filter(\.isScenes)
            : EffectCategory.allCases
        return cats.compactMap { cat in
            let kinds = EffectKind.allCases.filter {
                $0.category == cat && !$0.isRetired && include($0) &&
                (q.isEmpty || $0.displayName.lowercased().contains(q) || cat.rawValue.lowercased().contains(q)
                 || $0.blurb.lowercased().contains(q))
            }
            return kinds.isEmpty ? nil : (cat, kinds)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField(prompt, text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(12)
            Divider()
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(groups, id: \.0) { cat, kinds in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(cat.rawValue, systemImage: cat.symbol)
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 12) {
                                ForEach(kinds, id: \.self) { kind in
                                    Button { onPick(kind) } label: { cell(kind) }
                                        .buttonStyle(.plain)
                                        .help(kind.blurb)
                                        .id(kind)
                                }
                            }
                        }
                    }
                    if groups.isEmpty {
                        Text("No effects match “\(query)”.").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 30)
                    }
                }
                .padding(12)
            }
            .onAppear {
                // Show the current pick, not the top of the list.
                guard let selected else { return }
                DispatchQueue.main.async { proxy.scrollTo(selected, anchor: .center) }
            }
            }
        }
        .frame(width: size?.width, height: size?.height)
    }

    private func cell(_ kind: EffectKind) -> some View {
        let isSelected = kind == selected
        return VStack(alignment: .leading, spacing: 4) {
            swatch(kind)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2.5))
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(4)
                    }
                }
            Text(kind.displayName).font(.caption.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(.primary).lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    private func swatch(_ kind: EffectKind) -> some View {
        Group {
            if let img = thumbnailer.effectImage(kind, source: source) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                Color.black
            }
        }
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.primary.opacity(0.12)))
    }
}

// MARK: - Source

/// The one source every Look restyles. Used in the editor's Source tab and the
/// library's Source popover.
struct SourceEditor: View {
    @Binding var source: SourceSpec
    @ObservedObject var model: AppModel
    @State private var importing = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Every Look restyles this. Scenes don't use it.")
                .font(.caption).foregroundStyle(.secondary)

            Picker("Kind", selection: $source.kind) {
                Text("Slideshow").tag(SourceKind.collection)
                Text("Photo").tag(SourceKind.image)
                Text("Video").tag(SourceKind.video)
                Text("Gradient").tag(SourceKind.gradient)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch source.kind {
            case .collection: slideshowControls
            case .gradient: gradientControls
            case .image, .video: mediaControls
            }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: source.kind == .video ? [.movie, .mpeg4Movie, .quickTimeMovie] : [.image],
                      allowsMultipleSelection: source.kind == .collection) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            if source.kind == .collection { model.importSlideshowPhotos(urls) }
            else if let url = urls.first { importFile(url, kind: source.kind) }
        }
    }

    /// Built-in photos (or the user's own), slowly panning and cross-fading.
    private var slideshowControls: some View {
        let own = !(source.mediaFilenames ?? []).isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            Color.clear
                .frame(maxWidth: .infinity)
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .overlay(SourceSwatch(source: source))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(dropTargeted ? Color.accentColor : .clear, lineWidth: 2))
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                    loadDroppedImages(providers) { urls in model.importSlideshowPhotos(urls) }
                    return true
                }
            Text(own ? "Your photos · \(source.mediaFilenames?.count ?? 0)"
                     : "Built-in photos · curated, public domain")
                .font(.caption).foregroundStyle(.secondary)
            ParamRow(spec: ParamSpec("hold", "Seconds Each", 6, 120, def: SourceSpec.defaultSlideSeconds),
                     value: Binding(get: { source.slideInterval }, set: { source.slideSeconds = $0 }))
            ParamRow(spec: ParamSpec("motion", "Pan & Zoom", 0, 1, def: SourceSpec.defaultMotion),
                     value: Binding(get: { source.motionAmount }, set: { source.motion = $0 }))
            HStack {
                Button(own ? "Choose Other Photos…" : "Use Your Own Photos…") { importing = true }
                if own {
                    Button("Use Built-in Photos") { model.useBuiltInPhotos() }
                }
            }
            .controlSize(.small)
        }
    }

    /// Image files among dropped items, delivered together on the main queue.
    private func loadDroppedImages(_ providers: [NSItemProvider], _ done: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                defer { group.leave() }
                guard let url, let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else { return }
                lock.lock(); urls.append(url); lock.unlock()
            }
        }
        group.notify(queue: .main) { if !urls.isEmpty { done(urls) } }
    }

    private var gradientControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                ColorPicker("From", selection: colorBinding(\.colorA))
                ColorPicker("To", selection: colorBinding(\.colorB))
                Spacer()
                Button {
                    let a = source.colorA; source.colorA = source.colorB; source.colorB = a
                } label: { Image(systemName: "arrow.left.arrow.right") }
                    .buttonStyle(.borderless)
                    .help("Swap colors")
            }
            .font(.callout)
            ParamRow(spec: ParamSpec("angle", "Angle", 0, 6.28, def: 1.1), value: $source.gradientAngle)
            ParamRow(spec: ParamSpec("drift", "Drift", 0, 3, def: 1.0), value: $source.gradientDrift)
        }
    }

    private var mediaControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { importing = true } label: {
                VStack(spacing: 8) {
                    if source.mediaFilename != nil {
                        SourceSwatch(source: source)
                            .aspectRatio(16.0 / 10.0, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        Text(source.mediaFilename ?? "").font(.caption).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: source.kind == .video ? "film" : "photo")
                            .font(.title).foregroundStyle(.secondary)
                        Text("Drop a \(source.kind == .video ? "video" : "photo") here, or click to choose")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 110)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(dropTargeted ? 0.08 : 0.03)))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5)))
            }
            .buttonStyle(.plain)
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                guard let p = providers.first else { return false }
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, let type = UTType(filenameExtension: url.pathExtension) else { return }
                    let kind: SourceKind? = type.conforms(to: .movie) ? .video : type.conforms(to: .image) ? .image : nil
                    if let kind { DispatchQueue.main.async { importFile(url, kind: kind) } }
                }
                return true
            }

            Picker("Fit", selection: $source.fillMode) {
                Text("Fill").tag(1); Text("Fit").tag(0); Text("Stretch").tag(2)
            }
            .pickerStyle(.segmented)
            .font(.callout)
        }
    }

    private func importFile(_ url: URL, kind: SourceKind) {
        let ok = url.startAccessingSecurityScopedResource()
        model.importMedia(url, kind: kind)
        if ok { url.stopAccessingSecurityScopedResource() }
    }

    private func colorBinding(_ kp: WritableKeyPath<SourceSpec, RGBA>) -> Binding<Color> {
        Binding(get: { Color(source[keyPath: kp]) }, set: { source[keyPath: kp] = RGBA($0) })
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
