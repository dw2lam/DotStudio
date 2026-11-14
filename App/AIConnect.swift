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
    static var configJSON: String { ClaudeDesktopConfig.snippet(command: helperPath) }

    /// Re-read the settings and whether Claude Desktop lists this helper (on appear).
    func refresh(store: URL) {
        settings = AISettings.load(store: store)
        installedInDesktop = ClaudeDesktopConfig.installedCommand() == Self.helperPath
    }

    func setAllowPlaybackChanges(_ on: Bool, store: URL) {
        settings.allowPlaybackChanges = on
        settings.save(store: store)
    }

    func allowPlaybackBinding(store: URL) -> Binding<Bool> {
        Binding(get: { self.settings.allowPlaybackChanges }, set: { self.setAllowPlaybackChanges($0, store: store) })
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
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var ai = AIConnect.shared
    var close: () -> Void = {}

    var body: some View {
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
            VStack(alignment: .leading, spacing: layout.controlGap) {
                Button(scaled: ai.installedInDesktop ? "Added to Claude Desktop" : "Add to Claude Desktop") { ai.addToDesktop() }
                    .disabled(ai.installedInDesktop || !ai.helperFound)
                Button(scaled: ai.copied == "code" ? "Copied" : "Copy Claude Code command") {
                    ai.copy(AIConnect.claudeCodeCommand, "code")
                }
                .help(AIConnect.claudeCodeCommand)
                Button(scaled: ai.copied == "json" ? "Copied" : "Copy JSON") { ai.copy(AIConnect.configJSON, "json") }
                    .help("The mcpServers entry for Cursor, VS Code, Codex and other MCP clients")
            }
            .disabled(!ai.helperFound)
            if let s = ai.desktopStatus {
                Text(s).textRole(.caption).foregroundStyle(ai.desktopFailed ? .orange : .secondary).wrapping()
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
            Divider()
            Button(scaled: "More in Settings…") {
                close()
                ai.revealRequest += 1
                openSettings()
            }
        }
        .padding(layout.cardPadding)
        .frame(width: min(max(layout.scaled(300), range.lowerBound), range.upperBound), alignment: .leading)
        .onAppear { ai.refresh(store: store) }
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

/// The small "Beta" capsule on the AI features (Settings ▸ AI, the MCP popover) for 1.5.
struct BetaTag: View {
    var body: some View {
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
