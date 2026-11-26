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

    /// Re-read the settings and whether Claude Desktop lists this helper (on appear).
    func refresh(store: URL) {
        settings = AISettings.load(store: store)
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

    var body: some View {
        if console {
            MCPConsolePanel(close: close)
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

/// The MCP popover in the Console appearance: the same content and actions as the Classic one,
/// as a small instrument panel — a title with its BETA tag and status LEDs, the recommended
/// setup as a module of ruled rows (an LED each, the fix as a key), the four steps under
/// "01 // …" legends, the copyable command / JSON / prompt in recessed wells with a COPY key,
/// the two permissions as Console switches, and a key to Settings ▸ AI.
private struct MCPConsolePanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    @ObservedObject private var ai = AIConnect.shared
    @ObservedObject private var weather = WeatherService.shared
    var close: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let store = model.store.baseDir
        let range = layout.popoverWidth
        let column = min(max(layout.scaled(320), range.lowerBound), range.upperBound)
        // Two columns (the state and setup | the steps) so it stays shorter than a laptop
        // screen; one from the accessibility text sizes (picked from the size, never measured).
        Group {
            if typeSize.isAccessibilitySize {
                // One column, in the Classic popover's order.
                VStack(alignment: .leading, spacing: Space.m) {
                    header
                    recommended
                    steps
                    permissions(store)
                    settingsKey
                }
                .frame(width: column, alignment: .topLeading)
            } else {
                HStack(alignment: .top, spacing: Space.l) {
                    VStack(alignment: .leading, spacing: Space.m) {
                        header
                        recommended
                        permissions(store)
                        settingsKey
                    }
                    .frame(width: column, alignment: .topLeading)
                    steps
                        .frame(width: column, alignment: .topLeading)
                        .padding(.leading, Space.l)
                        .overlay(alignment: .leading) { ConsoleHairline(vertical: true) }
                }
            }
        }
        .padding(Space.m)
        .fixedSize(horizontal: false, vertical: true)
        .background(ConsoleInk.panel)
        .presentationBackground(ConsoleInk.panel)
        .foregroundStyle(ConsoleInk.ink, ConsoleInk.legend)
        .onAppear { ai.refresh(store: store) }
    }

    /// The four steps.
    private var steps: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            step(1, "Connect your assistant") {
                VStack(alignment: .leading, spacing: Space.s) {
                    Button { ai.addToDesktop() } label: {
                        Text(ai.installedInDesktop ? "Added to Claude Desktop" : "Add to Claude Desktop")
                            .textRole(.consoleKey).wrapping()
                    }
                    .buttonStyle(.keycap(ai.installedInDesktop ? .plain : .signal, latched: ai.installedInDesktop))
                    .disabled(ai.installedInDesktop || !ai.helperFound)
                    copyable("Claude Code", text: AIConnect.claudeCodeCommand, tag: "code",
                             help: AIConnect.claudeCodeCommand)
                    copyable("Other apps \u{00B7} JSON", text: AIConnect.configJSONCompact, copies: AIConnect.configJSON,
                             tag: "json", help: "The mcpServers entry for Cursor, VS Code, Codex and other MCP clients")
                }
                .disabled(!ai.helperFound)
                if let s = ai.desktopStatus {
                    note(s, tint: ai.desktopFailed ? ConsoleInk.signalInk : ConsoleInk.legend)
                }
            }
            step(2, "Restart it") {
                note(AIConnect.restartHint)
            }
            step(3, "Ask for a screensaver") {
                copyable("Example", text: "\u{201C}\(AIConnect.examplePrompt)\u{201D}", copies: AIConnect.examplePrompt,
                         tag: "prompt", help: "Copy example", mono: false)
            }
            step(4, "Find it in your Library") {
                note(AIConnect.libraryHint)
            }
        }
    }

    /// The two permissions as ruled switch rows (the same AISettings as Settings ▸ AI).
    private func permissions(_ store: URL) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            permission("Let AI change what plays", isOn: ai.allowPlaybackBinding(store: store))
                .help("Off: assistants can still create and edit styles, but never change your screensaver or live wallpaper.")
            permission("Let AI add live data signals", isOn: ai.allowSignalsBinding(store: store))
                .help("Off: assistants can't add, change or delete signals. They never see a signal's key either way.")
        }
        .overlay(alignment: .top) { ConsoleHairline() }
    }

    private var settingsKey: some View {
        Button {
            close()
            AppPresence.shared.showSettings(.ai)
        } label: {
            Text("What can it do? More in Settings\u{2026}").textRole(.consoleKey).wrapping()
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.keycap)
    }

    // MARK: Parts

    /// MCP · BETA, the pitch, and the server's state as LEDs (with the move warning).
    private var header: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    Text("MCP").textRole(.consoleHeadline).foregroundStyle(ConsoleInk.ink).wrapping()
                    BetaTag()
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                Text("Let Claude or any MCP app build screensavers in DotStudio.")
                    .textRole(.consoleBodySmall).foregroundStyle(ConsoleInk.legend).wrapping()
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                ConsoleLED(on: ai.helperFound, color: ConsoleInk.green,
                           label: ai.helperFound ? "Server ready in DotStudio" : "Server not found in this copy of DotStudio")
                ConsoleLED(on: ai.settings.allowPlaybackChanges, color: ConsoleInk.signal,
                           label: ai.settings.allowPlaybackChanges ? "AI may change what plays" : "AI can make styles, not change what plays")
                if !ai.pathIsStable {
                    ConsoleLED(on: true, color: ConsoleInk.amber, label: "Move DotStudio to Applications first")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The recommended setup: a module of ruled rows, each with its LED and its fix.
    private var recommended: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Recommended").textRole(.legend).foregroundStyle(ConsoleInk.legend)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                recommendation(ai.anyAssistantConnected, "An AI app connected", AIConnect.assistantHint) { EmptyView() }
                recommendation(ai.blenderReady, ai.blenderReady ? ai.blenderStatus : "Blender, for film scenes (optional)",
                               AIConnect.blenderHint) {
                    if !ai.blenderReady {
                        Button { ai.getBlender() } label: { Text("Get Blender\u{2026}").textRole(.consoleKey) }
                            .buttonStyle(.keycap(padding: HubMetrics.smallKey))
                            .help(AIConnect.blenderDownload.absoluteString)
                    }
                }
                recommendation(weather.enabled, "Live weather on", AIConnect.weatherHint, last: true) {
                    if !weather.enabled {
                        Button { weather.enabled = true } label: { Text("Turn On").textRole(.consoleKey) }
                            .buttonStyle(.keycap(padding: HubMetrics.smallKey))
                    }
                }
            }
            .padding(.horizontal, Space.s)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(ConsoleInk.surface))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(ConsoleInk.hairline, lineWidth: 1))
        }
        .accessibilityElement(children: .contain)
    }

    private func recommendation<Fix: View>(_ ok: Bool, _ title: String, _ detail: String, last: Bool = false,
                                           @ViewBuilder fix: () -> Fix) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            ConsoleLED(on: ok, color: ConsoleInk.green)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).textRole(.consoleBodySmallEmphasis).foregroundStyle(ConsoleInk.ink).wrapping()
                Text(detail).textRole(.consoleBodySmall).foregroundStyle(ConsoleInk.legend).wrapping()
                fix()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Space.s)
        .overlay(alignment: .bottom) { if !last { ConsoleHairline() } }
        .accessibilityElement(children: .combine)
        .accessibilityValue(ok ? "Done" : "Not set up")
    }

    /// One how-to step under its printed legend: the number in the signal ink, "//", the title.
    private func step<Content: View>(_ n: Int, _ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            (Text(String(format: "%02d", n)).foregroundColor(ConsoleInk.signalInk)
                + Text(" // ").foregroundColor(ConsoleInk.legend)
                + Text(title).foregroundColor(ConsoleInk.ink))
                .textRole(.legend)
                .wrapping()
                .accessibilityLabel("Step \(n): \(title)")
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .accessibilityElement(children: .contain)
    }

    /// Something to copy: its legend and a COPY key on one line, the text itself in a well
    /// under it (selectable; mono for a command or JSON). The key says COPIED for a moment.
    private func copyable(_ legend: String, text: String, copies: String? = nil, tag: String,
                          help: String, mono: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(alignment: .center, spacing: Space.xs) {
                Text(legend).textRole(.legend).foregroundStyle(ConsoleInk.legend)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { ai.copy(copies ?? text, tag) } label: {
                    Text(ai.copied == tag ? "Copied" : "Copy").textRole(.consoleKey).lineLimit(1).fixedSize()
                }
                .buttonStyle(.keycap(padding: HubMetrics.smallKey))
                .help(help)
                .accessibilityLabel("Copy \(legend)")
            }
            Text(text)
                .textRole(mono ? .consoleMono : .consoleBodySmall)
                .foregroundStyle(ConsoleInk.ink)
                .wrapping()
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.xs)
                .padding(.vertical, Space.xs - 2)
                .consoleWell(cornerRadius: 3)
        }
    }

    private func note(_ text: String, tint: Color = ConsoleInk.legend) -> some View {
        Text(text).textRole(.consoleBodySmall).foregroundStyle(tint).wrapping()
    }

    /// A permission as a ruled switch row.
    private func permission(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title).textRole(.consoleBody).foregroundStyle(ConsoleInk.ink).wrapping()
        }
        .toggleStyle(ConsoleSwitchStyle())
        .padding(.vertical, Space.xs)
        .overlay(alignment: .bottom) { ConsoleHairline() }
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
