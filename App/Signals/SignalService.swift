//  SignalService.swift — the writer side of signal-values.json (Shared/Signals), a sibling of
//  WeatherService: the app samples the built-in signals, fetches the user's web signals and reads
//  their file signals — only while an enabled When rule tests them or a style's Custom Scene input
//  is bound to them (Library.referencedSignalKeys) — and is the ONE evaluator of
//  the When rules (RuleEngine.decide: first match wins, hysteresis, hold). It writes the values
//  and its decision as a lease, so the saver on every display, the wallpaper, the gallery and
//  dotstudio-mcp all agree on what plays; a quit app's lease runs out and the lineup returns.
//
//  Limits (docs/signals-design.md §2): a web signal at most every 5 minutes (default 15) ±10 %
//  jitter, twice as long in Low Power Mode, Retry-After honoured on 429 / 503, failures back off
//  (1, 2, 5, 10, 20 min, never past the interval), about 60 fetches an hour in all; files are
//  stat'ed every 10 s. Nothing runs while no enabled rule and no input binding exists;
//  signal-values.json is then removed. Keys come from the Keychain (SignalKeychain) without ever
//  prompting. The app's own renderers read the state in memory (SignalLink.provider = snapshot).
//
//      SignalService.shared.attach(model:)   // App.init
//      SignalService.shared.start()          // applicationDidFinishLaunching

import AppKit
import Combine
import Foundation
import IOKit.ps

final class SignalService: ObservableObject {
    static let shared = SignalService()
    private static let backoff: [TimeInterval] = [60, 120, 300, 600, 1200]
    static let hourlyBudget = 60
    static let evaluateEvery: TimeInterval = 60
    static let fileCheckEvery: TimeInterval = 10

    /// One user signal's last fetch, for Settings.
    struct Status: Equatable {
        var lastAttempt: Date?
        var bytes: Int?
        var ms: Int?
        var error: String?
        var fetching = false
        var key: SignalKeychain.Lookup?
    }

    /// What's written (and what the app itself plays by): values + the rule lease.
    @Published private(set) var state = SignalState() {
        didSet { snapLock.lock(); snap = state; snapLock.unlock() }
    }
    private let snapLock = NSLock()
    private var snap = SignalState()
    /// `state`, safe to read from any thread (the renderers' SignalLink.provider).
    func snapshot() -> SignalState? {
        snapLock.lock(); defer { snapLock.unlock() }
        return snap
    }
    @Published private(set) var statuses: [UUID: Status] = [:]

    private weak var model: AppModel?
    private var subs: [AnyCancellable] = []
    private var started = false
    private var demo = false
    private var tick: Timer?
    private var fileTick: Timer?
    private var next: [UUID: DispatchWorkItem] = [:]
    private var failures: [UUID: Int] = [:]
    private var inFlight: Set<UUID> = []
    private var fetchLog: [Date] = []
    private var fileStamps: [UUID: FileStamp?] = [:]
    private var lastWrite: Date = .distantPast
    private var writtenState: SignalState?
    private var fileURL: URL? { model.map { $0.store.baseDir.appendingPathComponent(SignalState.fileName) } }
    private var store: URL? { model?.store.baseDir }

    /// What plays by — the app's own decision (every other host reads the file).
    var live: SignalState { state }

    // MARK: Lifecycle

