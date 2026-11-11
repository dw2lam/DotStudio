//  CrashReporter.swift — what DotStudio does when it crashes, and on the launch after.
//
//  During a session:
//   • Breadcrumbs: the last ~50 things the user did (a selection, opening the editor, a new
//     lineup, the wallpaper starting or stopping…), written through to breadcrumbs.txt as they
//     happen, so they are on disk whatever ends the process.
//   • Signals (CrashSignals.c): SIGSEGV/SIGBUS/SIGILL/SIGABRT/SIGFPE/SIGTRAP write one line to
//     the pre-opened crash.marker with write(2) only, then the signal goes back to the system
//     (macOS still writes its own .ips report).
//   • Exceptions: an Objective-C exception that is about to end the process (an uncaught one,
//     or one AppKit is about to crash on) has its name, reason and stack saved first
//     (exception.txt) — the .ips report alone doesn't carry the reason.
//
//  On the next launch, a non-empty crash.marker means the last session crashed: the report
//  (what happened, the breadcrumbs, this Mac, and the newest DotStudio .ips from
//  ~/Library/Logs/DiagnosticReports) is offered once in a small window — "Send Report…" copies
//  the full report and opens a pre-filled GitHub issue in the browser; nothing is ever uploaded
//  automatically. Help ▸ Report a Problem… offers the same on demand.
//
//  Safe mode: two crashes in a row, each within 60 s of its launch, and the next launch starts
//  with live previews and the live wallpaper paused (stills instead) and offers "Start Normally".
//
//  Files: ~/Library/Logs/DotStudio/ (under DOTSTUDIO_STORE_DIR/Logs for headless runs and
//  tests, or DOTSTUDIO_LOG_DIR). Earlier crashes are kept in Crashes/ (the newest 10).

import AppKit
import SwiftUI
import Metal
import ObjectiveC

// MARK: - Breadcrumbs

enum Breadcrumbs {
    static let capacity = 50
    private static let lock = NSLock()
    private static var ring: [String] = []
    private static var handle: FileHandle?
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Starts this session's file (the previous session's was read first: CrashReporter.start).
    static func open(at url: URL) {
        lock.lock(); defer { lock.unlock() }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        ring = []
    }

    /// Records one thing that happened (any thread). Cheap: a line in a 50-line ring buffer,
    /// rewritten to disk in one write.
    static func note(_ what: @autoclosure () -> String) {
        let line = "\(stamp.string(from: Date()))  \(what())"
        lock.lock(); defer { lock.unlock() }
        ring.append(line)
        if ring.count > capacity { ring.removeFirst(ring.count - capacity) }
        guard let handle else { return }
        let data = Data((ring.joined(separator: "\n") + "\n").utf8)
        try? handle.truncate(atOffset: 0)
        try? handle.write(contentsOf: data)
    }

    static var recent: [String] {
        lock.lock(); defer { lock.unlock() }
        return ring
    }
}

// MARK: - Report

struct CrashReport: Identifiable {
    let id = UUID()
    /// A crash found at launch (false: Help ▸ Report a Problem…).
    var isCrash: Bool
    /// When it crashed.
    var date: Date?
    /// One line: the signal or the exception.
    var summary: String
    /// The exception's reason and stack, when one was recorded.
    var exception: String?
    var breadcrumbs: [String]
    /// The matching macOS crash report (.ips), as text.
    var ips: String?
    var ipsName: String?
    var system: String
    /// This launch is in safe mode (two quick crashes in a row).
    var safeMode: Bool

    static let issueRepo = "dw2lam/DotStudio"
    /// GitHub's new-issue URL: kept well under the length browsers and GitHub accept.
    static let maxURLLength = 7500

    /// Everything, for the clipboard.
    var fullText: String {
        var s = "DotStudio \(isCrash ? "crash" : "problem") report\n\n"
        s += system + "\n"
        if let date { s += "Crashed: \(ISO8601DateFormatter().string(from: date))\n" }
        if isCrash { s += "What happened: \(summary)\n" }
        if safeMode { s += "Next launch: safe mode (two crashes within 60 s of launch)\n" }
        if let exception { s += "\nException:\n\(exception)\n" }
        s += "\nLast actions (oldest first):\n" + (breadcrumbs.isEmpty ? "(none)" : breadcrumbs.joined(separator: "\n")) + "\n"
        if let ips {
            s += "\nmacOS crash report (\(ipsName ?? "ips")):\n\(ips)\n"
        } else if isCrash {
            s += "\nmacOS crash report: not found in ~/Library/Logs/DiagnosticReports\n"
        }
        return s
    }

