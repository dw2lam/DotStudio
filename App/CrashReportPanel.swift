//  CrashReportPanel.swift — "DotStudio quit unexpectedly" (after a crash) and Help ▸ Report a
//  Problem…: what happened, the last few actions, and the full report behind a disclosure.
//  "Send Report…" copies the full report and opens a pre-filled GitHub issue; nothing is sent
//  automatically. In safe mode it also offers "Start Normally". (CrashReporter.swift)

import AppKit
import SwiftUI

final class CrashReportPanel: NSObject, NSWindowDelegate {
    static let shared = CrashReportPanel()
    static let size = CGSize(width: 520, height: 470)
    private var panel: NSPanel?

    /// The crash found at launch, if any (a moment after launch, once the app has settled).
    func presentPendingIfNeeded() {
        guard !OffscreenCapture.isActive, let report = CrashReporter.shared.takePending() else { return }
        show(report)
    }

    /// Help ▸ Report a Problem….
    func reportProblem() {
        show(CrashReporter.shared.currentReport())
    }

    func show(_ report: CrashReport) {
        panel?.close()
        let root = CrashReportView(report: report,
                                   onSend: { [weak self] in CrashReporter.send(report); self?.close() },
                                   onDismiss: { [weak self] in self?.close() },
                                   onStartNormally: { CrashReporter.shared.leaveSafeMode() })
            .adaptiveLayout()
        let p = NSPanel(contentRect: CGRect(origin: .zero, size: Self.size),
                        styleMask: [.titled, .closable, .resizable],
                        backing: .buffered, defer: false)
        p.title = report.isCrash ? "DotStudio Quit Unexpectedly" : "Report a Problem"
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.contentViewController = NSHostingController(rootView: root)
        p.setContentSize(Self.size)
        p.contentMinSize = CGSize(width: 440, height: 360)
        p.delegate = self
        p.center()
        panel = p
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        panel?.close()
        panel = nil
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSPanel) === panel { panel = nil }
    }
}

struct CrashReportView: View {
    @Environment(\.layout) private var layout
    let report: CrashReport
    var onSend: () -> Void = {}
    var onDismiss: () -> Void = {}
    var onStartNormally: () -> Void = {}
    @State private var showDetails = false
    @State private var startedNormally = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: layout.itemGap + Space.xxs) {
                    HStack(alignment: .top, spacing: Space.m) {
                        Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                            .resizable()
                            .frame(width: 56, height: 56)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: layout.labelGap) {
                            Text(report.isCrash ? "DotStudio quit unexpectedly" : "Report a problem")
                                .textRole(.headline)
                                .wrapping()
                            Text(report.isCrash
                                 ? "Sorry about that. You can send a report so it can be fixed — it opens a pre-filled GitHub issue in your browser and copies the full report for you to paste. Nothing is sent unless you submit it."
                                 : "Describe what went wrong in a GitHub issue. The details below are copied for you to paste; nothing is sent unless you submit it.")
                                .textRole(.callout)
                                .foregroundStyle(.secondary)
                                .wrapping()
                        }
                    }
                    if report.safeMode && !startedNormally {
                        safeModeNote
                    }
                    if report.isCrash {
                        VStack(alignment: .leading, spacing: layout.labelGap) {
                            Text("What was happening").textRole(.calloutEmphasis)
                            Text(happening)
                                .textRole(.caption)
                                .foregroundStyle(.secondary)
                                .wrapping()
                        }
                    }
                    DisclosureGroup(isExpanded: $showDetails) {
                        ScrollView([.vertical, .horizontal]) {
                            Text(report.fullText)
                                .font(.system(size: 10.5, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(Space.xs)
                        }
                        .frame(minHeight: 140, maxHeight: 220)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.05)))
                    } label: {
                        Text("Report details").textRole(.callout)
                    }
                }
                .padding(Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: Space.s) {
                Spacer(minLength: 0)
                Button("Not Now", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Send Report…", action: onSend)
                    .keyboardShortcut(.defaultAction)
                    .help("Copies the full report and opens a new GitHub issue in your browser")
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.s)
        }
        .frame(minWidth: 440, minHeight: 360)
    }

    private var safeModeNote: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: layout.labelGap) {
                Text("Started in safe mode").textRole(.calloutEmphasis)
                Text("DotStudio crashed twice right after opening, so live previews and the live wallpaper are paused this time.")
                    .textRole(.caption)
                    .foregroundStyle(.secondary)
                    .wrapping()
                Button("Start Normally") {
                    startedNormally = true
                    onStartNormally()
                }
                .adaptiveControlSize(.small)
            }
        }
        .padding(Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.10)))
    }

    /// The last few actions, newest last, without timestamps.
    private var happening: String {
        let lines = report.breadcrumbs.suffix(5).map { line -> String in
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            return parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : line
        }
        let last = lines.isEmpty ? "No recent actions were recorded." : lines.joined(separator: " → ")
        return "\(report.summary).\nLast actions: \(last)"
    }
}

extension CrashReport {
    /// A made-up report for UI shots (never this Mac's).
    static func sample(safeMode: Bool, crash: Bool = true) -> CrashReport {
        CrashReport(isCrash: crash, date: crash ? Date(timeIntervalSince1970: 1_794_360_000) : nil,
                    summary: crash ? "NSGenericException: The window has been marked as needing another Update Constraints in Window pass" : "Problem report",
                    exception: crash ? "NSGenericException: The window has been marked as needing another Update Constraints in Window pass, but it has already had more Update Constraints in Window passes than there are views in the window." : nil,
                    breadcrumbs: ["10:41:02.118  launch 1.4.4 (240)",
                                  "10:41:09.502  select “Aurora” [scene aurora]",
                                  "10:41:12.871  select “Liquid Chrome” [scene liquidChrome]",
                                  "10:41:13.233  edit “Liquid Chrome” [scene liquidChrome]"],
                    ips: crash ? "{\"app_name\":\"DotStudio\",\"app_version\":\"1.4.4\" …}" : nil,
                    ipsName: crash ? "DotStudio-2026-11-11-104113.ips" : nil,
                    system: "DotStudio 1.4.4 (240)\nmacOS Version 26.6.2 (Build 25G83)\nMac: Mac15,3 · Apple M3\nGPU: Apple M3\nDisplays: 1",
                    safeMode: safeMode)
    }
}
