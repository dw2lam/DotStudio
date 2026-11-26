//  SignalsSettingsSection.swift — Settings ▸ Signals: the live values When rules react to
//  (docs/signals-design.md §7). The built-ins in a line; a row per signal of the user's (where it
//  comes from, its value, how fresh, a status dot, on/off, an AI badge); Add Signal… opens the
//  editor sheet (kind, URL or file, Test with an outline to pick the value from, type and units,
//  and the API key, which goes to the Keychain only — SignalKeychain).

import AppKit
import SwiftUI

struct SignalsSettingsSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var service = SignalService.shared
    @Environment(\.layout) private var layout
    @State private var editing: Signal?
    @Environment(\.console) private var console

    var body: some View {
        let signals = model.library.signals ?? []
        Section {
            Text("Built in: weather, sun, time, battery, music")
                .settingsText(.caption).foregroundStyle(.secondary).wrapping()
            if signals.isEmpty {
                Text("Add a value from the web or a file, then use it in a When rule on the Screensaver card, or connect it to a custom scene's input in the editor.")
                    .settingsText(.body).foregroundStyle(.secondary).wrapping()
            }
            ForEach(signals) { s in
                SignalRow(signal: s, status: service.statuses[s.id], value: service.state.values[s.key],
                          used: model.library.referencedSignalKeys.contains(s.key),
                          edit: { editing = s })
            }
            FlowLayout(spacing: layout.controlGap, lineSpacing: layout.controlGap, alignment: .leading) {
                Button(scaled: "Add Signal\u{2026}") { editing = Signal(name: "") }
                    .disabled(signals.count >= Signal.maxCount)
                Button(scaled: "Open Signal Files") { revealFiles() }
                    .help("The folder file signals read from: Shortcuts, scripts and cron can write files here")
            }
        } header: {
            SettingsHeader("Signals")
        } footer: {
            SettingsNote("DotStudio fetches a signal only while a When rule or a scene input uses it, at most every 5 minutes, and sends nothing but the address you give (with your location rounded to about 10 km only if it asks for {lat} and {lon}). API keys are kept in your Keychain.")
        }
        .sheet(item: $editing) { s in
            SignalEditorSheet(original: s, isNew: !(model.library.signals ?? []).contains { $0.id == s.id })
                .environmentObject(model)
                .environment(\.console, console)   // the sheet is its own root
                .adaptiveLayout()
        }
    }

    private func revealFiles() {
        let dir = SignalPolicy.filesDir(model.store.baseDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }
}

/// One signal: icon, name (+ AI), "api.waqi.info · 42 AQI · 3 min ago", a status dot, on/off.
struct SignalRow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    @ScaledLength(relativeTo: .title3) private var iconBox: CGFloat = 20
    @ScaledLength(relativeTo: .caption) private var dot: CGFloat = 8
    let signal: Signal
    let status: SignalService.Status?
    let value: SignalValue?
    let used: Bool
    let edit: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: layout.controlGap) {
            Image(systemName: signal.kind == .web ? "globe" : "doc.text")
                .scaledFont { .scaled(.title3, $0) }
                .foregroundStyle(.secondary)
                .frame(width: iconBox)
            Button(action: edit) {
                VStack(alignment: .leading, spacing: layout.labelGap) {
                    HStack(spacing: Space.xs) {
                        Text(signal.name).settingsText(.bodyEmphasis).lineLimit(2)
                        if signal.createdByAI { AIBadge() }
                    }
                    TimelineView(.periodic(from: .now, by: 60)) { ctx in
                        Text(detail(now: ctx.date))
                            .settingsText(.caption)
                            .foregroundStyle(problem != nil ? AnyShapeStyle(console ? ConsoleInk.signalInk : .orange)
                                                            : AnyShapeStyle(.secondary))
                            .wrapping()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit “\(signal.name)”")
            Circle().fill(dotColor).frame(width: dot, height: dot)
                .accessibilityLabel(problem ?? (fresh ? "Up to date" : "Idle"))
            if console {
                ConsoleSwitch(isOn: Binding(get: { signal.enabled }, set: { setEnabled($0) }))
                    .accessibilityLabel("\(signal.name) on")
            } else {
                Toggle("On", isOn: Binding(get: { signal.enabled }, set: { setEnabled($0) }))
                    .labelsHidden()
                    .formSwitchSize()
                    .accessibilityLabel("\(signal.name) on")
            }
        }
    }

    @Environment(\.consoleSettings) private var console

    private var fresh: Bool { value?.isFresh() == true && value?.error == nil }

    /// What's wrong, in a few words (nil = nothing).
    private var problem: String? {
        guard signal.enabled else { return nil }
        if signal.auth != nil {
            switch status?.key {
            case .needsReentry?, .missing?, .failed?: return SignalService.keyStatusText(status!.key!)
            default: break
            }
        }
        return value?.error ?? status?.error
    }

    private var dotColor: Color {
        if !signal.enabled || !used { return Color.secondary.opacity(0.4) }
        if problem != nil { return console ? ConsoleInk.amber : .orange }
        return fresh ? (console ? ConsoleInk.green : .green) : Color.secondary.opacity(0.4)
    }

    private func detail(now: Date) -> String {
        var parts = [signal.whereFrom]
        if !signal.enabled { parts.append("Off"); return parts.joined(separator: " · ") }
        if let v = value, v.hasValue { parts.append(v.display(type: signal.valueType, unit: signal.unit)) }
        if let at = value?.at, value?.hasValue == true {
            let mins = Int(max(0, now.timeIntervalSince1970 - at) / 60)
            parts.append(mins < 1 ? "just now" : mins < 60 ? "\(mins) min ago"
                         : RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: at), relativeTo: now))
        }
        if let p = problem { parts.append(p) }
        else if !used { parts.append("Not used yet") }
        else if value?.hasValue != true { parts.append("Waiting for the first value") }
        return parts.joined(separator: " · ")
    }

    private func setEnabled(_ on: Bool) {
        guard let i = model.library.signals?.firstIndex(where: { $0.id == signal.id }) else { return }
        model.library.signals?[i].enabled = on
        model.save()
    }
}

