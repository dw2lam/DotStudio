//  AIBridgeHost.swift — the app's end of the AI bridge (Shared/AI/AIBridge.swift).
//
//  dotstudio-mcp sends each library change here while the app runs. What a request does — its
//  validation, the Settings ▸ AI gates ("Let AI change what plays", "Let AI add live data
//  signals"), its refusals and the edit itself — is LibraryOps.apply (Shared/AI/LibraryOps.swift),
//  the same function dotstudio-mcp runs on the files when the app isn't running. Here, on the main
//  thread, it runs on copies of the in-memory library and the wallpaper's settings, and the app
//  adopts the result: AppModel saves it (the UI and the saver's library.json follow), the live
//  wallpaper takes its new choice, the When rules re-decide, and changes to what plays show a
//  small notice with Undo (AINoticePanel). The app's own settings (get/update_settings,
//  app_action) are in AIBridgeSettings.swift.

import AppKit
import Combine
import SwiftUI

final class AIBridgeHost {
    static let shared = AIBridgeHost()
    private var server: AIBridge.Server?
    private weak var model: AppModel?

    /// Opened at launch while the store lock is held (DotStudioApp.init): dotstudio-mcp then
    /// either waits for the lock or finds this socket — never a window where both write.
    func start(model: AppModel) {
        guard server == nil else { return }
        self.model = model
        let s = AIBridge.Server(store: model.store.baseDir) { [weak self] req, reply in
            DispatchQueue.main.async {
                // A signal test waits on the network: answered when the fetch is done, never
                // holding the main thread.
                if req.op == .testSignal, let self { self.testSignal(req, reply: reply); return }
                reply(self?.handle(req) ?? .fail("DotStudio is shutting down"))
            }
        }
        if s.start() { server = s } else { Breadcrumbs.note("AI bridge: couldn't open its socket") }
    }

    func stop() {
        server?.stop()
        server = nil
    }

    var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    private func handle(_ req: BridgeRequest) -> BridgeResponse {
        guard let model else { return .fail("DotStudio isn't ready yet") }
        let who = req.client ?? "AI"
        Breadcrumbs.note("AI bridge: \(req.op.rawValue) from \(who)")
        switch req.op {
        case .ping:
            return BridgeResponse(ok: true, appVersion: appVersion)
        case .getSettings:
            return BridgeResponse(ok: true, appVersion: appVersion, settings: settingsNow(model))
        case .updateSettings:
            return updateSettings(req, model, who: who)
        case .appAction:
            return appAction(req.mode ?? "", model)
        case .upsertStyle, .deleteStyle, .duplicateStyle, .setScreensaver, .setWallpaper,
             .upsertSignal, .deleteSignal, .upsertRule, .deleteRule:
            return libraryEdit(req, model, who: who)
        case .testSignal:
            return .fail("testSignal is answered asynchronously")
        }
    }

    /// A library change: LibraryOps decides and edits (as dotstudio-mcp does on the files); the
    /// app adopts the result.
    private func libraryEdit(_ req: BridgeRequest, _ model: AppModel, who: String) -> BridgeResponse {
        let settings = AISettings.load(store: model.store.baseDir)
        let w = WallpaperController.shared
        let ctx = LibraryOps.Context(displays: DisplayRoster.shared.displays.map { DisplayEntry(key: $0.key, name: $0.name, builtIn: $0.isBuiltIn) },
                                     settings: settings, live: SignalService.shared.live)
        var lib = model.library
        var wall = w.settings.choice
        let wallBefore = wall
        let undo = LibraryOps.isNoticed(req.op) ? snapshot(model) : nil
        var r = LibraryOps.apply(req, library: &lib, wallpaper: &wall, ctx)
        guard r.ok else { return r }
        model.adoptAIEdit(lib, deleted: req.op == .deleteStyle ? req.id : nil,
                          duplicate: req.op == .duplicateStyle ? r.id : nil)    // saves
        if wall != wallBefore { w.adopt(wall) }
        switch req.op {
        case .upsertSignal, .deleteSignal, .upsertRule, .deleteRule:
            SignalService.shared.evaluate()     // decide at once, not at the next minute
        default: break
        }
        r.appVersion = appVersion
        if let undo, settings.showNotices, let msg = r.message { AINoticePanel.shared.show("\(who): \(msg)", undo: undo) }
        return r
    }

