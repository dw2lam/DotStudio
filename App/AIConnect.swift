//  AIConnect.swift — connecting AI assistants to DotStudio's MCP server (dotstudio-mcp, inside
//  this app): the state and actions Settings ▸ AI (AISettingsSection) and the library window's
//  MCP toolbar button share, so both show the same status and act the same way.

import AppKit
import SwiftUI

final class AIConnect: ObservableObject {
    static let shared = AIConnect()

    /// What the user lets the AI do (<store>/ai-settings.json).
    @Published private(set) var settings = AISettings()
    @Published private(set) var installedInDesktop = false
    /// `claude mcp add` wrote this helper into Claude Code's config (~/.claude.json, any scope).
    @Published private(set) var installedInClaudeCode = false
    var anyAssistantConnected: Bool { installedInDesktop || installedInClaudeCode }
    @Published private(set) var desktopStatus: String?
    @Published private(set) var desktopFailed = false
    /// Which copy button just copied ("code", "json", "config"), for its "Copied" title.
    @Published private(set) var copied: String?
    /// "More in Settings…": bumped to have the Settings window scroll to its AI section.
    @Published var revealRequest = 0

    /// The helper every client launches.
    static var helperPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/dotstudio-mcp").path
    }

    /// The helper is in this copy of the app.
    var helperFound: Bool { FileManager.default.isExecutableFile(atPath: Self.helperPath) }

    /// Clients store the helper's path: it must survive the app being moved (not run from the
    /// disk image, Downloads or a translocated copy).
    var pathIsStable: Bool {
        if let pinned { return pinned.stable }
        let p = Bundle.main.bundlePath
        return p.hasPrefix("/Applications/") || p.hasPrefix(SharedStore.realHome.path + "/Applications/")
    }

    static var claudeCodeCommand: String { ClaudeDesktopConfig.claudeCodeCommand(command: helperPath) }

    // The how-to, shared by the MCP popover and Settings ▸ AI.
    static let restartHint = "Quit and reopen Claude Desktop. Claude Code picks DotStudio up in a new session. In Cursor, VS Code and other apps, paste the JSON into their MCP settings."
    static let examplePrompt = "Make me a calm ocean screensaver with a clock, and show me a preview."
    static let libraryHint = "New styles appear in your Library, ready to play. When the AI changes your screensaver or wallpaper, a small notice shows what it did, with Undo."
    static var configJSON: String { ClaudeDesktopConfig.snippet(command: helperPath) }
    /// The same JSON on one line, for showing in a small space (Copy still copies `configJSON`).
    static var configJSONCompact: String {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(configJSON.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return configJSON }
        return String(decoding: data, as: UTF8.self)
    }

    // Blender: optional, recommended. With it the AI can make photoreal film scenes like Commute
    // (dotstudio-mcp's film tools, FilmPaths in MCP/Film.swift); DotStudio never installs it.
    static let blenderMinimum = "5.1"
    static let blenderDownload = URL(string: "https://www.blender.org/download/")!
    static let blenderHint = "Free, about 1 GB. With Blender, the AI can also make photoreal film scenes like Commute, rendered on your Mac. Everything else works without it."

    // The recommended setup and what to ask, shared by the MCP popover and Settings ▸ AI.
    static let assistantHint = "Claude Desktop or Claude Code is what DotStudio is tested with. Cursor, VS Code, Codex and other MCP apps work too."
    static let weatherHint = "Lets scenes follow your real weather: rain, snow, storms, fog. Uses your approximate location."
    /// What an assistant can do, with roughly how long each takes.
    static let abilities: [(title: String, detail: String)] = [
        ("A screensaver or wallpaper", "From DotStudio's scenes and looks. Seconds, with a preview."),
        ("A brand-new scene", "Written as a GPU shader and checked for speed and battery. About a minute."),
        ("A photoreal film scene", "Built in Blender. Stills take minutes; the moving loop renders in the background, often overnight. Needs Blender."),
        ("Your settings", "Which style plays where, per display, the schedule, weather and more."),
    ]
    static let examples = [
        "Make me a calm ocean screensaver with a clock, and show me a preview.",
        "Put something warm on my second display at night.",
        "Make a photoreal film scene of a rainy café window. Show me stills first.",
    ]

    /// Blender's version if installed (Applications or ~/Applications), from its Info.plist —
    /// never launches it. Same places dotstudio-mcp looks (FilmPaths.blenderApps).
    @Published private(set) var blenderVersion: String?
    @Published private(set) var blenderFound = false

    var blenderReady: Bool { blenderFound && Self.versionAtLeast(blenderVersion, Self.blenderMinimum) }

    var blenderStatus: String {
        if !blenderFound { return "Blender not installed" }
        if !blenderReady { return "Blender \(blenderVersion ?? "") found; film scenes need \(Self.blenderMinimum) or newer" }
        return "Blender \(blenderVersion ?? "") ready for film scenes"
    }

    func refreshBlender() {
        let apps = ["/Applications/Blender.app", SharedStore.realHome.path + "/Applications/Blender.app"]
        for app in apps where FileManager.default.isExecutableFile(atPath: app + "/Contents/MacOS/Blender") {
            blenderFound = true
            blenderVersion = NSDictionary(contentsOfFile: app + "/Contents/Info.plist")?["CFBundleShortVersionString"] as? String
            return
        }
        blenderFound = false
        blenderVersion = nil
    }

    func getBlender() { NSWorkspace.shared.open(Self.blenderDownload) }

    static func versionAtLeast(_ v: String?, _ min: String) -> Bool {
        guard let v else { return false }
        let a = v.split(separator: ".").compactMap { Int($0) }, b = min.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }

    /// Offscreen renders (UIShots) pin what the popover shows — connected apps, the app's
    /// location, Blender's version — instead of reading this Mac. nil = the real state.
    struct Pinned {
        var desktop = false
        var code = false
        var stable = true
        var blender: String? = AIConnect.blenderMinimum
    }
    var pinned: Pinned? {
        didSet {
            desktopStatus = nil
            desktopFailed = false
            copied = nil
            if let pinned {
                installedInDesktop = pinned.desktop
                installedInClaudeCode = pinned.code
                blenderFound = pinned.blender != nil
                blenderVersion = pinned.blender
            }
        }
    }

    /// Re-read the settings and whether Claude Desktop lists this helper (on appear).
    func refresh(store: URL) {
        settings = AISettings.load(store: store)
        if pinned != nil { return }
        installedInDesktop = ClaudeDesktopConfig.installedCommand() == Self.helperPath
        let codeConfig = SharedStore.realHome.appendingPathComponent(".claude.json")
        installedInClaudeCode = (try? String(contentsOf: codeConfig, encoding: .utf8))?.contains(Self.helperPath) ?? false
        refreshBlender()
    }

    func setAllowPlaybackChanges(_ on: Bool, store: URL) {
        settings.allowPlaybackChanges = on
        settings.save(store: store)
    }

    func allowPlaybackBinding(store: URL) -> Binding<Bool> {
        Binding(get: { self.settings.allowPlaybackChanges }, set: { self.setAllowPlaybackChanges($0, store: store) })
    }

    /// "Let AI add live data signals" (Signals; the AI never sees their keys either way).
    func allowSignalsBinding(store: URL) -> Binding<Bool> {
        Binding(get: { self.settings.allowSignals }, set: { self.settings.allowSignals = $0; self.settings.save(store: store) })
    }

    func addToDesktop() {
        switch ClaudeDesktopConfig.install(command: Self.helperPath) {
        case .success(.unchanged):
            desktopFailed = false
            desktopStatus = "Already added. Restart Claude Desktop if it doesn't list DotStudio."
        case .success(.added(let backup)):
            desktopFailed = false
            desktopStatus = "Added. Quit and reopen Claude Desktop to connect."
                + (backup != nil ? " Your previous settings were backed up next to the file." : "")
        case .failure(let f):
            desktopFailed = true
            desktopStatus = f.description
        }
        installedInDesktop = ClaudeDesktopConfig.installedCommand() == Self.helperPath
    }

    func revealDesktopConfig() {
        let url = ClaudeDesktopConfig.defaultURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    func copy(_ s: String, _ tag: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        copied = tag
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in if self?.copied == tag { self?.copied = nil } }
    }

    func openGuidesFolder(store: URL) {
        let dir = AIStore.guidesDir(store)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
}

