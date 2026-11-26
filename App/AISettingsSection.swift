//  AISettingsSection.swift — Settings ▸ AI: connect AI assistants to DotStudio's MCP server
//  (dotstudio-mcp, inside this app), and what they may change. The state and actions are
//  AIConnect's (AIConnect.swift), shared with the library window's MCP button.

import AppKit
import SwiftUI

struct AISettingsSection: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    @Environment(\.consoleSettings) private var console
    @ObservedObject private var ai = AIConnect.shared
    @ObservedObject private var weather = WeatherService.shared

    /// The helper every client launches.
    static var helperPath: String { AIConnect.helperPath }

    var body: some View {
        let store = model.store.baseDir
        Section {
            Text("Assistants like Claude, Cursor or VS Code can design screensavers with you through DotStudio's MCP server: they read DotStudio's style guide, build styles from the scenes and looks or write new scenes of their own, preview them as images and check their GPU cost.")
                .settingsText(.body).wrapping()
            // Recommended setup: each row says whether it's done, with the fix next to it.
            LabeledContent {
                Text(ai.anyAssistantConnected ? "Connected" : "Not yet — connect one below")
                    .settingsText(.caption).foregroundStyle(.secondary)
            } label: {
                recommendedLabel(ai.anyAssistantConnected, "An AI app (recommended)", AIConnect.assistantHint)
            }
            LabeledContent {
                HStack(spacing: layout.controlGap) {
                    Text(ai.blenderReady ? "Ready" : ai.blenderStatus).settingsText(.caption).foregroundStyle(.secondary).wrapping()
                    if !ai.blenderReady {
                        Button(scaled: "Get Blender…") { ai.getBlender() }
                            .help(AIConnect.blenderDownload.absoluteString)
                    }
                }
            } label: {
                recommendedLabel(ai.blenderReady, "Blender (recommended for film scenes)", AIConnect.blenderHint)
            }
            LabeledContent {
                HStack(spacing: layout.controlGap) {
                    Text(weather.enabled ? "On" : "Off").settingsText(.caption).foregroundStyle(.secondary)
                    if !weather.enabled { Button(scaled: "Turn On") { weather.enabled = true } }
                }
            } label: {
                recommendedLabel(weather.enabled, "Live weather (recommended)", AIConnect.weatherHint)
            }
            LabeledContent("How to use it") {
                Text("1. Connect your assistant below.\n2. \(AIConnect.restartHint)\n3. Ask it for a screensaver — “\(AIConnect.examplePrompt)”\n4. \(AIConnect.libraryHint)")
                    .settingsText(.caption).foregroundStyle(.secondary).wrapping()
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
            }
            LabeledContent("What it can do") {
                VStack(alignment: .leading, spacing: layout.labelGap) {
                    ForEach(AIConnect.abilities, id: \.title) { a in
                        (Text(a.title).fontWeight(.medium) + Text(" — " + a.detail))
                            .settingsText(.caption).foregroundStyle(.secondary).wrapping()
                    }
                }
                .multilineTextAlignment(.leading)
            }
            LabeledContent("Try asking") {
                VStack(alignment: .leading, spacing: layout.labelGap) {
                    ForEach(AIConnect.examples, id: \.self) { e in
                        if console {
                            // Console: the prompt in a recessed well, its COPY key beside it.
                            HStack(alignment: .center, spacing: layout.controlGap) {
                                Text("“\(e)”").settingsText(.caption).foregroundStyle(ConsoleInk.ink).wrapping()
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, Space.xs)
                                    .padding(.vertical, Space.xs - 2)
                                    .consoleWell(cornerRadius: 3)
                                Button { ai.copy(e, e) } label: {
                                    Text(ai.copied == e ? "Copied" : "Copy").textRole(.consoleKey).lineLimit(1).fixedSize()
                                }
                                .buttonStyle(.keycap(padding: HubMetrics.smallKey))
                                .accessibilityLabel("Copy example")
                            }
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: layout.controlGap) {
                                Text("“\(e)”").settingsText(.caption).foregroundStyle(.secondary).wrapping()
                                    .textSelection(.enabled)
                                Button(scaled: ai.copied == e ? "Copied" : "Copy") { ai.copy(e, e) }
                                    .adaptiveControlSize(.small)
                            }
                        }
                    }
                }
                .multilineTextAlignment(.leading)
            }
            Toggle("Let AI change what plays", isOn: ai.allowPlaybackBinding(store: store))
                .formSwitchSize()
                .help("Off: assistants can still create and edit styles, but never change your screensaver or live wallpaper.")
            Toggle("Let AI add live data signals", isOn: ai.allowSignalsBinding(store: store))
                .formSwitchSize()
                .help("Off: assistants can't add, change or delete signals (Settings ▸ Signals). They never see a signal's key either way.")
            LabeledContent("Claude Desktop") {
                FlowLayout(spacing: layout.controlGap, lineSpacing: layout.controlGap, alignment: .trailing) {
                    Button(scaled: ai.installedInDesktop ? "Added" : "Add to Claude Desktop") { ai.addToDesktop() }
                        .disabled(ai.installedInDesktop || !ai.helperFound)
                    if ai.desktopFailed {
                        Button(scaled: "Copy Config") { ai.copy(AIConnect.configJSON, "config") }
                        Button(scaled: "Reveal Config") { ai.revealDesktopConfig() }
                    }
                }
            }
            if let status = ai.desktopStatus {
                Text(status).settingsText(.caption)
                    .foregroundStyle(ai.desktopFailed ? (console ? ConsoleInk.signalInk : .orange) : .secondary).wrapping()
            }
            LabeledContent("Claude Code") {
                Button(scaled: ai.copied == "code" ? "Copied" : "Copy Command") {
                    ai.copy(AIConnect.claudeCodeCommand, "code")
                }
                .help(AIConnect.claudeCodeCommand)
            }
            LabeledContent("Other apps") {
                Button(scaled: ai.copied == "json" ? "Copied" : "Copy JSON") {
                    ai.copy(AIConnect.configJSON, "json")
                }
                .help("The mcpServers entry for Cursor, VS Code, Codex and other MCP clients")
            }
            LabeledContent("Your guides") {
                Button(scaled: "Open Guides Folder") { ai.openGuidesFolder(store: store) }
                    .help("Markdown files here (a brand guide, colours you like) steer what the AI designs")
            }
        } header: {
            HStack(spacing: Space.xs) { SettingsHeader("AI"); BetaTag() }
        } footer: {
            VStack(alignment: .leading, spacing: Space.xs) {
                SettingsNote(ai.settings.allowPlaybackChanges
                    ? "When an assistant changes your screensaver or wallpaper, a small notice shows what it did, with Undo."
                    : "Assistants can make styles for you to try; setting one as your screensaver or wallpaper stays with you.")
                if !ai.pathIsStable {
                    SettingsNote("Move DotStudio to Applications first: assistants remember where its server is, and this copy may move.")
                        .foregroundStyle(console ? ConsoleInk.signalInk : .orange)
                }
            }
        }
        .id(Self.anchor)
        .onAppear { ai.refresh(store: store) }
    }

    /// A recommended-setup row's label: a green tick when it's done, the title, a caption.
    @ViewBuilder
    private func recommendedLabel(_ ok: Bool, _ title: String, _ detail: String) -> some View {
        Label {
            Text(title)
        } icon: {
            if console {
                // Console: a status LED, lit green when it's set up (the value says Done).
                ConsoleLED(on: ok, color: ConsoleInk.green)
            } else {
                Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(ok ? Color.green : Color.secondary)
            }
        }
        .accessibilityValue(ok ? "Done" : "Not set up")
        Text(detail).settingsText(.caption).foregroundStyle(.secondary).wrapping()
    }

    /// The Settings form's scroll anchor for this section (the MCP popover's "More in Settings…").
    static let anchor = "settings-ai"
}
