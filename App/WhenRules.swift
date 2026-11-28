//  WhenRules.swift — "When ⟨condition⟩, play ⟨style⟩" on the Screensaver card (docs/signals-design.md
//  §7): the When key (its menu and its popover editor), the sentence editor, and AppModel's rule
//  edits. The rules are stored in library.json (Library.rules, Shared/Signals/PlayRule.swift); the
//  app's SignalService decides which one plays and every host follows its lease.
//  Console (\.console): the popover on the panel colour, rules as ruled rows with a printed
//  tag, a Console switch and an edit key; the sentence editor's pop-ups, fields and buttons
//  as keys and wells (the Signal editor's look). Classic unchanged.

import SwiftUI

// MARK: - Model edits

extension AppModel {
    /// Add or replace a rule (the user's own). nil = saved; else why not.
    @discardableResult
    func saveRule(_ r: PlayRule) -> String? {
        var lib = library
        if let why = lib.upsertRule(r) { return why }
        Breadcrumbs.note("When rule saved: \(r.name)")
        library = lib
        save()
        SignalService.shared.evaluate()
        return nil
    }

    func deleteRule(_ id: UUID) {
        guard library.deleteRule(id) else { return }
        save()
        SignalService.shared.evaluate()
    }

    func setRuleEnabled(_ id: UUID, _ on: Bool) {
        guard let i = library.rules?.firstIndex(where: { $0.id == id }) else { return }
        library.rules?[i].enabled = on
        save()
        SignalService.shared.evaluate()
    }
}

// MARK: - The card's key

/// When · "Snow day" / "2 rules" / "Off": its LED lit while a rule plays. The menu toggles each
/// rule and opens the editor.
struct WhenKey: View {
    @EnvironmentObject var model: AppModel
    @State private var editing = false

    var body: some View {
        let rules = model.library.rules ?? []
        let active = model.activeRule
        let values: [String] = active.map { [RuleText.short($0, in: model.library), "On"] }
            ?? (rules.isEmpty ? ["Off"] : [rules.count == 1 ? "1 rule" : "\(rules.count) rules", "\(rules.count)"])
        return DropdownMenu(title: "When rules") {
            Self.entries(model) { DispatchQueue.main.async { editing = true } }
        } label: {
            PanelKeyLabel(symbol: "arrow.triangle.branch", title: "When", values: values, indicator: .menuLED(active != nil))
        }
        .panelKeyMenu()
        .help(active.map { "Playing now because of “\(RuleText.short($0, in: model.library))” — \(RuleText.condition($0.when, in: model.library))" }
              ?? "Play a style when something happens — snow, low battery, a value you watch")
        .accessibilityLabel("When rules")
        .accessibilityValue(values[0])
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            WhenRulesEditor()
                .adaptiveLayout()
        }
    }

    /// The key's menu: Edit When Rules…, then each rule as a switch.
    @MenuBuilder
    static func entries(_ model: AppModel, edit: @escaping () -> Void) -> [MenuEntry] {
        let rules = model.library.rules ?? []
        MenuEntry.button("Edit When Rules\u{2026}", edit)
        if !rules.isEmpty {
            MenuEntry.section("Rules") {
                rules.map { r in
                    MenuEntry.toggle(RuleText.short(r, in: model.library) + " \u{2192} " + playName(r, model),
                                     isOn: r.enabled) { model.setRuleEnabled(r.id, $0) }
                }
            }
        }
    }

    private static func playName(_ r: PlayRule, _ model: AppModel) -> String {
        let names = r.play.compactMap { model.preset($0)?.name }
        return names.count <= 1 ? (names.first ?? "—") : "\(names.count) styles"
    }
}

// MARK: - The editor (a popover)