    /// A pre-filled GitHub issue. The body is the short form; the full report is on the clipboard.
    var issueURL: URL {
        let title = isCrash ? "Crash: \(summary)" : "Problem report"
        func body(crumbs: Int, exceptionLines: Int) -> String {
            var b = "<!-- The full report, including the macOS crash log, is on your clipboard: paste it below. -->\n\n"
            b += "**What were you doing?**\n\n\n"
            b += "**System**\n```\n\(system)\n```\n"
            if isCrash { b += "**What happened**: \(summary)\n\n" }
            if let exception, exceptionLines > 0 {
                b += "**Exception**\n```\n" + exception.split(separator: "\n", omittingEmptySubsequences: false)
                    .prefix(exceptionLines).joined(separator: "\n") + "\n```\n"
            }
            if crumbs > 0, !breadcrumbs.isEmpty {
                b += "**Last actions**\n```\n" + breadcrumbs.suffix(crumbs).joined(separator: "\n") + "\n```\n"
            }
            b += "\n**Full report**\n\n(paste here)\n"
            return b
        }
        // Shrink the body until the URL fits.
        for (crumbs, ex) in [(50, 40), (30, 20), (15, 10), (8, 4), (4, 2), (0, 0)] {
            if let url = Self.url(title: title, body: body(crumbs: crumbs, exceptionLines: ex)),
               url.absoluteString.count <= Self.maxURLLength { return url }
        }
        return Self.url(title: String(title.prefix(120)), body: "(The full report is on your clipboard: paste it here.)")
            ?? URL(string: "https://github.com/\(Self.issueRepo)/issues/new")!
    }

    private static func url(title: String, body: String) -> URL? {
        var c = URLComponents(string: "https://github.com/\(issueRepo)/issues/new")
        c?.queryItems = [URLQueryItem(name: "title", value: String(title.prefix(200))),
                         URLQueryItem(name: "body", value: body)]
        // URLComponents leaves "+" and "&"-safe characters alone; GitHub reads "+" as a space.
        let q = c?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        c?.percentEncodedQuery = q
        return c?.url
    }
}

// MARK: - Reporter

final class CrashReporter {
    static let shared = CrashReporter()

    private let env = ProcessInfo.processInfo.environment
    private(set) var dir: URL
    /// Set by start(): the last session crashed (offered once, at launch).
    private(set) var pending: CrashReport?
    /// This launch runs in safe mode (see the header). "Start Normally" turns it off.
    private(set) var safeMode = false
    private var started = false
    private var launchedAt = Date()

    /// Safe mode: crashes this soon after their launch count…
    static let quickCrash: TimeInterval = 60
    /// …and this many of them in a row.
    static let quickCrashesForSafeMode = 2

    private init() {
        if let d = env["DOTSTUDIO_LOG_DIR"], !d.isEmpty {
            dir = URL(fileURLWithPath: d, isDirectory: true)
        } else if let s = env["DOTSTUDIO_STORE_DIR"], !s.isEmpty {
            dir = URL(fileURLWithPath: s, isDirectory: true).appendingPathComponent("Logs", isDirectory: true)
        } else {
            dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Logs/DotStudio", isDirectory: true)
        }
    }

    private var markerURL: URL { dir.appendingPathComponent("crash.marker") }
    private var exceptionURL: URL { dir.appendingPathComponent("exception.txt") }
    private var breadcrumbsURL: URL { dir.appendingPathComponent("breadcrumbs.txt") }
    private var launchURL: URL { dir.appendingPathComponent("launch.json") }
    private var historyURL: URL { dir.appendingPathComponent("crash-history.json") }

    private struct Launch: Codable { var launchedAt: Date; var version: String; var pid: Int32 }
    private struct HistoryEntry: Codable { var launchedAt: Date; var crashedAt: Date }

    /// Reads what the previous session left (a crash?), then arms this session. Once, first
    /// thing at launch.
    func start() {
        guard !started else { return }
        started = true
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        launchedAt = Date()
        pending = collectPrevious()

        Breadcrumbs.open(at: breadcrumbsURL)
        _ = markerURL.path.withCString { dotstudio_crash_signals_install($0) }
        try? fm.removeItem(at: exceptionURL)
        if let data = try? JSONEncoder().encode(Launch(launchedAt: launchedAt, version: Self.versionString,
                                                       pid: getpid())) {
            try? data.write(to: launchURL, options: .atomic)
        }
        _ = exceptionURL.path.withCString { dotstudio_crash_exceptions_install($0) }
        installExceptionHooks()
        Breadcrumbs.note("launch \(Self.versionString)\(safeMode ? " (safe mode)" : "")")
    }