    /// test_signal: a draft (the AI host policy) or a saved signal with its Keychain key (never
    /// prompting). Only the outcome goes back — value, status, an outline — never the key.
    private func testSignal(_ req: BridgeRequest, reply: @escaping (BridgeResponse) -> Void) {
        guard let model else { reply(.fail("DotStudio isn't ready yet")); return }
        Breadcrumbs.note("AI bridge: testSignal from \(req.client ?? "AI")")
        let target: Signal
        let forAI: Bool
        if let draft = req.signal {
            target = draft
            forAI = true
        } else if let id = req.id, let s = model.library.signal(id) {
            target = s
            forAI = s.createdByAI
        } else { reply(.fail("No such signal. Call list_signals.")); return }
        SignalService.shared.test(target, forAI: forAI) { [appVersion] r in
            reply(BridgeResponse(ok: true, appVersion: appVersion, test: r))
        }
    }

    static var playbackOff: String { LibraryOps.playbackOff }

    /// What plays now, to put back on Undo.
    private func snapshot(_ model: AppModel) -> () -> Void {
        let lib = model.library
        let wall = WallpaperController.shared.settings.choice
        // Scene inputs bound to signals (delete_signal with force unbinds them), by style and effect.
        var bindings: [UUID: [UUID: [String: InputBinding]?]] = [:]
        for p in lib.presets where p.effects.contains(where: { $0.inputs != nil }) {
            // (uniquing: a hand-edited library can repeat an effect id — never trap on Undo's snapshot)
            bindings[p.id] = Dictionary(p.effects.map { ($0.id, $0.inputs) }, uniquingKeysWith: { first, _ in first })
        }
        return { [weak model] in
            guard let model else { return }
            model.library.activeID = lib.activeID
            model.library.rotation = lib.rotation
            model.library.schedule = lib.schedule
            model.library.displayStyles = lib.displayStyles
            model.library.rules = lib.rules          // When rules and signals are part of what plays
            model.library.signals = lib.signals
            for i in model.library.presets.indices {
                guard let was = bindings[model.library.presets[i].id] else { continue }
                for j in model.library.presets[i].effects.indices {
                    if let inputs = was[model.library.presets[i].effects[j].id] { model.library.presets[i].effects[j].inputs = inputs }
                }
            }
            model.save()
            WallpaperController.shared.adopt(wall)
            SignalService.shared.evaluate()
        }
    }
}

// MARK: - The notice

/// A small, quiet panel under the menu bar for a few seconds: what the AI changed, with Undo.
/// Non-activating (never steals focus), on every Space, no shadow theatrics.
final class AINoticePanel {
    static let shared = AINoticePanel()
    private var panel: NSPanel?
    private var hide: DispatchWorkItem?

    func show(_ text: String, undo: @escaping () -> Void) {
        hide?.cancel()
        panel?.orderOut(nil)
        let view = AINoticeView(text: text, undo: { [weak self] in undo(); self?.dismiss() }, close: { [weak self] in self?.dismiss() })
        let host = NSHostingView(rootView: view)
        host.setFrameSize(host.fittingSize)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        p.contentView = host
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.maxX - host.fittingSize.width - 16, y: f.maxY - host.fittingSize.height - 12))
        }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; p.animator().alphaValue = 1 }
        panel = p
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: work)
    }

    func dismiss() {
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 }) { p.orderOut(nil) }
    }
}

private struct AINoticeView: View {
    let text: String
    let undo: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(.secondary)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 300, alignment: .leading)
            Button("Undo", action: undo).controlSize(.small)
            Button(action: close) { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .padding(4)
    }
}