struct WhenRulesEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    @Environment(\.console) private var console
    /// The rule being written (a new one, or a copy of one to change).
    @State private var draft: RuleDraft?

    var body: some View {
        let rules = model.library.rules ?? []
        let width = layout.popoverWidth
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: layout.labelGap) {
                Text("When Rules").textRole(console ? .consoleHeadline : .headline).wrapping()
                Text("Play a style when something happens. The first rule that matches wins; a display with its own style keeps it.")
                    .textRole(console ? .consoleBodySmall : .caption).foregroundStyle(.secondary).wrapping()
            }
            .padding(layout.cardPadding)
            if console { ConsoleHairline() } else { Divider() }
            ScrollView {
                VStack(alignment: .leading, spacing: layout.itemGap) {
                    if rules.isEmpty && draft == nil {
                        Text("No rules yet.").textRole(console ? .consoleBody : .body).foregroundStyle(.secondary)
                    }
                    ForEach(rules) { r in
                        if draft?.id == r.id {
                            RuleSentenceEditor(draft: binding, onDone: { draft = nil })
                        } else {
                            RuleChipRow(rule: r, active: model.activeRule?.id == r.id,
                                        edit: { draft = RuleDraft(r, in: model.library) })
                        }
                    }
                    if let d = draft, !rules.contains(where: { $0.id == d.id }) {
                        RuleSentenceEditor(draft: binding, onDone: { draft = nil })
                    }
                    if draft == nil {
                        Button(scaled: "Add Rule\u{2026}") { draft = RuleDraft(new: model.library) }
                            .modifier(RuleKeyStyle())
                            .disabled(rules.count >= PlayRule.maxCount || model.library.presets.isEmpty)
                    }
                }
                .padding(layout.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: width.lowerBound, idealWidth: min(max(layout.scaled(440), width.lowerBound), width.upperBound),
               maxWidth: width.upperBound, minHeight: layout.scaled(240), idealHeight: layout.scaled(380), maxHeight: .infinity)
        .modifier(WhenConsolePanel())
    }

    private var binding: Binding<RuleDraft> {
        Binding(get: { draft ?? RuleDraft(new: model.library) }, set: { draft = $0 })
    }
}

/// One rule as a chip: "❄ Snow day → Golden Hour", its sentence, on/off, edit.
struct RuleChipRow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    @Environment(\.console) private var console
    let rule: PlayRule
    let active: Bool
    let edit: () -> Void

    var body: some View {
        if console { consoleBody } else { classicBody }
    }

    /// Console: a ruled row — the rule as a printed tag (its symbol, "Snow day → Aurora"; an
    /// orange edge and a lit PLAYING light while it plays), its sentence under it in the legend
    /// grey, a Console switch and an edit key at the end.
    private var consoleBody: some View {
        let lib = model.library
        let names = rule.play.compactMap { model.preset($0)?.name }
        let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
        return HStack(alignment: .center, spacing: layout.controlGap) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                ReflowStack(rowAlignment: .center, columnAlignment: .leading, spacing: Space.xs) {
                    Label {
                        Text(RuleText.short(rule, in: lib) + " \u{2192} " + (names.count == 1 ? names[0] : "\(names.count) styles"))
                            .lineLimit(2)
                    } icon: {
                        Image(systemName: RuleText.symbol(rule, in: lib)).foregroundStyle(ConsoleInk.legend)
                    }
                    .textRole(.consoleBodySmallEmphasis)
                    .foregroundStyle(ConsoleInk.ink)
                    .padding(.horizontal, Space.xs)
                    .padding(.vertical, Space.xxs)
                    .background(shape.fill(active ? ConsoleInk.signal.opacity(0.16) : ConsoleInk.keyFace))
                    .overlay(shape.strokeBorder(active ? ConsoleInk.signal : ConsoleInk.hairline, lineWidth: 1))
                    .opacity(rule.enabled ? 1 : 0.55)
                    if active {
                        ConsoleLED(on: true, color: ConsoleInk.signal, label: "Playing")
                    }
                }
                Text("When " + RuleText.condition(rule.when, in: lib))
                    .textRole(.consoleBodySmall).foregroundStyle(ConsoleInk.legend).wrapping()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ConsoleSwitch(isOn: Binding(get: { rule.enabled }, set: { model.setRuleEnabled(rule.id, $0) }))
                .accessibilityLabel("\(rule.name) on")
            Button(action: edit) {
                Image(systemName: "pencil").scaledFont { .scaled(points: 11, $0, weight: .semibold) }
            }
            .buttonStyle(.keycap(padding: HubMetrics.squareKey))
            .help("Change this rule").accessibilityLabel("Edit \(rule.name)")
        }
        .padding(.bottom, Space.s)
        .overlay(alignment: .bottom) { ConsoleHairline() }
    }

    private var classicBody: some View {
        let lib = model.library
        let names = rule.play.compactMap { model.preset($0)?.name }
        return HStack(alignment: .center, spacing: layout.controlGap) {
            VStack(alignment: .leading, spacing: layout.labelGap) {
                HStack(spacing: Space.xs) {
                    Label {
                        Text(RuleText.short(rule, in: lib) + " \u{2192} " + (names.count == 1 ? names[0] : "\(names.count) styles"))
                            .lineLimit(2)
                    } icon: {
                        Image(systemName: RuleText.symbol(rule, in: lib))
                    }
                    .textRole(.bodyEmphasis)
                    .padding(.horizontal, Space.xs)
                    .padding(.vertical, Space.xxs)
                    .background(Capsule().fill(active ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06)))
                    .opacity(rule.enabled ? 1 : 0.55)
                    if active {
                        Text("Playing").textRole(.badge).foregroundStyle(Color.accentColor)
                    }
                }
                Text("When " + RuleText.condition(rule.when, in: lib))
                    .textRole(.caption).foregroundStyle(.secondary).wrapping()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("On", isOn: Binding(get: { rule.enabled }, set: { model.setRuleEnabled(rule.id, $0) }))
                .toggleStyle(.switch).labelsHidden().adaptiveControlSize(.mini)
                .accessibilityLabel("\(rule.name) on")
            Button(action: edit) { Image(systemName: "pencil") }
                .buttonStyle(.borderless).help("Change this rule").accessibilityLabel("Edit \(rule.name)")
        }
    }
}