    /// The last session's crash, if it had one; files it under Crashes/ and updates the history.
    private func collectPrevious() -> CrashReport? {
        let fm = FileManager.default
        guard let marker = try? String(contentsOf: markerURL, encoding: .utf8),
              !marker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // A clean session (or the first ever): the run of quick crashes is broken.
            if fm.fileExists(atPath: launchURL.path) { saveHistory([]) }
            return nil
        }
        let previous = (try? Data(contentsOf: launchURL)).flatMap { try? Self.decoder.decode(Launch.self, from: $0) }
        let signalLine = marker.split(separator: "\n").first { $0.hasPrefix("signal ") }.map(String.init)
        var crashedAt = (try? fm.attributesOfItem(atPath: markerURL.path)[.modificationDate] as? Date) ?? Date()
        var summary = "DotStudio quit unexpectedly"
        if let line = signalLine {
            let parts = line.split(separator: " ")
            if let i = parts.firstIndex(of: "time"), i + 1 < parts.count, let t = Double(parts[i + 1]) {
                crashedAt = Date(timeIntervalSince1970: t)
            }
            if parts.count > 1, let sig = Int32(parts[1]) { summary = Self.signalName(sig) }
        }
        var exception: String?
        // The exception record is the cause only when it was raised just before the crash.
        let exceptionAt = (try? fm.attributesOfItem(atPath: exceptionURL.path)[.modificationDate] as? Date) ?? .distantPast
        if abs(crashedAt.timeIntervalSince(exceptionAt)) < 10,
           let ex = try? String(contentsOf: exceptionURL, encoding: .utf8), !ex.isEmpty {
            exception = ex
            if let first = ex.split(separator: "\n").first {
                summary = String(first.prefix(160))
            }
        }
        let crumbs = ((try? String(contentsOf: breadcrumbsURL, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        let (ips, ipsName) = Self.newestIPS(after: previous?.launchedAt ?? crashedAt.addingTimeInterval(-3600))

        // Safe mode: two quick crashes in a row.
        var history = loadHistory()
        if let launched = previous?.launchedAt {
            history.append(HistoryEntry(launchedAt: launched, crashedAt: crashedAt))
            history = Array(history.suffix(5))
        }
        saveHistory(history)
        let quick = history.reversed().prefix { $0.crashedAt.timeIntervalSince($0.launchedAt) <= Self.quickCrash }
        safeMode = quick.count >= Self.quickCrashesForSafeMode || env["DOTSTUDIO_SAFE_MODE"] == "1"

        var report = CrashReport(isCrash: true, date: crashedAt, summary: summary, exception: exception,
                                 breadcrumbs: crumbs, ips: ips, ipsName: ipsName,
                                 system: Self.systemDescription(previousVersion: previous?.version),
                                 safeMode: safeMode)
        if exception == nil, signalLine == nil { report.summary = "DotStudio quit unexpectedly" }

        // Keep it (the newest ten), then clear the marker so it's offered once.
        let stampFormatter = DateFormatter()
        stampFormatter.locale = Locale(identifier: "en_US_POSIX")
        stampFormatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let archive = dir.appendingPathComponent("Crashes", isDirectory: true)
        try? fm.createDirectory(at: archive, withIntermediateDirectories: true)
        try? report.fullText.write(to: archive.appendingPathComponent("crash-\(stampFormatter.string(from: crashedAt)).txt"),
                                   atomically: true, encoding: .utf8)
        if let old = try? fm.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "txt" }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            for url in old.dropFirst(10) { try? fm.removeItem(at: url) }
        }
        try? fm.removeItem(at: markerURL)
        try? fm.removeItem(at: exceptionURL)
        return report
    }

    private static let decoder: JSONDecoder = { let d = JSONDecoder(); return d }()

    private func loadHistory() -> [HistoryEntry] {
        (try? Data(contentsOf: historyURL)).flatMap { try? Self.decoder.decode([HistoryEntry].self, from: $0) } ?? []
    }

    private func saveHistory(_ h: [HistoryEntry]) {
        if let data = try? JSONEncoder().encode(h) { try? data.write(to: historyURL, options: .atomic) }
    }

