//  AIBridgeHost.swift — the app's end of the AI bridge (Shared/AI/AIBridge.swift).
//
//  dotstudio-mcp sends each library change here while the app runs; it's applied on the main
//  thread through AppModel / WallpaperSlot — exactly the paths the gallery's own buttons take —
//  so the UI, the saver's library.json and the live wallpaper all follow at once. Changes to
//  what plays honour Settings ▸ AI ("Let AI change what plays") and show a small notice with
//  Undo (AINoticePanel).

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
            DispatchQueue.main.async { reply(self?.handle(req) ?? .fail("DotStudio is shutting down")) }
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
        func name(_ id: UUID?) -> String { id.flatMap { model.preset($0)?.name } ?? "—" }
        Breadcrumbs.note("AI bridge: \(req.op.rawValue) from \(who)")
        switch req.op {
        case .ping:
            return BridgeResponse(ok: true, appVersion: appVersion)
        case .upsertStyle:
            guard var p = req.preset else { return .fail("no style given") }
            if let n = model.library.newerBuildStyle(p.id) { return .fail(Library.newerBuildMessage(n.name)) }
            if let i = model.library.presets.firstIndex(where: { $0.id == p.id }) {
                model.library.presets[i] = p
                model.save()
                return BridgeResponse(ok: true, id: p.id, name: p.name, appVersion: appVersion, message: "Updated “\(p.name)”.")
            }
            p.name = model.library.uniqueName(p.name)
            model.library.presets.append(p)
            model.save()
            return BridgeResponse(ok: true, id: p.id, name: p.name, appVersion: appVersion, message: "Added “\(p.name)” to the library.")
        case .duplicateStyle:
            if let id = req.id, let n = model.library.newerBuildStyle(id) { return .fail(Library.newerBuildMessage(n.name)) }
            guard let id = req.id, model.preset(id) != nil, let copy = model.duplicate(id) else { return .fail("no such style") }
            if let n = req.name, let i = model.library.presets.firstIndex(where: { $0.id == copy }) {
                model.library.presets[i].name = model.library.uniqueName(n)
                model.save()
            }
            return BridgeResponse(ok: true, id: copy, name: name(copy), appVersion: appVersion, message: "Duplicated as “\(name(copy))”.")
        case .deleteStyle:
            if let id = req.id, let n = model.library.newerBuildStyle(id) { return .fail(Library.newerBuildMessage(n.name)) }
            guard let id = req.id, let p = model.preset(id) else { return .fail("no such style") }
            guard model.library.presets.count > 1 else { return .fail("“\(p.name)” is the only style; the library can't be empty.") }
            model.delete(id)
            return BridgeResponse(ok: true, id: id, name: p.name, appVersion: appVersion, message: "Deleted “\(p.name)”.")
        case .setScreensaver, .setWallpaper:
            let settings = AISettings.load(store: model.store.baseDir)
            guard settings.allowPlaybackChanges else { return .fail(Self.playbackOff) }
            let undo = snapshot(model)
            let r = req.op == .setScreensaver ? screensaver(req, model) : wallpaper(req, model)
            if r.ok, settings.showNotices, let msg = r.message {
                AINoticePanel.shared.show("\(who): \(msg)", undo: undo)
            }
            return r
        }
    }

    static let playbackOff = "The user has turned off “Let AI change what plays” in DotStudio ▸ Settings ▸ AI. Styles can still be created; ask the user to set it themselves, or to turn that setting on."

    /// What plays now, to put back on Undo.
    private func snapshot(_ model: AppModel) -> () -> Void {
        let lib = model.library
        let wall = WallpaperController.shared.settings
        return { [weak model] in
            guard let model else { return }
            model.library.activeID = lib.activeID
            model.library.rotation = lib.rotation
            model.library.schedule = lib.schedule
            model.library.displayStyles = lib.displayStyles
            model.save()
            let w = WallpaperController.shared
            if !wall.enabled {
                if w.settings.enabled { w.stop() }
            } else if wall.followsScreensaver {
                w.update { $0.displayStyles = wall.displayStyles }
                w.setFollowsScreensaver(true)
            } else if let id = wall.presetID {
                w.update { $0.displayStyles = wall.displayStyles }
                w.use(id)
            }
        }
    }

    private func display(_ key: String?) -> DisplayInfo? {
        guard let key else { return nil }
        return DisplayRoster.shared.display(key)
    }

    private func screensaver(_ req: BridgeRequest, _ model: AppModel) -> BridgeResponse {
        let mode = req.mode ?? "only"
        func name(_ id: UUID?) -> String { id.flatMap { model.preset($0)?.name } ?? "—" }
        if mode == "unpin" {
            guard let d = display(req.display) else { return .fail("No connected display has that key. Call list_displays.") }
            model.setScreensaverStyle(nil, on: d)
            return BridgeResponse(ok: true, appVersion: appVersion, message: "\(d.name) plays the screensaver lineup again.")
        }
        if mode == "dayOnly" {
            model.setNight(nil)
            return BridgeResponse(ok: true, appVersion: appVersion, message: "No separate night screensaver any more.")
        }
        guard let id = req.id, model.preset(id) != nil else { return .fail("no such style") }
        switch mode {
        case "only":
            if req.display != nil {
                guard let d = display(req.display) else { return .fail("No connected display has that key. Call list_displays.") }
                model.setScreensaverStyle(id, on: d)
                return BridgeResponse(ok: true, id: id, name: name(id), appVersion: appVersion, message: "Set “\(name(id))” as the screensaver on \(d.name).")
            }
            model.playAsScreensaverEverywhere(id)
            return BridgeResponse(ok: true, id: id, name: name(id), appVersion: appVersion, message: "Set “\(name(id))” as your screensaver.")
        case "add":
            model.addToPlaylist(id)
            return BridgeResponse(ok: true, id: id, name: name(id), appVersion: appVersion, message: "Added “\(name(id))” to the screensaver rotation.")
        case "remove":
            guard model.screensaverLineup.playlist.count > 1, model.isInPlaylist(id) else {
                return .fail("“\(name(id))” isn't in the rotation, or it's the only style playing (something always plays).")
            }
            model.removeFromPlaylist(id)
            return BridgeResponse(ok: true, id: id, name: name(id), appVersion: appVersion, message: "Took “\(name(id))” out of the screensaver rotation.")
        case "night":
            model.setNight(id)
            return BridgeResponse(ok: true, id: id, name: name(id), appVersion: appVersion, message: "Set “\(name(id))” as the screensaver after sunset.")
        default:
            return .fail("unknown screensaver mode \(mode)")
        }
    }

    private func wallpaper(_ req: BridgeRequest, _ model: AppModel) -> BridgeResponse {
        let slot = WallpaperSlot.shared
        func name(_ id: UUID?) -> String { id.flatMap { model.preset($0)?.name } ?? "—" }
        switch req.mode ?? "set" {
        case "off":
            slot.stop()
            return BridgeResponse(ok: true, appVersion: appVersion, message: "Turned the live wallpaper off.")
        case "follow":
            WallpaperController.shared.setFollowsScreensaver(true)
            return BridgeResponse(ok: true, appVersion: appVersion, message: "The live wallpaper now matches the screensaver.")
        case "unpin":
            guard let d = display(req.display) else { return .fail("No connected display has that key. Call list_displays.") }
            slot.set(nil, on: d)
            return BridgeResponse(ok: true, appVersion: appVersion, message: "\(d.name) shows the shared wallpaper again.")
        case "set":
            guard let id = req.id, model.preset(id) != nil else { return .fail("no such style") }
            if req.display != nil {
                guard let d = display(req.display) else { return .fail("No connected display has that key. Call list_displays.") }
                slot.set(id, on: d)
                return BridgeResponse(ok: true, id: id, name: name(id), appVersion: appVersion, message: "Set “\(name(id))” as the live wallpaper on \(d.name).")
            }
            slot.setEverywhere(id)
            return BridgeResponse(ok: true, id: id, name: name(id), appVersion: appVersion, message: "Set “\(name(id))” as your live wallpaper.")
        default:
            return .fail("unknown wallpaper mode")
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