// MARK: - The sentence editor

/// What the sentence editor holds: one test, a time of day and one style (the common rule). A
/// rule with more (made by an assistant) keeps its other tests when only the style or name changes.
struct RuleDraft: Equatable {
    var id: UUID
    var name: String
    var signal: String
    var op: RuleOp
    var number: Double
    var words: Set<String>
    var yes: Bool
    var text: String
    var timeOfDay: String?
    var style: UUID?
    var hold: Double?
    var extraClauses: [RuleClause] = []
    var enabled = true

    init(new lib: Library) {
        id = UUID(); name = ""; signal = "weather.condition"; op = .in; number = 0
        words = ["snow"]; yes = true; text = ""; timeOfDay = nil
        style = lib.presets.first?.id
    }

    init(_ r: PlayRule, in lib: Library) {
        self.init(new: lib)
        id = r.id; name = r.name; timeOfDay = r.when.timeOfDay; style = r.play.first; hold = r.holdMinutes; enabled = r.enabled
        let cs = r.when.clauses
        guard let c = cs.first else { return }
        extraClauses = Array(cs.dropFirst())
        signal = c.signal; op = c.op
        switch c.value {
        case .number(let d): number = d
        case .integer(let i): number = Double(i)
        case .bool(let b): yes = b
        case .string(let s): words = [s]; text = s
        default: break
        }
        if let vs = c.values {
            let ws = vs.compactMap { j -> String? in if case .string(let s) = j { return s } else { return nil } }
            if !ws.isEmpty { words = Set(ws) }
            if case .number(let d)? = vs.first { number = d }
        }
    }

    func rule(in lib: Library) -> PlayRule {
        let type = lib.signalInfo(signal)?.type ?? .number
        let clause: RuleClause
        switch type {
        case .number: clause = RuleClause(signal: signal, op: op == .lt ? .lt : .gt, value: .number(number))
        case .bool: clause = RuleClause(signal: signal, op: .eq, value: .bool(yes))
        case .string:
            if lib.signalInfo(signal)?.options != nil {
                let ws = words.sorted()
                clause = ws.count == 1 ? RuleClause(signal: signal, op: .eq, value: .string(ws[0]))
                    : RuleClause(signal: signal, op: .in, values: ws.map { .string($0) })
            } else {
                clause = RuleClause(signal: signal, op: .eq, value: .string(text.trimmingCharacters(in: .whitespaces)))
            }
        }
        var r = PlayRule(id: id, name: name, enabled: enabled,
                         when: RuleCondition(all: [clause] + extraClauses, timeOfDay: timeOfDay),
                         play: style.map { [$0] } ?? [], holdMinutes: hold)
        if r.name.trimmingCharacters(in: .whitespaces).isEmpty { r.name = String(RuleText.clause(clause, in: lib).prefix(60)) }
        return r
    }
}