    /// Ends safe mode for this launch ("Start Normally"); the next crash-free launch ends it anyway.
    func leaveSafeMode() {
        guard safeMode else { return }
        safeMode = false
        saveHistory([])
        Breadcrumbs.note("start normally (safe mode off)")
        NotificationCenter.default.post(name: CrashReporter.safeModeChanged, object: nil)
    }

    static let safeModeChanged = Notification.Name("DotStudioSafeModeChanged")

    /// Help ▸ Report a Problem…: the same report without a crash.
    func currentReport() -> CrashReport {
        CrashReport(isCrash: false, date: nil, summary: "Problem report", exception: nil,
                    breadcrumbs: Breadcrumbs.recent, ips: nil, ipsName: nil,
                    system: Self.systemDescription(previousVersion: nil), safeMode: safeMode)
    }

    /// The crash found at launch, once.
    func takePending() -> CrashReport? {
        defer { pending = nil }
        return pending
    }

    /// Copies the full report and opens the pre-filled issue. Never uploads anything itself.
    static func send(_ report: CrashReport) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(report.fullText, forType: .string)
        Breadcrumbs.note("report: copied, issue page opened")
        if ProcessInfo.processInfo.environment["DOTSTUDIO_CRASH_NO_OPEN"] == nil {
            NSWorkspace.shared.open(report.issueURL)
        }
    }

    // MARK: Exceptions

    private func installExceptionHooks() {
        NSSetUncaughtExceptionHandler { e in CrashReporter.record(e) }
        // AppKit catches exceptions on the main thread and then crashes on them itself
        // (NSApplicationCrashOnExceptions): record first, then let it.
        NSApplication.swizzle(#selector(NSApplication.reportException(_:)),
                              with: #selector(NSApplication.ds_reportException(_:)))
        let crashSel = NSSelectorFromString("_crashOnException:")
        if NSApplication.instancesRespond(to: crashSel) {
            NSApplication.swizzle(crashSel, with: #selector(NSApplication.ds_crashOnException(_:)))
        }
    }

    private static let recordLock = NSLock()
    private static var recorded: ObjectIdentifier?

    /// Saves an exception that is about to end the process (once per exception).
    static func record(_ e: NSException) {
        recordLock.lock(); defer { recordLock.unlock() }
        guard recorded != ObjectIdentifier(e) else { return }
        recorded = ObjectIdentifier(e)
        var s = "\(e.name.rawValue): \(e.reason ?? "(no reason)")\n"
        if let info = e.userInfo, !info.isEmpty { s += "userInfo: \(info)\n" }
        s += e.callStackSymbols.joined(separator: "\n")
        try? s.write(to: shared.exceptionURL, atomically: false, encoding: .utf8)
        dotstudio_crash_signals_note("exception \(e.name.rawValue)\n")
    }

    // MARK: System

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    static func systemDescription(previousVersion: String?) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var lines = ["DotStudio \(versionString)" + (previousVersion.map { $0 != versionString ? " (crashed in \($0))" : "" } ?? ""),
                     "macOS \(os)",
                     "Mac: \(sysctl("hw.model") ?? "?") · \(cpuDescription())"]
        let gpus = MTLCopyAllDevices().map { d -> String in
            var s = d.name
            if d.isLowPower { s += " (integrated)" }
            if d.isRemovable { s += " (external)" }
            return s
        }
        lines.append("GPU: " + (gpus.isEmpty ? "none" : gpus.joined(separator: ", ")))
        lines.append("Displays: \(NSScreen.screens.count)")
        return lines.joined(separator: "\n")
    }

    private static func cpuDescription() -> String {
        let brand = sysctl("machdep.cpu.brand_string") ?? "?"
        var arm: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let translated = sysctlbyname("sysctl.proc_translated", &arm, &size, nil, 0) == 0 && arm == 1
        return brand + (translated ? " (Rosetta)" : "")
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func signalName(_ sig: Int32) -> String {
        switch sig {
        case SIGSEGV: return "Crashed (SIGSEGV: bad memory access)"
        case SIGBUS: return "Crashed (SIGBUS: bad memory access)"
        case SIGILL: return "Crashed (SIGILL: illegal instruction)"
        case SIGABRT: return "Crashed (SIGABRT: aborted)"
        case SIGFPE: return "Crashed (SIGFPE: arithmetic error)"
        case SIGTRAP: return "Crashed (SIGTRAP: a trap or assertion)"
        default: return "Crashed (signal \(sig))"
        }
    }

    /// The newest DotStudio-*.ips written after `date`, as text (capped).
    static func newestIPS(after date: Date) -> (String?, String?) {
        let env = ProcessInfo.processInfo.environment
        let dir = env["DOTSTUDIO_DIAG_REPORTS_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Logs/DiagnosticReports", isDirectory: true)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return (nil, nil)
        }
        let candidates = files.compactMap { url -> (URL, Date)? in
            let name = url.lastPathComponent
            guard name.hasPrefix("DotStudio"), url.pathExtension == "ips",
                  let d = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  d >= date.addingTimeInterval(-5) else { return nil }
            return (url, d)
        }
        guard let newest = candidates.max(by: { $0.1 < $1.1 })?.0,
              let data = try? Data(contentsOf: newest) else { return (nil, nil) }
        let cap = 400_000
        var text = String(decoding: data.prefix(cap), as: UTF8.self)
        if data.count > cap { text += "\n… (truncated)" }
        return (text, newest.lastPathComponent)
    }
}

