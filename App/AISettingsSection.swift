//  AISettingsSection.swift — Settings ▸ AI: connect AI assistants to DotStudio's MCP server
//  (dotstudio-mcp, inside this app), and what they may change.

import AppKit
import SwiftUI

struct AISettingsSection: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.layout) private var layout
    @State private var settings = AISettings()
    @State private var desktopStatus: String?
    @State private var desktopFailed = false
    @State private var copied: String?

    /// The helper every client launches.
    static var helperPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/dotstudio-mcp").path
    }

    /// Clients store this path: it must survive the app being moved (not run from the disk
    /// image, Downloads or a translocated copy).
    private var pathIsStable: Bool {
        let p = Bundle.main.bundlePath
        return p.hasPrefix("/Applications/") || p.hasPrefix(SharedStore.realHome.path + "/Applications/")
    }

    var body: some View {
        Section {
            Text("Assistants like Claude, Cursor or VS Code can design screensavers with you through DotStudio's MCP server: they read DotStudio's style guide, build styles from the scenes and looks, preview them as images and check their GPU cost.")
                .textRole(.body).wrapping()
            Toggle("Let AI change what plays", isOn: Binding(get: { settings.allowPlaybackChanges }, set: { on in
                settings.allowPlaybackChanges = on
                settings.save(store: model.store.baseDir)
            }))
            .formSwitchSize()
            .help("Off: assistants can still create and edit styles, but never change your screensaver or live wallpaper.")
            LabeledContent("Claude Desktop") {
                FlowLayout(spacing: layout.controlGap, lineSpacing: layout.controlGap, alignment: .trailing) {
                    Button(scaled: installedInDesktop ? "Added" : "Add to Claude Desktop") { addToDesktop() }
                        .disabled(installedInDesktop)
                    if desktopFailed {
                        Button(scaled: "Copy Config") { copy(ClaudeDesktopConfig.snippet(command: Self.helperPath), "config") }
                        Button(scaled: "Reveal Config") { revealDesktopConfig() }
                    }
                }
            }
            if let desktopStatus {
                Text(desktopStatus).textRole(.caption).foregroundStyle(desktopFailed ? .orange : .secondary).wrapping()
            }
            LabeledContent("Claude Code") {
                Button(scaled: copied == "code" ? "Copied" : "Copy Command") {
                    copy(ClaudeDesktopConfig.claudeCodeCommand(command: Self.helperPath), "code")
                }
                .help(ClaudeDesktopConfig.claudeCodeCommand(command: Self.helperPath))
            }
            LabeledContent("Other apps") {
                Button(scaled: copied == "json" ? "Copied" : "Copy JSON") {
                    copy(ClaudeDesktopConfig.snippet(command: Self.helperPath), "json")
                }
                .help("The mcpServers entry for Cursor, VS Code, Codex and other MCP clients")
            }
            LabeledContent("Your guides") {
                Button(scaled: "Open Guides Folder") {
                    let dir = AIStore.guidesDir(model.store.baseDir)
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(dir)
                }
                .help("Markdown files here (a brand guide, colours you like) steer what the AI designs")
            }
        } header: {
            SettingsHeader("AI")
        } footer: {
            VStack(alignment: .leading, spacing: Space.xs) {
                SettingsNote(settings.allowPlaybackChanges
                    ? "When an assistant changes your screensaver or wallpaper, a small notice shows what it did, with Undo."
                    : "Assistants can make styles for you to try; setting one as your screensaver or wallpaper stays with you.")
                if !pathIsStable {
                    SettingsNote("Move DotStudio to Applications first: assistants remember where its server is, and this copy may move.")
                        .foregroundStyle(.orange)
                }
            }
        }
        .onAppear {
            settings = AISettings.load(store: model.store.baseDir)
            refreshDesktop()
        }
    }

    @State private var installedInDesktop = false

    private func refreshDesktop() {
        installedInDesktop = ClaudeDesktopConfig.installedCommand() == Self.helperPath
    }

    private func addToDesktop() {
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
        refreshDesktop()
    }

    private func revealDesktopConfig() {
        let url = ClaudeDesktopConfig.defaultURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    private func copy(_ s: String, _ tag: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        copied = tag
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if copied == tag { copied = nil } }
    }
}