/// [Signal ▾] [is above ▾] [value] [any time ▾] → play [Style ▾], then Save.
struct RuleSentenceEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    @Environment(\.console) private var console
    @Binding var draft: RuleDraft
    let onDone: () -> Void
    @State private var problem: String?

    var body: some View {
        let lib = model.library
        let info = lib.signalInfo(draft.signal)
        VStack(alignment: .leading, spacing: layout.controlGap) {
            FlowLayout(spacing: layout.controlGap, lineSpacing: layout.controlGap, alignment: .leading) {
                Text("When").textRole(console ? .consoleBody : .body)
                DropdownMenu(title: "Signal") {
                    RuleMenus.signals(lib) { pick($0) }
                } label: { RuleMenuLabel(title: info?.name ?? "Signal") }
                .modifier(RuleMenuStyle())
                .fixedSize()
                valueControls(info)
                DropdownMenu(title: "Time of day") {
                    RuleMenus.timeOfDay { draft.timeOfDay = $0 }
                } label: { RuleMenuLabel(title: timeLabel) }
                .modifier(RuleMenuStyle())
                .fixedSize()
                Text("play").textRole(console ? .consoleBody : .body)
                DropdownMenu(title: "Style") {
                    StyleMenu.entries(model, current: draft.style) { draft.style = $0 }
                } label: { RuleMenuLabel(title: draft.style.flatMap { model.preset($0)?.name } ?? "Style") }
                .modifier(RuleMenuStyle())
                .fixedSize()
            }
            if !draft.extraClauses.isEmpty {
                Text("…and \(draft.extraClauses.count) more test\(draft.extraClauses.count == 1 ? "" : "s"), kept as they are.")
                    .textRole(console ? .consoleBodySmall : .caption).foregroundStyle(.secondary).wrapping()
            }
            TextField("Name (optional)", text: $draft.name)
                .modifier(RuleFieldStyle())
            if let problem {
                Text(problem).textRole(console ? .consoleBodySmall : .caption)
                    .foregroundStyle(console ? ConsoleInk.signalInk : .orange).wrapping()
            }
            HStack(spacing: layout.controlGap) {
                if lib.rules?.contains(where: { $0.id == draft.id }) == true {
                    Button(scaled: "Delete") { model.deleteRule(draft.id); onDone() }
                        .modifier(RuleKeyStyle())
                }
                Spacer(minLength: 0)
                Button(scaled: "Cancel") { onDone() }
                    .modifier(RuleKeyStyle())
                Button(scaled: "Save") {
                    if let why = model.saveRule(draft.rule(in: lib)) { problem = why } else { onDone() }
                }
                .modifier(RuleKeyStyle(tint: .signal))
                .keyboardShortcut(.defaultAction)
                .disabled(draft.style == nil)
            }
        }
        .padding(layout.controlGap)
        .background {
            if console {
                // Console: a module on the surface colour with a hairline edge
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(ConsoleInk.surface)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(ConsoleInk.hairline, lineWidth: 1))
            } else {
                RoundedRectangle(cornerRadius: Radius.s, style: .continuous).fill(Color.primary.opacity(0.05))
            }
        }
    }

    private var timeLabel: String {
        switch draft.timeOfDay { case "day": return "by day"; case "night": return "only at night"; default: return "any time" }
    }

    private func pick(_ id: String) {
        draft.signal = id
        let info = model.library.signalInfo(id)
        if info?.type == .number, let r = info?.range { draft.number = (r.lowerBound + (r.upperBound - r.lowerBound) / 2).rounded() }
        if info?.type == .number { draft.op = .gt }
        if let opts = info?.options, !opts.contains(where: draft.words.contains) { draft.words = [opts[0]] }
    }

    @ViewBuilder
    private func valueControls(_ info: (name: String, type: SignalValueType, unit: String?, range: ClosedRange<Double>?, options: [String]?)?) -> some View {
        switch info?.type ?? .number {
        case .number:
            DropdownMenu(title: "Comparison") {
                MenuEntry.button("is above") { draft.op = .gt }
                MenuEntry.button("is below") { draft.op = .lt }
            } label: { RuleMenuLabel(title: draft.op == .lt ? "is below" : "is above") }
            .modifier(RuleMenuStyle())
            .fixedSize()
            HStack(spacing: Space.xxs) {
                TextField("Value", value: $draft.number, format: .number)
                    .modifier(RuleFieldStyle())
                    .frame(width: layout.scaled(64))
                if let u = info?.unit, !u.isEmpty { Text(u).textRole(console ? .consoleBody : .body).foregroundStyle(.secondary) }
            }
        case .bool:
            DropdownMenu(title: "Value") {
                MenuEntry.button("is yes") { draft.yes = true }
                MenuEntry.button("is no") { draft.yes = false }
            } label: { RuleMenuLabel(title: draft.yes ? "is yes" : "is no") }
            .modifier(RuleMenuStyle())
            .fixedSize()
        case .string:
            if let opts = info?.options {
                DropdownMenu(title: "Values") {
                    opts.map { o in
                        MenuEntry.toggle(RuleText.word(o), isOn: draft.words.contains(o)) { on in
                            if on { draft.words.insert(o) } else if draft.words.count > 1 { draft.words.remove(o) }
                        }
                    }
                } label: { RuleMenuLabel(title: draft.words.count > 1 ? "is one of" : "is") }
                .modifier(RuleMenuStyle())
                .fixedSize()
                Text(draft.words.sorted().map(RuleText.word).joined(separator: " or "))
                    .textRole(console ? .consoleBody : .body).foregroundStyle(.secondary)
            } else {
                Text("is").textRole(console ? .consoleBody : .body)
                TextField("Word", text: $draft.text)
                    .modifier(RuleFieldStyle())
                    .frame(width: layout.scaled(96))
            }
        }
    }
}