    func attach(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        // The lease from before a relaunch still counts until it runs out (no flash back to the lineup).
        if let url = fileURL, let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(SignalState.self, from: d) {
            state = s
            writtenState = s
        }
        subs = [model.$library.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.libraryChanged() }]
        // Every renderer in the app (previews, thumbnails, the wallpaper) reads the scene inputs
        // from here rather than the file it writes.
        SignalLink.provider = { [weak self] in self?.snapshot() }
    }

    func start() {
        guard !demo, !DemoHooks.isActive else { return }
        started = true
        SignalKeychain.pruneOrphans(keep: Set((model?.library.signals ?? []).map(\.id)))
        libraryChanged()
    }

    /// Offscreen UI shots: show these values and statuses; never fetch.
    func setDemo(values: [String: SignalValue], rule: UUID?, statuses: [UUID: Status]) {
        demo = true
        var s = SignalState()
        s.values = values
        let t = Date().timeIntervalSince1970
        s.rule = RuleLease(id: rule, since: t - 120, validUntil: t + SignalState.leaseSeconds)
        state = s
        self.statuses = statuses
    }

    // MARK: What's needed

    private var library: Library? { model?.library }

    /// Enabled rules exist, or a style binds a scene input: the service samples, evaluates and writes.
    var isActive: Bool {
        guard let lib = library else { return false }
        return (lib.rules ?? []).contains(where: \.enabled) || !lib.boundSignalKeys.isEmpty
    }

    /// User signals some enabled rule tests or some input binding uses (fetched only these).
    var neededSignals: [Signal] {
        guard let lib = library else { return [] }
        let keys = lib.referencedSignalKeys
        return (lib.signals ?? []).filter { $0.enabled && keys.contains($0.key) }
    }

    /// An enabled rule tests the weather, or an input is bound to it (WeatherService fetches for it too).
    var needsWeather: Bool { (library?.referencedSignalKeys ?? []).contains { $0.hasPrefix("weather.") } }

    func isNeeded(_ s: Signal) -> Bool { neededSignals.contains { $0.id == s.id } }

    /// What in the library the service depends on: anything else (a slider drag in the editor,
    /// a rename) changes nothing here and costs nothing.
    private struct Inputs: Equatable {
        var signals: [Signal]?
        var rules: [PlayRule]?
        var styles: [UUID]
        var bound: Set<String>
        var lat: Double?
        var lon: Double?
    }
    private var lastInputs: Inputs?

    private func libraryChanged() {
        guard started, !demo, let lib = library else { return }
        let inputs = Inputs(signals: lib.signals, rules: lib.rules, styles: lib.presets.map(\.id),
                            bound: lib.boundSignalKeys, lat: lib.locationLat, lon: lib.locationLon)
        guard inputs != lastInputs else { return }
        lastInputs = inputs
        guard isActive else { shutDown(); return }
        let needed = neededSignals
        let ids = Set(needed.map(\.id))
        // Not needed any more (or deleted): stop fetching; drop the values of deleted signals.
        for (id, work) in next where !ids.contains(id) { work.cancel(); next[id] = nil }
        let known = Set((library?.signals ?? []).map(\.key))
        let builtIns = Set(BuiltInSignals.all.map(\.id))
        state.values = state.values.filter { builtIns.contains($0.key) || known.contains($0.key) }
        statuses = statuses.filter { k, _ in known.contains(k.uuidString) }
        for s in needed where s.kind == .web && next[s.id] == nil && !inFlight.contains(s.id) {
            let last = state.values[s.key]?.at.map { Date().timeIntervalSince1970 - $0 } ?? .infinity
            schedule(s.id, after: last < s.interval ? s.interval - last : 0)
        }
        startTimers(files: needed.contains { $0.kind == .file })
        evaluate()
    }

    private func startTimers(files: Bool) {
        if tick == nil {
            let t = Timer(timeInterval: Self.evaluateEvery, repeats: true) { [weak self] _ in self?.evaluate() }
            t.tolerance = 5
            RunLoop.main.add(t, forMode: .common)
            tick = t
        }
        if files, fileTick == nil {
            let t = Timer(timeInterval: Self.fileCheckEvery, repeats: true) { [weak self] _ in self?.checkFiles() }
            t.tolerance = 2
            RunLoop.main.add(t, forMode: .common)
            fileTick = t
            checkFiles()
        } else if !files {
            fileTick?.invalidate(); fileTick = nil
        }
    }

    /// No enabled rule and no binding: nothing to watch. The file goes (a host with a stale lease
    /// plays the lineup; bound inputs fall back to their defaults).
    private func shutDown() {
        tick?.invalidate(); tick = nil
        fileTick?.invalidate(); fileTick = nil
        for w in next.values { w.cancel() }
        next.removeAll()
        let hadRule = state.rule?.id != nil
        state = SignalState()
        writtenState = nil
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        if hadRule { ruleChanged() }
    }

    // MARK: Fetching

    private func schedule(_ id: UUID, after seconds: TimeInterval) {
        next[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.next[id] = nil
            self?.fetch(id)
        }
        next[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(seconds, 0), execute: work)
    }

    /// The interval with ±10 % jitter, doubled in Low Power Mode.
    private func interval(_ s: Signal) -> TimeInterval {
        let lpm = ProcessInfo.processInfo.isLowPowerModeEnabled ? 2.0 : 1.0
        return s.interval * lpm * Double.random(in: 0.9...1.1)
    }

    private func fetch(_ id: UUID) {
        guard let s = neededSignals.first(where: { $0.id == id }), s.kind == .web, !inFlight.contains(id) else { return }
        // The hourly budget, across every signal.
        let now = Date()
        fetchLog.removeAll { now.timeIntervalSince($0) > 3600 }
        if fetchLog.count >= Self.hourlyBudget, let oldest = fetchLog.first {
            schedule(id, after: oldest.addingTimeInterval(3600).timeIntervalSince(now) + 5)
            return
        }
        var secret: String?
        var st = statuses[id] ?? Status()
        if s.auth != nil {
            let k = SignalKeychain.read(id)
            st.key = k
            guard case .found(let v) = k else {
                st.error = Self.keyStatusText(k)
                st.lastAttempt = now
                statuses[id] = st
                recordError(s, Self.keyStatusText(k))
                schedule(id, after: s.interval)       // re-checked; Settings saving a key fetches at once
                return
            }
            secret = v
        }
        fetchLog.append(now)
        inFlight.insert(id)
        st.fetching = true
        statuses[id] = st
        Perf.count("SignalService.fetch")
        SignalFetcher.fetch(s, secret: secret, location: library?.signalLocation, forAI: s.createdByAI) { [weak self] r in
            DispatchQueue.main.async { self?.fetched(id, r) }
        }
    }

    private func fetched(_ id: UUID, _ r: SignalFetchResult) {
        inFlight.remove(id)
        var st = statuses[id] ?? Status()
        st.fetching = false
        st.lastAttempt = Date()
        st.bytes = r.bytes
        st.ms = r.ms
        st.error = r.ok ? nil : r.error
        statuses[id] = st
        guard let s = neededSignals.first(where: { $0.id == id }) else { return }   // no longer needed
        if r.ok, let v = r.value {
            failures[id] = 0
            state.values[s.key] = v
            schedule(id, after: interval(s))
        } else {
            recordError(s, r.error ?? "No value")
            let n = failures[id] ?? 0
            failures[id] = n + 1
            var delay = min(Self.backoff[min(n, Self.backoff.count - 1)], s.interval)
            if let ra = r.retryAfter, r.status == 429 || r.status == 503 { delay = max(delay, ra) }
            schedule(id, after: delay)
        }
        evaluate()
    }

    /// Keep the last good value (it goes stale on its own), note the problem.
    private func recordError(_ s: Signal, _ why: String) {
        var v = state.values[s.key] ?? SignalValue(stale: s.staleAfter)
        v.error = why
        state.values[s.key] = v
    }

    private func checkFiles() {
        guard let store else { return }
        for s in neededSignals where s.kind == .file {
            let path = SignalPolicy.filesDir(store).appendingPathComponent(s.file ?? "").path
            let stamp = FileStamp(path: path)
            if let old = fileStamps[s.id], old == stamp { continue }        // unchanged since the last read
            fileStamps[s.id] = stamp
            let r = SignalFileReader.read(s, store: store)
            var st = statuses[s.id] ?? Status()
            st.lastAttempt = Date(); st.bytes = r.bytes; st.error = r.ok ? nil : r.error
            statuses[s.id] = st
            if r.ok, var v = r.value {
                // A file's value stands until the file changes or goes: whatever writes it owns
                // its freshness. `at` is when it was written.
                if let stamp { v.at = Double(stamp.sec) + Double(stamp.nsec) / 1e9 }
                v.stale = 10 * 365 * 86400
                state.values[s.key] = v
            } else {
                recordError(s, r.error ?? "No value")
            }
        }
        evaluate()
    }

    /// Settings' Retry / a key just saved: fetch now.
    func refresh(_ id: UUID) {
        failures[id] = 0
        if isNeeded(library?.signal(id) ?? Signal(name: "")) { schedule(id, after: 0) }
    }

    /// One fetch for Settings' Test or the AI's test_signal: a draft or a saved signal, with its
    /// key (never prompting unless `interactive`). Completion on the main queue.
    func test(_ s: Signal, forAI: Bool, interactive: Bool = false, completion: @escaping (SignalFetchResult) -> Void) {
        if s.kind == .file {
            let r = store.map { SignalFileReader.read(s, store: $0) } ?? SignalFetchResult(error: "No store")
            completion(r)
            return
        }
        var secret: String?
        if s.auth != nil {
            switch SignalKeychain.read(s.id, interactive: interactive) {
            case .found(let v): secret = v
            case let k:
                completion(SignalFetchResult(error: Self.keyStatusText(k), needsSecret: true))
                return
            }
        }
        SignalFetcher.fetch(s, secret: secret, location: library?.signalLocation, forAI: forAI) { r in
            DispatchQueue.main.async { completion(r) }
        }
    }

    static func keyStatusText(_ k: SignalKeychain.Lookup) -> String {
        switch k {
        case .found: return "Key saved"
        case .missing: return "Needs its key"
        case .needsReentry: return "Key needs re-entry"
        case .failed(let st): return "Keychain error \(st)"
        }
    }

    // MARK: Built-ins

    private func sampleBuiltIns(now: Date) {
        guard let lib = library else { return }
        let t = now.timeIntervalSince1970
        var v = state.values
        if let r = WeatherService.shared.reading, let at = r.fetchedAt {
            let mix = WeatherMix(r, at: now)
            let stale = WeatherState.staleAfter
            func put(_ id: String, _ x: Double?) { if let x { v[id] = SignalValue(v: (x * 1000).rounded() / 1000, at: at, stale: stale) } }
            // The same classification Custom Scenes read (DSWeather.condition): WeatherMix.condition.
            v["weather.condition"] = SignalValue(s: mix.condition.rawValue, at: at, stale: stale)
            put("weather.precip", mix.precip); put("weather.snow", mix.snow); put("weather.cloud", mix.cover)
            put("weather.fog", mix.fog); put("weather.storm", mix.storm); put("weather.wind", r.windSpeed)
            put("weather.tempC", r.temperature)
        }
        let elev = MetalRenderer.solarElevation(location: lib.signalLocation) * 180 / .pi
        v["sun.elevation"] = SignalValue(v: (elev * 2).rounded() / 2, at: t, stale: 30 * 60)
        v["sun.isDay"] = SignalValue(v: elev > -0.833 ? 1 : 0, at: t, stale: 30 * 60)
        let power = Self.powerNow()
        if let b = power.battery { v["power.battery"] = SignalValue(v: b, at: t, stale: 30 * 60) } else { v["power.battery"] = nil }
        v["power.onAC"] = SignalValue(v: power.onAC ? 1 : 0, at: t, stale: 30 * 60)
        if let store, let d = try? Data(contentsOf: store.appendingPathComponent(MusicState.fileName)),
           let m = try? JSONDecoder().decode(MusicState.self, from: d) {
            v["music.playing"] = SignalValue(v: m.isPlaying == true ? 1 : 0, at: t, stale: 30 * 60)
        } else {
            v["music.playing"] = SignalValue(v: 0, at: t, stale: 30 * 60)
        }
        if v != state.values { state.values = v }
    }

    /// Battery % (nil on a Mac without one) and whether it's on mains power.
    static func powerNow() -> (battery: Double?, onAC: Bool) {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return (nil, true) }
        let type = IOPSGetProvidingPowerSourceType(snap)?.takeUnretainedValue() as String?
        var battery: Double?
        if let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let d = IOPSGetPowerSourceDescription(snap, ps)?.takeUnretainedValue() as? [String: Any],
                      (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                      let cur = d[kIOPSCurrentCapacityKey] as? Double ?? (d[kIOPSCurrentCapacityKey] as? Int).map(Double.init),
                      let max = d[kIOPSMaxCapacityKey] as? Double ?? (d[kIOPSMaxCapacityKey] as? Int).map(Double.init), max > 0 else { continue }
                battery = (cur / max * 100).rounded()
            }
        }
        return (battery, type != kIOPMBatteryPowerKey)
    }

    // MARK: Deciding

    /// Sample, decide, write when something changed (or the lease is due).
    func evaluate() {
        guard started, !demo, isActive, let lib = library else { return }
        let now = Date()
        sampleBuiltIns(now: now)
        let values = state
        let decision = RuleEngine.decide(rules: lib.rules ?? [], styles: Set(lib.presets.map(\.id)),
                                         values: { values.value($0, at: now) }, range: { lib.signalInfo($0)?.range },
                                         isNight: Playback.isNight(lib), previous: state.rule, now: now)
        let changed = decision.id != state.rule?.id
        if changed || state.rule == nil || now.timeIntervalSince(lastWrite) >= SignalState.leaseRefresh {
            state.rule = decision
        }
        write(now: now)
        if changed {
            Breadcrumbs.note("When rule: \(decision.id.flatMap { id in lib.rules?.first { $0.id == id }?.name } ?? "none")")
            ruleChanged()
        }
    }

    private func write(now: Date) {
        guard let url = fileURL else { return }
        var s = state
        // Compare without the timestamp: write only what changed (or the lease refresh).
        s.writtenAt = writtenState?.writtenAt
        let due = now.timeIntervalSince(lastWrite) >= SignalState.leaseRefresh
        guard s != writtenState || due else { return }
        s.writtenAt = now.timeIntervalSince1970
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try enc.encode(s).write(to: url, options: .atomic)
            writtenState = s
            lastWrite = now
        } catch {
            Breadcrumbs.note("signal-values.json: couldn't write (\((error as NSError).code))")
        }
    }

    /// The rule on screen changed: the gallery re-reads what plays, a wallpaper matching the
    /// screensaver follows (with the crossfade). The saver reads the file on its own.
    private func ruleChanged() {
        model?.objectWillChange.send()
        WallpaperController.shared.signalsChanged()
    }
}