// MARK: - Exception hooks

extension NSApplication {
    fileprivate static func swizzle(_ original: Selector, with replacement: Selector) {
        guard let a = class_getInstanceMethod(NSApplication.self, original),
              let b = class_getInstanceMethod(NSApplication.self, replacement) else { return }
        method_exchangeImplementations(a, b)
    }

    /// After the swizzle, calling this calls AppKit's own reportException:.
    @objc dynamic fileprivate func ds_reportException(_ e: NSException) {
        CrashReporter.record(e)
        ds_reportException(e)
    }

    @objc dynamic fileprivate func ds_crashOnException(_ e: NSException) {
        CrashReporter.record(e)
        ds_crashOnException(e)
    }
}

// MARK: - Debug trigger

#if DEBUG
/// DOTSTUDIO_DEBUG_CRASH=<kind> (Debug builds only, with DOTSTUDIO_STORE_DIR): crashes on
/// purpose right after the reporter is armed, for the crash-reporter self-test
/// (tools/crash-selftest). Kinds: segv, abort, trap, exception, constraints.
enum DebugCrash {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let kind = env["DOTSTUDIO_DEBUG_CRASH"], env["DOTSTUDIO_STORE_DIR"] != nil else { return }
        Breadcrumbs.note("debug crash: \(kind)")
        switch kind {
        case "segv":
            let p = UnsafeMutablePointer<Int>(bitPattern: 0x8)!
            p.pointee = 1
        case "abort":
            abort()
        case "trap":
            let a: [Int] = []
            _ = a[Int(env["DOTSTUDIO_DEBUG_CRASH_INDEX"] ?? "3") ?? 3]
        case "exception":
            // An exception raised and never caught (the preprocessor records it as raised).
            let e = NSException(name: NSExceptionName("NSGenericException"),
                                reason: "The window has been marked as needing another Update Constraints in Window pass, but it has already had more Update Constraints in Window passes than there are views in the window. (debug)",
                                userInfo: nil)
            e.raise()
        default:
            break
        }
    }
}
#endif

#if DEBUG
/// DOTSTUDIO_CRASH_SELFTEST=<out dir> (Debug builds only, with DOTSTUDIO_STORE_DIR): prints what
/// the reporter found from the previous run (tools/crash-selftest) — the summary, safe mode,
/// the breadcrumbs, whether an .ips was matched — writes the full report and the issue URL to
/// <out dir>, and exits.
enum CrashSelfTest {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["DOTSTUDIO_CRASH_SELFTEST"], env["DOTSTUDIO_STORE_DIR"] != nil else { return }
        let dir = URL(fileURLWithPath: out, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var s = ""
        if let r = CrashReporter.shared.pending {
            s += "pending: yes\nsummary: \(r.summary)\nsafeMode: \(r.safeMode)\n"
            s += "breadcrumbs: \(r.breadcrumbs.count)\nlastBreadcrumb: \(r.breadcrumbs.last ?? "-")\n"
            s += "exception: \(r.exception == nil ? "no" : "yes")\nips: \(r.ipsName ?? "none")\n"
            s += "issueURLLength: \(r.issueURL.absoluteString.count)\n"
            try? r.fullText.write(to: dir.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
            try? r.issueURL.absoluteString.write(to: dir.appendingPathComponent("issue-url.txt"), atomically: true, encoding: .utf8)
        } else {
            s += "pending: no\nsafeMode: \(CrashReporter.shared.safeMode)\n"
        }
        FileHandle.standardOutput.write(Data(s.utf8))
        exit(0)
    }
}
#endif