// MARK: - Console pieces

/// The rule editor's menus as items (MenuEntry): its pop-ups in either look, and UIShots.
enum RuleMenus {
    /// When ▸ the signal: the built-ins, then the user's own.
    @MenuBuilder
    static func signals(_ lib: Library, pick: @escaping (String) -> Void) -> [MenuEntry] {
        MenuEntry.section("Built in") {
            BuiltInSignals.all.map { b in MenuEntry.button(b.name) { pick(b.id) } }
        }
        let mine = lib.signals ?? []
        if !mine.isEmpty {
            MenuEntry.section("Yours") { mine.map { s in MenuEntry.button(s.name) { pick(s.key) } } }
        }
    }

    /// …any time / by day / only at night.
    @MenuBuilder
    static func timeOfDay(_ set: @escaping (String?) -> Void) -> [MenuEntry] {
        MenuEntry.button("any time") { set(nil) }
        MenuEntry.button("by day") { set("day") }
        MenuEntry.button("only at night") { set("night") }
    }
}

/// Console: the popover on the panel colour with the Console inks (Classic: the popover's own).
private struct WhenConsolePanel: ViewModifier {
    @Environment(\.console) private var console
    func body(content: Content) -> some View {
        if console {
            content
                .background(ConsoleInk.panel)
                .presentationBackground(ConsoleInk.panel)
                .foregroundStyle(ConsoleInk.ink, ConsoleInk.legend)
        } else {
            content
        }
    }
}

/// A pop-up's title: Classic's plain title (the stock pop-up draws its own arrows); Console's
/// title and up-down chevron on a key (ConsoleMenuPicker's look).
private struct RuleMenuLabel: View {
    let title: String
    @Environment(\.console) private var console
    var body: some View {
        if console {
            HStack(spacing: Space.xs) {
                Text(title).textRole(.consoleBody).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ConsoleInk.legend)
            }
        } else {
            Text(title)
        }
    }
}

/// Console: a pop-up as a grey key (its own chevron, no stock indicator).
private struct RuleMenuStyle: ViewModifier {
    @Environment(\.console) private var console
    func body(content: Content) -> some View {
        if console {
            content
                .menuStyle(.button)
                .buttonStyle(.keycap(padding: HubMetrics.smallKey))
                .menuIndicator(.hidden)
        } else {
            content
        }
    }
}

/// Console: a button as a key (`tint` for Save); Classic's stock button.
private struct RuleKeyStyle: ViewModifier {
    var tint: ConsoleKeycapStyle.Tint = .plain
    @Environment(\.console) private var console
    func body(content: Content) -> some View {
        if console {
            content.buttonStyle(.keycap(tint, padding: HubMetrics.smallKey))
                .environment(\.consoleSettings, true)   // Button(scaled:) prints a key legend
        } else {
            content
        }
    }
}

/// A text field: the stock rounded field (Classic); the inspector's recessed well (Console).
private struct RuleFieldStyle: ViewModifier {
    @Environment(\.console) private var console
    func body(content: Content) -> some View {
        if console { content.modifier(InspectorTextFieldStyle()) } else { content.textFieldStyle(.roundedBorder) }
    }
}
