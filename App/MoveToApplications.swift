//  MoveToApplications.swift — once, at launch: DotStudio opened from the disk image, Downloads
//  or another folder (or translocated by Gatekeeper) offers to move itself into /Applications,
//  because updates and Open at login need a stable copy there. Move & Relaunch copies it in
//  (replacing an older copy only after asking), clears quarantine only when the copy carries it,
//  opens the new copy and quits. Never under UI shots, demos, tests or a dev build.
//  The rule for "where" is AppLocation (SetupGuideStore.swift, checked by setup-guide-check).

import AppKit
import SwiftUI

@MainActor
final class MoveToApplications: NSObject, NSWindowDelegate, ObservableObject {
    static let shared = MoveToApplications()
    /// Asked once (Move or Not Now): never again.
    static let askedKey = "moveToApplicationsAsked"
    static let destination = URL(fileURLWithPath: "/Applications/DotStudio.app")

    enum Phase: Equatable {
        case ask
        /// /Applications already has a DotStudio: replace it? (its version, ours)
        case replace(existing: String, ours: String)
        case moving
        case failed(String)
    }

    @Published private(set) var phase: Phase = .ask
    private var panel: NSPanel?

    /// UI shots: a pinned phase.
    init(demo: Phase) { phase = demo }
    private override init() {}

    /// Anything that isn't a real person launching a real copy.
    static var isSuppressed: Bool {
        let env = ProcessInfo.processInfo.environment
        let testKeys = ["DOTSTUDIO_STORE_DIR", "DOTSTUDIO_UI_SHOTS", "DOTSTUDIO_SHOTS", "DOTSTUDIO_CLICK_PROBE",
                        "DOTSTUDIO_PERF_PROBE", "DOTSTUDIO_COACH_SELFTEST", "DOTSTUDIO_MIGRATE_ONLY", "XCTestConfigurationFilePath"]
        return OffscreenCapture.isActive || DemoHooks.isActive || testKeys.contains { env[$0] != nil }
    }

    /// At launch (a second after it settles): offer once when DotStudio runs from the wrong place.
    func offerIfNeeded() {
        guard !Self.isSuppressed,
              !AppPrefs.shared.bool(Self.askedKey, default: false),
              AppLocation.shouldOfferMove(bundlePath: Bundle.main.bundlePath,
                                          home: FileManager.default.homeDirectoryForCurrentUser.path)
        else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.show() }
    }

    private func show() {
        guard panel == nil else { return }
        AppPrefs.shared.set(true, Self.askedKey)
        let root = MoveToApplicationsView(mover: self).adaptiveLayout()
        let host = NSHostingController(rootView: root)
        let p = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 440, height: 220),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        p.title = "Move to Applications"
        p.isReleasedWhenClosed = false
        p.contentViewController = host
        p.delegate = self
        p.center()
        panel = p
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    func notNow() { panel?.close() }

    func windowWillClose(_ notification: Notification) {
        panel?.contentViewController = nil
        panel = nil
    }

    // MARK: Moving

    private static func version(of url: URL) -> String {
        let info = Bundle(url: url)?.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    /// "Move & Relaunch": asks before replacing a copy already in Applications.
    func move() {
        let dest = Self.destination
        if FileManager.default.fileExists(atPath: dest.path) {
            phase = .replace(existing: Self.version(of: dest), ours: Self.version(of: Bundle.main.bundleURL))
            return
        }
        perform(replacing: false)
    }

    func confirmReplace() { perform(replacing: true) }

    private func perform(replacing: Bool) {
        phase = .moving
        let source = Bundle.main.bundleURL
        let dest = Self.destination
        Task.detached(priority: .userInitiated) {
            let result = Self.install(source: source, dest: dest, replacing: replacing)
            await MainActor.run {
                switch result {
                case .success: Self.relaunch(dest)
                case .failure(let message): self.phase = .failed(message)
                }
            }
        }
    }

    enum Outcome { case success, failure(String) }

    /// Copies next to the destination first, then swaps it in (the old copy goes to the Trash),
    /// so a failure never leaves Applications without a DotStudio.
    nonisolated static func install(source: URL, dest: URL, replacing: Bool) -> Outcome {
        let fm = FileManager.default
        let staging = dest.deletingLastPathComponent().appendingPathComponent(".DotStudio-moving-\(UUID().uuidString).app")
        do {
            try fm.copyItem(at: source, to: staging)
        } catch {
            return .failure(permissionAware(error))
        }
        do {
            if fm.fileExists(atPath: dest.path) {
                guard replacing else { try? fm.removeItem(at: staging); return .failure("A DotStudio is already in Applications.") }
                do { try fm.trashItem(at: dest, resultingItemURL: nil) } catch { try fm.removeItem(at: dest) }
            }
            try fm.moveItem(at: staging, to: dest)
        } catch {
            try? fm.removeItem(at: staging)
            return .failure(permissionAware(error))
        }
        // A quarantined copy would be translocated again: clear it, but only when it's there
        // (the user already approved this app to get this far).
        if getxattr(dest.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            p.arguments = ["-dr", "com.apple.quarantine", dest.path]
            try? p.run()
            p.waitUntilExit()
        }
        return .success
    }

    private nonisolated static func permissionAware(_ error: Error) -> String {
        let ns = error as NSError
        let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? $0.code : nil }
        let denied = ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError
            || posix == Int(EACCES) || posix == Int(EPERM)
        if denied {
            return "DotStudio doesn't have permission to write to the Applications folder. In Finder, drag DotStudio into Applications (you may be asked for an administrator password), then open it from there."
        }
        return "DotStudio couldn't move itself: \(ns.localizedDescription) In Finder, drag DotStudio into Applications, then open it from there."
    }

    /// Opens the new copy once this one has quit, then quits.
    private static func relaunch(_ dest: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                       "relaunch", String(pid), dest.path]
        do { try p.run() } catch {
            MoveToApplications.shared.phase = .failed("DotStudio moved to Applications but couldn't reopen itself. Open it from Applications.")
            return
        }
        NSApp.terminate(nil)
    }
}