/// "AI" beside something an assistant made (like BetaTag, accent-tinted).
struct AIBadge: View {
    @Environment(\.console) private var console

    var body: some View {
        if console {
            // Console: a small printed tag, as the hub's (no accent outline)
            ConsoleTag(text: "AI").fixedSize().accessibilityLabel("Made by AI")
        } else {
            classic
        }
    }

    private var classic: some View {
        Label("AI", systemImage: "sparkles")
            .labelStyle(.titleAndIcon)
            .textRole(.badge)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1))
            .fixedSize()
            .accessibilityLabel("Made by AI")
    }
}

// MARK: - Add / edit

struct SignalEditorSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.layout) private var layout
    let original: Signal
    let isNew: Bool

    @State private var s: Signal
    @State private var usesKey: Bool
    @State private var key = ""
    @State private var keyState: SignalKeychain.Lookup?
    @State private var testing = false
    @State private var result: SignalFetchResult?
    @State private var problem: String?
    @State private var rangeLo: Double?
    @State private var rangeHi: Double?

    /// UI shots: a test result to show without fetching.
    static var demoResult: SignalFetchResult?

    init(original: Signal, isNew: Bool) {
        self.original = original
        self.isNew = isNew
        _s = State(initialValue: original)
        _usesKey = State(initialValue: original.auth != nil)
        _rangeLo = State(initialValue: original.range?.first)
        _rangeHi = State(initialValue: original.range?.last)
        _result = State(initialValue: Self.demoResult)
    }

    @Environment(\.console) private var console

    var body: some View {
        VStack(spacing: 0) {
            Text(isNew ? "Add Signal" : "Edit Signal")
                .textRole(console ? .consoleHeadline : .headline)
                .foregroundStyle(console ? AnyShapeStyle(ConsoleInk.ink) : AnyShapeStyle(.primary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], console ? Space.l : layout.cardPadding)
            Form {
                Section {
                    field("Name") { TextField("Name", text: $s.name, prompt: Text("Air quality")) }
                    choice("Comes from", $s.kind, [("The web", SignalKind.web), ("A file", SignalKind.file)], segmented: true)
                    if s.kind == .web {
                        field("URL") {
                            TextField("URL", text: Binding(get: { s.url ?? "" }, set: { s.url = $0 }), prompt: Text("https://…"))
                        }
                        Text("https only. {lat} and {lon} in the address use your location, rounded to about 10 km.")
                            .settingsText(.caption).foregroundStyle(.secondary).wrapping()
                    } else {
                        LabeledContent("File") {
                            HStack {
                                TextField("File", text: Binding(get: { s.file ?? "" }, set: { s.file = $0 }), prompt: Text("office.json"))
                                    .labelsHidden()
                                    .modifier(SignalFieldLook())
                                Button(scaled: "Reveal") { reveal() }
                            }
                        }
                        Text("A file in DotStudio's signal-files folder: JSON, or plain text with one number or word. Shortcuts, scripts and cron can write it.")
                            .settingsText(.caption).foregroundStyle(.secondary).wrapping()
                    }
                    field("Value at") {
                        TextField("Value at", text: Binding(get: { s.pointer ?? "" }, set: { s.pointer = $0.isEmpty ? nil : $0 }),
                                  prompt: Text("/data/aqi (empty: the whole thing)"))
                    }
                    HStack {
                        Button(scaled: testing ? "Testing…" : "Test") { test() }
                            .disabled(testing)
                        if let r = result {
                            Text(resultLine(r)).settingsText(.caption)
                                .foregroundStyle(r.ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(warning)).wrapping()
                        }
                    }
                    if let outline = result?.outline, !outline.isEmpty {
                        outlineList(outline)
                    }
                }
                if s.kind == .web {
                    Section {
                        Toggle("Sends an API key", isOn: $usesKey).formSwitchSize()
                            .onChange(of: usesKey) { _, on in
                                if on, s.auth == nil { s.auth = SignalAuth(placement: .header, name: "") }
                            }
                        if usesKey {
                            choice("Send it as", Binding(get: { s.auth?.placement ?? .header },
                                                         set: { s.auth = SignalAuth(placement: $0, name: s.auth?.name ?? "") }),
                                   [("A header", SignalAuth.Placement.header), ("A query parameter", SignalAuth.Placement.query)])
                            field("Name") {
                                TextField("Name", text: Binding(get: { s.auth?.name ?? "" },
                                                                set: { s.auth = SignalAuth(placement: s.auth?.placement ?? .header, name: $0) }),
                                          prompt: Text("X-API-Key"))
                            }
                            field("Key") { SecureField("Key", text: $key, prompt: Text(keyPrompt)) }
                            if let k = keyState, k != .found("") {
                                Text(keyLine(k)).settingsText(.caption)
                                    .foregroundStyle(k == .needsReentry || k == .missing ? AnyShapeStyle(warning) : AnyShapeStyle(.secondary))
                                    .wrapping()
                            }
                        }
                    } footer: {
                        if usesKey {
                            SettingsNote("The key is saved in your Keychain — never in DotStudio's files, and never shown to an assistant.")
                        }
                    }
                }
                Section {
                    choice("Value", $s.valueType, [("Number", SignalValueType.number), ("Yes / No", SignalValueType.bool),
                                                   ("Word", SignalValueType.string)])
                    if s.valueType == .number {
                        LabeledContent("Adjust") {
                            HStack(spacing: Space.xs) {
                                Spacer(minLength: 0)
                                Text("×").foregroundStyle(.secondary)
                                TextField("Scale", value: $s.scale, format: .number, prompt: Text("1")).labelsHidden()
                                    .multilineTextAlignment(.trailing).modifier(SignalFieldLook()).frame(maxWidth: layout.scaled(72))
                                Text("+").foregroundStyle(.secondary)
                                TextField("Offset", value: $s.offset, format: .number, prompt: Text("0")).labelsHidden()
                                    .multilineTextAlignment(.trailing).modifier(SignalFieldLook()).frame(maxWidth: layout.scaled(72))
                            }
                        }
                        field("Unit") {
                            TextField("Unit", text: Binding(get: { s.unit ?? "" }, set: { s.unit = $0.isEmpty ? nil : String($0.prefix(12)) }),
                                      prompt: Text("None"))
                        }
                        LabeledContent("Usual range") {
                            HStack(spacing: Space.xs) {
                                Spacer(minLength: 0)
                                TextField("Low", value: $rangeLo, format: .number, prompt: Text("Low")).labelsHidden()
                                    .multilineTextAlignment(.trailing).modifier(SignalFieldLook()).frame(maxWidth: layout.scaled(72))
                                Text("–").foregroundStyle(.secondary)
                                TextField("High", value: $rangeHi, format: .number, prompt: Text("High")).labelsHidden()
                                    .multilineTextAlignment(.trailing).modifier(SignalFieldLook()).frame(maxWidth: layout.scaled(72))
                            }
                        }
                        field("When missing") {
                            TextField("When missing", value: $s.defaultValue, format: .number, prompt: Text("0"))
                        }
                    }
                    if s.kind == .web {
                        choice("Check every", Binding(get: { s.pollMinutes ?? Signal.defaultPollMinutes }, set: { s.pollMinutes = $0 }),
                               [5.0, 10, 15, 30, 60, 180, 720].map { m in (m < 60 ? "\(Int(m)) min" : "\(Int(m / 60)) hr", m) })
                    }
                }
            }
            .settingsForm()   // Classic: the grouped Form; Console: its ruled sections (ConsoleSettingsKit)
            if console { ConsoleHairline() } else { Divider() }
            HStack(spacing: layout.controlGap) {
                if let problem {
                    Text(problem).settingsText(.caption).foregroundStyle(warning).wrapping()
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 0)
                }
                if console {
                    consoleButtons
                } else {
                    if !isNew { Button(scaled: "Delete") { delete() } }
                    Button(scaled: "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(scaled: isNew ? "Add" : "Save") { save() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, console ? Space.l : layout.cardPadding)
            .padding(.vertical, console ? Space.s : layout.cardPadding)
            // the Settings' Console text roles for the bar's caption (settingsText)
            .environment(\.consoleSettings, console)
        }
        .frame(minWidth: 480, idealWidth: layout.scaled(520), minHeight: 420, idealHeight: layout.scaled(620))
        .background(console ? ConsoleInk.panel : Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if original.auth != nil, !isNew {
                keyState = SignalService.shared.statuses[original.id]?.key
                    ?? (SignalKeychain.has(original.id) ? nil : .missing)
            }
        }
    }

    /// Console: Delete and Cancel as grey keys, Save (or Add) the orange one — the Settings
    /// sheet's Done.
    @ViewBuilder private var consoleButtons: some View {
        let pad = EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
        if !isNew {
            Button { delete() } label: { Text("Delete").textRole(.consoleKey) }
                .buttonStyle(.keycap(padding: pad))
        }
        Button { dismiss() } label: { Text("Cancel").textRole(.consoleKey) }
            .buttonStyle(.keycap(padding: pad))
            .keyboardShortcut(.cancelAction)
        Button { save() } label: { Text(isNew ? "Add" : "Save").textRole(.consoleKey) }
            .buttonStyle(.keycap(.signal, padding: pad))
            .keyboardShortcut(.defaultAction)
    }

    /// A warning's colour: orange (Classic), the signal ink (Console, readable on the panel).
    private var warning: Color { console ? ConsoleInk.signalInk : .orange }

    /// A labelled text field: the Form labels it (Classic); Console prints the label as a row
    /// and the field as a recessed well.
    @ViewBuilder private func field<F: View>(_ label: String, @ViewBuilder _ f: () -> F) -> some View {
        if console {
            LabeledContent(label) {
                f().labelsHidden().modifier(SignalFieldLook())
                    .frame(maxWidth: layout.scaled(280))
            }
        } else {
            f()
        }
    }

    /// A choice: the stock pop-up (or segmented control) in Classic; a Console key with a menu
    /// (or keycaps in a well) in Console.
    @ViewBuilder private func choice<V: Hashable>(_ title: String, _ selection: Binding<V>,
                                                  _ options: [(title: String, value: V)],
                                                  segmented: Bool = false) -> some View {
        if console {
            LabeledContent(title) {
                if segmented {
                    ConsoleSegments(title: title, selection: selection, options: options)
                } else {
                    ConsoleMenuPicker(title: title, selection: selection, options: options)
                }
            }
        } else if segmented {
            Picker(title, selection: selection) {
                ForEach(options.indices, id: \.self) { i in Text(options[i].title).tag(options[i].value) }
            }
            .pickerStyle(.segmented)
        } else {
            Picker(title, selection: selection) {
                ForEach(options.indices, id: \.self) { i in Text(options[i].title).tag(options[i].value) }
            }
        }
    }

    private var keyPrompt: String {
        switch keyState {
        case .needsReentry?: return "Enter the key again"
        case .missing?, nil: return isNew || original.auth == nil ? "Paste the key" : "Saved — paste to replace"
        default: return "Saved — paste to replace"
        }
    }

    private func keyLine(_ k: SignalKeychain.Lookup) -> String {
        switch k {
        case .needsReentry: return "Key needs re-entry — this version of DotStudio can't read the one saved before. Paste it again."
        case .missing: return "No key saved yet."
        case .failed(let st): return "Keychain error \(st)."
        case .found: return "Key saved."
        }
    }

    private func resultLine(_ r: SignalFetchResult) -> String {
        var parts: [String] = []
        if r.ok, let v = r.value { parts.append("Reads " + v.display(type: s.valueType, unit: s.unit)) }
        else { parts.append(r.error ?? "No value") }
        if let st = r.status { parts.append("HTTP \(st)") }
        if let ms = r.ms { parts.append("\(ms) ms") }
        if let b = r.bytes { parts.append(b >= 1024 ? String(format: "%.1f KB", Double(b) / 1024) : "\(b) bytes") }
        return parts.joined(separator: " · ")
    }

    /// The document's leaves; clicking one makes it the value.
    private func outlineList(_ items: [SignalOutlineItem]) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text("Click a value to use it").settingsText(.caption).foregroundStyle(.secondary)
            ForEach(items.prefix(20), id: \.pointer) { item in
                Button {
                    s.pointer = item.pointer
                    if case .string = item.value { s.valueType = .string }
                    if case .bool = item.value { s.valueType = .bool }
                    if case .number = item.value { s.valueType = .number }
                } label: {
                    HStack(spacing: Space.xs) {
                        Image(systemName: s.pointer == item.pointer ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(s.pointer == item.pointer ? (console ? ConsoleInk.signal : Color.accentColor) : .secondary)
                        // Console: the pointer in the mono face (Classic: the caption, monospaced)
                        if console {
                            Text(item.pointer.isEmpty ? "(all)" : item.pointer).textRole(.consoleMono).lineLimit(1)
                        } else {
                            Text(item.pointer.isEmpty ? "(all)" : item.pointer).textRole(.caption).monospaced().lineLimit(1)
                        }
                        Spacer(minLength: Space.xs)
                        Text(leaf(item.value)).settingsText(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func leaf(_ v: JSONValue) -> String {
        switch v {
        case .number(let d): return SignalValue.format(d)
        case .integer(let i): return String(i)
        case .bool(let b): return b ? "true" : "false"
        case .string(let s): return "“\(s)”"
        default: return ""
        }
    }

    /// What would be saved.
    private var draft: Signal {
        var d = s
        if !usesKey || d.kind == .file { d.auth = nil }
        if let lo = rangeLo, let hi = rangeHi { d.range = [lo, hi] } else { d.range = nil }
        return d
    }

    private func test() {
        let d = draft
        let problems = SignalPolicy.validate(d, forAI: false).filter { !$0.contains("needs a name") }
        if let p = problems.first { problem = p; return }
        problem = nil
        testing = true
        let done: (SignalFetchResult) -> Void = { r in testing = false; result = r }
        if d.kind == .web, d.auth != nil, !key.isEmpty {
            // The key just typed (not saved yet).
            SignalFetcher.fetch(d, secret: key, location: model.library.signalLocation, forAI: false) { r in
                DispatchQueue.main.async { done(r) }
            }
        } else {
            SignalService.shared.test(d, forAI: false, interactive: true, completion: done)
        }
    }

    private func save() {
        let d = draft
        var lib = model.library
        if let why = lib.upsertSignal(d, forAI: false) { problem = why; return }
        if d.auth != nil, !key.isEmpty {
            let st = SignalKeychain.save(key, for: d.id)
            guard st == errSecSuccess else { problem = "Couldn't save the key in the Keychain (\(st))."; return }
        }
        if d.auth == nil, original.auth != nil { SignalKeychain.delete(d.id) }
        model.library = lib
        model.save()
        SignalService.shared.refresh(d.id)
        dismiss()
    }

    private func delete() {
        var lib = model.library
        if let why = lib.deleteSignal(original.id, force: true) { problem = why; return }
        SignalKeychain.delete(original.id)
        model.library = lib
        model.save()
        dismiss()
    }

    private func reveal() {
        let dir = SignalPolicy.filesDir(model.store.baseDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }
}

/// A text field in the signal editor: as the Form draws it (Classic), or plain text in a
/// recessed well with an orange edge while typing (Console — the inspector's field).
private struct SignalFieldLook: ViewModifier {
    @Environment(\.console) private var console
    func body(content: Content) -> some View {
        if console { content.modifier(InspectorTextFieldStyle()) } else { content }
    }
}