// MARK: - The library window's MCP button

/// Toolbar item: "MCP" — a popover to connect an assistant, as Settings ▸ AI does.
struct MCPToolbarButton: View {
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Label("MCP", systemImage: "point.3.connected.trianglepath.dotted")
        }
        .help("MCP (beta): let Claude or any MCP app build screensavers in DotStudio")
        .accessibilityLabel("MCP, beta")
        .accessibilityHint("Connect Claude or another MCP app to DotStudio")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            MCPPopover(close: { open = false })
                .adaptiveLayout()   // the popover is its own root
        }
    }
}

/// What the MCP button opens: the one-line pitch, the helper's status, the three ways to connect
/// and the playback switch (the same AISettings as Settings ▸ AI), and a way to the rest.
struct MCPPopover: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    @Environment(\.console) private var console
    @ObservedObject private var ai = AIConnect.shared
    @ObservedObject private var weather = WeatherService.shared
    var close: () -> Void = {}
    /// Console: which other-app way to connect shows first (renders pin `.other`).
    var client: Client = .code

    enum Client: Hashable { case code, other }

    var body: some View {
        if console {
            MCPConsolePanel(close: close, client: client)
        } else {
            classic
        }
    }

    @ViewBuilder private var classic: some View {
        let store = model.store.baseDir
        let range = layout.popoverWidth
        VStack(alignment: .leading, spacing: layout.itemGap) {
            VStack(alignment: .leading, spacing: layout.labelGap) {
                HStack(spacing: Space.xs) {
                    Text("MCP").textRole(.headline).wrapping()
                    BetaTag()
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                Text("Let Claude or any MCP app build screensavers in DotStudio.")
                    .textRole(.caption).foregroundStyle(.secondary).wrapping()
            }
            VStack(alignment: .leading, spacing: layout.labelGap) {
                status(ai.helperFound, ai.helperFound ? "Server ready in DotStudio" : "Server not found in this copy of DotStudio")
                status(ai.settings.allowPlaybackChanges,
                       ai.settings.allowPlaybackChanges ? "AI may change what plays" : "AI can make styles, not change what plays")
                if !ai.pathIsStable {
                    Label("Move DotStudio to Applications first", systemImage: "exclamationmark.triangle.fill")
                        .textRole(.caption).foregroundStyle(.orange).wrapping()
                }
            }
            recommended
            step(1, "Connect your assistant") {
                VStack(alignment: .leading, spacing: layout.controlGap) {
                    Button(scaled: ai.installedInDesktop ? "Added to Claude Desktop" : "Add to Claude Desktop") { ai.addToDesktop() }
                        .disabled(ai.installedInDesktop || !ai.helperFound)
                    Button(scaled: ai.copied == "code" ? "Copied" : "Copy Claude Code command") {
                        ai.copy(AIConnect.claudeCodeCommand, "code")
                    }
                    .help(AIConnect.claudeCodeCommand)
                    Button(scaled: ai.copied == "json" ? "Copied" : "Copy JSON for other apps") { ai.copy(AIConnect.configJSON, "json") }
                        .help("The mcpServers entry for Cursor, VS Code, Codex and other MCP clients")
                }
                .disabled(!ai.helperFound)
                if let s = ai.desktopStatus {
                    Text(s).textRole(.caption).foregroundStyle(ai.desktopFailed ? .orange : .secondary).wrapping()
                }
            }
            step(2, "Restart it") {
                Text(AIConnect.restartHint).textRole(.caption).foregroundStyle(.secondary).wrapping()
            }
            step(3, "Ask for a screensaver") {
                Text("“\(AIConnect.examplePrompt)”").textRole(.caption).foregroundStyle(.secondary).wrapping()
                Button(scaled: ai.copied == "prompt" ? "Copied" : "Copy example") { ai.copy(AIConnect.examplePrompt, "prompt") }
            }
            step(4, "Find it in your Library") {
                Text(AIConnect.libraryHint).textRole(.caption).foregroundStyle(.secondary).wrapping()
            }
            // The standard macOS switch, small and accent-tinted (as in the setup guide), its
            // label on the left and the switch at the trailing edge, like a Settings row.
            HStack(alignment: .center, spacing: layout.controlGap) {
                Text("Let AI change what plays").textRole(.body).wrapping()
                    .accessibilityHidden(true)          // (the switch carries the label)
                Spacer(minLength: 0)
                Toggle("Let AI change what plays", isOn: ai.allowPlaybackBinding(store: store))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(.accentColor)
                    .adaptiveControlSize(.small)
                    .accessibilityLabel("Let AI change what plays")
            }
            .help("Off: assistants can still create and edit styles, but never change your screensaver or live wallpaper.")
            HStack(alignment: .center, spacing: layout.controlGap) {
                Text("Let AI add live data signals").textRole(.body).wrapping()
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                Toggle("Let AI add live data signals", isOn: ai.allowSignalsBinding(store: store))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(.accentColor)
                    .adaptiveControlSize(.small)
                    .accessibilityLabel("Let AI add live data signals")
            }
            .help("Off: assistants can't add, change or delete signals. They never see a signal's key either way.")
            Divider()
            Button(scaled: "What can it do? More in Settings…") {
                close()
                AppPresence.shared.showSettings(.ai)
            }
        }
        .padding(layout.cardPadding)
        .frame(width: min(max(layout.scaled(320), range.lowerBound), range.upperBound), alignment: .leading)
        .onAppear { ai.refresh(store: store) }
    }

    /// The recommended setup as a checklist: each item ticks itself off, with a one-click fix.
    private var recommended: some View {
        VStack(alignment: .leading, spacing: layout.controlGap) {
            Text("Recommended").textRole(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            recommendation(ai.anyAssistantConnected, "An AI app connected", AIConnect.assistantHint)
            recommendation(ai.blenderReady, ai.blenderReady ? ai.blenderStatus : "Blender, for film scenes (optional)",
                           AIConnect.blenderHint) {
                if !ai.blenderReady {
                    Button(scaled: "Get Blender…") { ai.getBlender() }
                        .help(AIConnect.blenderDownload.absoluteString)
                }
            }
            recommendation(weather.enabled, "Live weather on", AIConnect.weatherHint) {
                if !weather.enabled {
                    Button(scaled: "Turn On") { weather.enabled = true }
                }
            }
        }
        .padding(layout.controlGap)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        .accessibilityElement(children: .contain)
    }

    private func recommendation(_ ok: Bool, _ title: String, _ detail: String) -> some View {
        recommendation(ok, title, detail) { EmptyView() }
    }

    private func recommendation<Fix: View>(_ ok: Bool, _ title: String, _ detail: String,
                                           @ViewBuilder fix: () -> Fix) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? Color.green : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: layout.labelGap) {
                Text(title).textRole(.caption).fontWeight(.medium).wrapping()
                Text(detail).textRole(.caption).foregroundStyle(.secondary).wrapping()
                fix()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(ok ? "Done" : "Not set up")
    }

    /// One how-to step: an accent number, the title, then its controls or note.
    private func step<Content: View>(_ n: Int?, _ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: layout.controlGap) {
            Group {
                if let n { Text("\(n)") } else { Image(systemName: "star.fill").imageScale(.small) }
            }
                .textRole(.badge)
                .foregroundStyle(.white)
                .frame(width: layout.scaled(18), height: layout.scaled(18))
                .background(Circle().fill(Color.accentColor))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: layout.labelGap) {
                Text(title).textRole(.body).fontWeight(.semibold).wrapping()
                    .accessibilityLabel(n.map { "Step \($0): \(title)" } ?? title)
                content()
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func status(_ ok: Bool, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            Image(systemName: ok ? "checkmark.circle.fill" : "minus.circle.fill")
                .foregroundStyle(ok ? Color.green : Color.secondary)
                .accessibilityHidden(true)
            Text(text).wrapping()
        }
        .textRole(.caption)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Console

/// The MCP popover in the Console appearance: the same state and actions as the Classic one, as
/// one calm column — MCP · BETA, the pitch and ONE status LED; CONNECT with the orange
/// "Add to Claude Desktop" key, then Claude Code / other apps as segment keys over one
/// single-line well (command or JSON, truncated in the middle, full text in the tooltip) and
/// a COPY key; TRY IT with the example prompt; the two permissions as ruled switch rows;
/// EXTRAS as one row per thing that needs doing (or one "all set" line); a key to Settings ▸ AI.
private struct MCPConsolePanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var ai = AIConnect.shared
    @ObservedObject private var weather = WeatherService.shared
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var client: MCPPopover.Client
    var close: () -> Void

    /// The panel's width (padding included), the same at every text size: large text makes it
    /// taller, never wider or two-column.
    static let width: CGFloat = 400

    init(close: @escaping () -> Void, client: MCPPopover.Client) {
        self.close = close
        _client = State(initialValue: client)
    }

    var body: some View {
        let store = model.store.baseDir
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, Space.m)
            section("Connect") { connect }
            section("Try it") { tryIt }
            section("Let AI") { permissions(store) }
            if !extrasAllSet {
                section("Extras") { extras }
            }
            foot
        }
        .padding(Space.m)
        .frame(width: Self.width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(ConsoleInk.panel)
        .presentationBackground(ConsoleInk.panel)
        .foregroundStyle(ConsoleInk.ink, ConsoleInk.legend)
        .onAppear { ai.refresh(store: store) }
    }

    // MARK: Header

    /// MCP · BETA, the pitch, and one status line.
    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                Text("MCP").textRole(.consoleHeadline).foregroundStyle(ConsoleInk.ink).wrapping()
                BetaTag()
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Text("Let Claude or any MCP app build screensavers in DotStudio.")
                .textRole(.consoleBodySmall).foregroundStyle(ConsoleInk.legend).wrapping()
            let s = status
            ConsoleLED(on: true, color: s.color, label: s.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.xxs)
                .help(s.help)
        }
    }

    /// The one thing to know right now: blocked (amber), connected, or ready to connect.
    private var status: (text: String, color: Color, help: String) {
        if !ai.helperFound {
            return ("Server not found in this copy", ConsoleInk.amber,
                    "This copy of DotStudio has no MCP server inside. Reinstall DotStudio from its download.")
        }
        if !ai.pathIsStable {
            return ("Move DotStudio to Applications first", ConsoleInk.amber,
                    "AI apps remember where DotStudio is. Move it to Applications, open it from there, then connect.")
        }
        let apps = [ai.installedInDesktop ? "Claude Desktop" : nil, ai.installedInClaudeCode ? "Claude Code" : nil].compactMap { $0 }
        if !apps.isEmpty {
            return ("Connected to " + apps.joined(separator: " + "), ConsoleInk.green, AIConnect.assistantHint)
        }
        return ("Ready to connect", ConsoleInk.green, AIConnect.assistantHint)
    }

    // MARK: Connect

    private var connect: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Button { ai.addToDesktop() } label: {
                    HStack(spacing: Space.xs) {
                        Text(ai.installedInDesktop ? "Added to Claude Desktop" : "Add to Claude Desktop")
                            .textRole(.consoleKey).wrapping(.center)
                        if ai.installedInDesktop {
                            Image(systemName: "checkmark").textRole(.consoleKey).accessibilityHidden(true)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                // orange while it's the thing to do: grey once added, or while DotStudio must move first
                .buttonStyle(.keycap(ai.installedInDesktop || !ai.pathIsStable ? .plain : .signal,
                                     latched: ai.installedInDesktop))
                .help(ai.installedInDesktop ? "Already in Claude Desktop's settings. Press to check again."
                                            : "Adds DotStudio to Claude Desktop's MCP settings (your old settings are backed up)")
                .accessibilityValue(ai.installedInDesktop ? "Added" : "")
                note(desktopHint, tint: ai.desktopFailed ? ConsoleInk.signalInk : ConsoleInk.legend)
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                ConsoleSegments(title: "Other apps", selection: $client,
                                options: [("Claude Code", .code), ("Other apps", .other)])
                if client == .code {
                    copyLine(AIConnect.claudeCodeCommand, tag: "code", what: "Claude Code command")
                    note("Run it in Terminal, then start a new Claude Code session.")
                } else {
                    copyLine(AIConnect.configJSONCompact, copies: AIConnect.configJSON, tag: "json", what: "JSON",
                             help: "The mcpServers entry for Cursor, VS Code, Codex and other MCP clients")
                    note("Paste it into the MCP settings of Cursor, VS Code, Codex\u{2026}")
                }
            }
        }
        .disabled(!ai.helperFound)
    }

    /// Under the Claude Desktop key: what happened, or the one thing to do next.
    private var desktopHint: String {
        if let s = ai.desktopStatus { return s }
        if !ai.pathIsStable { return "Move DotStudio to Applications and open it from there first." }
        return ai.installedInDesktop ? "Quit and reopen Claude Desktop if it doesn't list DotStudio."
                                     : "Then quit and reopen Claude Desktop."
    }

    // MARK: Try it

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            copyLine("\u{201C}\(AIConnect.examplePrompt)\u{201D}", copies: AIConnect.examplePrompt, tag: "prompt",
                     what: "example prompt", help: AIConnect.examplePrompt, prose: true)
            note("New styles land in your Library. Changes come with Undo.")
                .help(AIConnect.libraryHint)
        }
    }

    // MARK: Permissions

    /// The two permissions as ruled switch rows (the same AISettings as Settings ▸ AI).
    private func permissions(_ store: URL) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            permission("Change what plays", full: "Let AI change what plays", isOn: ai.allowPlaybackBinding(store: store))
                .help("Off: assistants can still create and edit styles, but never change your screensaver or live wallpaper.")
            permission("Add live data signals", full: "Let AI add live data signals", isOn: ai.allowSignalsBinding(store: store))
                .help("Off: assistants can't add, change or delete signals. They never see a signal's key either way.")
        }
        .overlay(alignment: .top) { ConsoleHairline() }
    }

    private func permission(_ title: String, full: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title).textRole(.consoleBody).foregroundStyle(ConsoleInk.ink).wrapping()
                .accessibilityLabel(full)
        }
        .toggleStyle(ConsoleSwitchStyle())
        .padding(.vertical, Space.xs)
        .overlay(alignment: .bottom) { ConsoleHairline() }
    }

    // MARK: Extras

    /// Blender (film scenes) and live weather: optional, so only what needs doing is shown.
    private var extrasAllSet: Bool { ai.blenderReady && weather.enabled }

    private var extras: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !ai.blenderReady {
                extra(ai.blenderFound ? "Blender \(ai.blenderVersion ?? "") \u{00B7} film scenes need \(AIConnect.blenderMinimum)+"
                                      : "Blender, for film scenes",
                      help: ai.blenderFound ? ai.blenderStatus : AIConnect.blenderHint) {
                    Button { ai.getBlender() } label: { Text("Get Blender\u{2026}").textRole(.consoleKey).lineLimit(1).fixedSize() }
                        .buttonStyle(.keycap(padding: HubMetrics.smallKey))
                        .help(AIConnect.blenderDownload.absoluteString)
                }
            }
            if !weather.enabled {
                extra("Live weather", help: AIConnect.weatherHint) {
                    Button { weather.enabled = true } label: { Text("Turn On").textRole(.consoleKey).lineLimit(1).fixedSize() }
                        .buttonStyle(.keycap(padding: HubMetrics.smallKey))
                }
            }
        }
        .overlay(alignment: .top) { ConsoleHairline() }
    }

    /// One extra that needs doing: a dark LED, its short title, its fix key; a hairline under.
    private func extra<Fix: View>(_ title: String, help: String, @ViewBuilder fix: () -> Fix) -> some View {
        HStack(alignment: .center, spacing: Space.s) {
            ConsoleLED(on: false)
            Text(title).textRole(.consoleBody).foregroundStyle(ConsoleInk.ink).wrapping()
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(help)
            fix()
        }
        .padding(.vertical, Space.xs)
        .overlay(alignment: .bottom) { ConsoleHairline() }
        .accessibilityElement(children: .contain)
        .accessibilityValue("Not set up")
    }

    // MARK: Foot

    /// "Extras · all set" (when it is) and the key to the rest in Settings ▸ AI.
    private var foot: some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s))
                             : AnyLayout(HStackLayout(alignment: .center, spacing: Space.s))
        return layout {
            if extrasAllSet {
                ConsoleLED(on: true, color: ConsoleInk.green, label: "Extras \u{00B7} all set")
                    .help("\(ai.blenderStatus). Live weather on.")
            }
            if !stacked { Spacer(minLength: 0) }
            Button {
                close()
                AppPresence.shared.showSettings(.ai)
            } label: {
                Text("More in Settings\u{2026}").textRole(.consoleKey).lineLimit(1).fixedSize()
            }
            .buttonStyle(.keycap(padding: HubMetrics.smallKey))
            .help("What it can do, more examples to try, and the rest of the AI settings")
        }
    }

    // MARK: Parts

    /// A titled block: its legend, then the content; a gap after it.
    private func section<Content: View>(_ legend: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(legend).textRole(.legend).foregroundStyle(ConsoleInk.legend)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(.bottom, Space.m)
        .accessibilityElement(children: .contain)
    }

    /// Something to copy on one line: the text in a well (truncated in the middle for a
    /// command or JSON, so a long path never wraps; the whole text in the tooltip and
    /// selectable), and a COPY key that says COPIED for a moment. At accessibility text sizes
    /// the key goes under the well (picked from the text size, never measured).
    private func copyLine(_ text: String, copies: String? = nil, tag: String, what: String,
                          help: String? = nil, prose: Bool = false) -> some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .trailing, spacing: Space.xs))
                             : AnyLayout(HStackLayout(alignment: .center, spacing: Space.xs))
        let done = ai.copied == tag
        return layout {
            Text(text)
                .textRole(prose ? .consoleBodySmall : .consoleMono)
                .foregroundStyle(ConsoleInk.ink)
                .lineLimit(prose ? 2 : 1)
                .truncationMode(prose ? .tail : .middle)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .help(help ?? (copies ?? text))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.xs)
                .padding(.vertical, Space.xs - 1)
                .consoleWell(cornerRadius: 3)
            Button { ai.copy(copies ?? text, tag) } label: {
                Text(done ? "Copied" : "Copy").textRole(.consoleKey).lineLimit(1).fixedSize()
            }
            .buttonStyle(.keycap(latched: done, padding: HubMetrics.smallKey))
            .accessibilityLabel(done ? "Copied" : "Copy \(what)")
        }
    }

    private func note(_ text: String, tint: Color = ConsoleInk.legend) -> some View {
        Text(text).textRole(.consoleBodySmall).foregroundStyle(tint).wrapping()
    }
}

/// The small "Beta" capsule on the AI features (Settings ▸ AI, the MCP popover) for 1.5.
/// Console: a printed grey tag.
struct BetaTag: View {
    @Environment(\.console) private var console

    var body: some View {
        if console {
            ConsoleTag(text: "Beta").fixedSize().accessibilityLabel("Beta")
        } else {
            classic
        }
    }

    private var classic: some View {
        Text("Beta")
            .textRole(.badge)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1))
            .fixedSize()
            .accessibilityLabel("Beta")
    }
}