// MARK: - The sheet

struct MoveToApplicationsView: View {
    @Environment(\.layout) private var layout
    @ObservedObject var mover: MoveToApplications

    var body: some View {
        VStack(alignment: .leading, spacing: layout.itemGap) {
            HStack(alignment: .top, spacing: layout.itemGap) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: layout.labelGap) {
                    Text(title).textRole(.headline).wrapping()
                    Text(message).textRole(.callout).foregroundStyle(.secondary).wrapping()
                }
            }
            HStack(spacing: layout.controlGap) {
                Spacer(minLength: 0)
                buttons
            }
        }
        .padding(layout.cardPadding)
        .frame(width: 440, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var title: String {
        switch mover.phase {
        case .ask, .moving: return "Move DotStudio to Applications?"
        case .replace: return "Replace the DotStudio in Applications?"
        case .failed: return "Couldn't Move DotStudio"
        }
    }

    private var message: String {
        switch mover.phase {
        case .ask, .moving:
            return "Updates and Open at login need DotStudio in your Applications folder. DotStudio copies itself there and reopens."
        case .replace(let existing, let ours):
            return "Applications already has DotStudio \(existing). It goes to the Trash and this copy (\(ours)) takes its place."
        case .failed(let message):
            return message
        }
    }

    @ViewBuilder private var buttons: some View {
        switch mover.phase {
        case .ask:
            Button { mover.notNow() } label: { Text("Not Now").textRole(.body) }
                .keyboardShortcut(.cancelAction)
            Button { mover.move() } label: { Text("Move & Relaunch").textRole(.body) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        case .replace:
            Button { mover.notNow() } label: { Text("Cancel").textRole(.body) }
                .keyboardShortcut(.cancelAction)
            Button { mover.confirmReplace() } label: { Text("Replace & Relaunch").textRole(.body) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        case .moving:
            ProgressView().controlSize(.small)
            Text("Moving\u{2026}").textRole(.body).foregroundStyle(.secondary)
        case .failed:
            Button { mover.notNow() } label: { Text("OK").textRole(.body) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }
}
