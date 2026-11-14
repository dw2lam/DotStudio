//  AISettingsSection.swift — Settings ▸ AI: connect AI assistants to DotStudio's MCP server
//  (dotstudio-mcp, inside this app), and what they may change. The state and actions are
//  AIConnect's (AIConnect.swift), shared with the library window's MCP button.

import AppKit
import SwiftUI

struct AISettingsSection: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    @ObservedObject private var ai = AIConnect.shared

    /// The helper every client launches.
    static var helperPath: String { AIConnect.helperPath }

    var body: some View {
        let store = model.store.baseDir
        Section {
            Text("Assistants like Claude, Cursor or VS Code can design screensavers with you through DotStudio's MCP server: they read DotStudio's style guide, build styles from the scenes and looks or write new scenes of their own, preview them as images and check their GPU cost.")
                .textRole(.body).wrapping()
            LabeledContent("How to use it") {
                Text("1. Connect your assistant below.\n2. \(AIConnect.restartHint)\n3. Ask it for a screensaver — “\(AIConnect.examplePrompt)”\n4. \(AIConnect.libraryHint)")
                    .textRole(.caption).foregroundStyle(.secondary).wrapping()
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
            }
            Toggle("Let AI change what plays", isOn: ai.allowPlaybackBinding(store: store))
                .formSwitchSize()
                .help("Off: assistants can still create and edit styles, but never change your screensaver or live wallpaper.")
            LabeledContent("Claude Desktop") {
                FlowLayout(spacing: layout.controlGap, lineSpacing: layout.controlGap, alignment: .trailing) {
                    Button(scaled: ai.installedInDesktop ? "Added" : "Add to Claude Desktop") { ai.addToDesktop() }
                        .disabled(ai.installedInDesktop)
                    if ai.desktopFailed {
                        Button(scaled: "Copy Config") { ai.copy(AIConnect.configJSON, "config") }
                        Button(scaled: "Reveal Config") { ai.revealDesktopConfig() }
                    }
                }
            }
            if let status = ai.desktopStatus {
                Text(status).textRole(.caption).foregroundStyle(ai.desktopFailed ? .orange : .secondary).wrapping()
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
                        .foregroundStyle(.orange)
                }
            }
        }
        .id(Self.anchor)
        .onAppear { ai.refresh(store: store) }
    }

    /// The Settings form's scroll anchor for this section (the MCP popover's "More in Settings…").
    static let anchor = "settings-ai"
}
