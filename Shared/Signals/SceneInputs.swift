//  SceneInputs.swift — Custom Scene inputs (docs/signals-design.md §4): a package declares live
//  inputs in its manifest ("inputs": [{key, label, range, default, unit?, suggest?}], at most 8,
//  CustomSceneManifest.Input); a style connects each to a signal (EffectInstance.inputs: key →
//  InputBinding); every MetalRenderer's SignalLink turns the signal's value into ctx.input[i]
//  (declared units, clamped to the range, eased over ~20 s) and ctx.inputLive[i] (its freshness
//  0…1). Unconnected, unknown or stale → the input's default and inputLive 0, easing there as the
//  reading goes stale. Packed into u.scene[9…12] (CustomSceneLink.fillStatic; Runtime.h).
//
//  Chain: Signal → binding → input. A package only DECLARES inputs: a shared style or package can
//  never make a Mac fetch anything; the app fetches a signal only while some style binds it (or a
//  When rule tests it) — Library.referencedSignalKeys.
//
//  Read side, like WeatherLink: the saver, the wallpaper, previews, thumbnails and the gallery
//  poll <store>/signal-values.json (SignalFeed, at most every 5 s, only while a bound input
//  draws); the app hands its own in-memory state over instead (SignalLink.provider).
//  Test hooks: SignalLink.forced (preview_style `inputs`, tools/gallery) pins inputs by key.

import Foundation
import QuartzCore
import simd

/// Which signal drives one input of a Custom Scene: a built-in id ("weather.tempC") or a user
/// signal's UUID string. Tolerant: `"aqi": "weather.tempC"` (a bare string) reads too.
struct InputBinding: Codable, Equatable, Hashable {
    var signal: String

    init(signal: String) { self.signal = signal }

    private enum CodingKeys: String, CodingKey { case signal }

    init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) { signal = s; return }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        signal = (try? c.decode(String.self, forKey: .signal)) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(signal, forKey: .signal)
    }

    /// An effect's binding map, read tolerantly: anything unreadable is nil (not connected), and
    /// entries with a malformed key or no signal are dropped.
    static func decodeMap<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ k: K) -> [String: InputBinding]? {
        guard let m = (try? c.decodeIfPresent([String: InputBinding].self, forKey: k)) ?? nil else { return nil }
        let out = m.filter { CustomScenes.isInputKey($0.key) && !$0.value.signal.isEmpty && $0.value.signal.count <= 80 }
        return out.isEmpty ? nil : out
    }
}

/// What a Custom Scene pass reads for its inputs: values (declared units) and how live each is.
struct SceneInputValues: Equatable {
    var value = SIMD8<Float>(repeating: 0)
    var live = SIMD8<Float>(repeating: 0)

    /// Every input at its default, none live (unconnected; tools; a renderer without a link).
    static func defaults(_ inputs: [CustomSceneManifest.Input]) -> SceneInputValues {
        var v = SceneInputValues()
        for (i, inp) in inputs.prefix(8).enumerated() { v.value[i] = Float(inp.def) }
        return v
    }
}

/// The inputs a renderer draws: the bound signals' values, eased per effect instance.
final class SignalLink {
    /// preview_style `inputs` / tools: input key → value, pinned (live 1) in every Custom Scene
    /// that declares that key; one-off renders read it as is.
    static var forced: [String: Double]?
    /// The app: SignalService's own state (thread-safe snapshot) instead of reading the file back.
    static var provider: (() -> SignalState?)?
    static let easeSeconds: Double = 20
    static let pollSeconds: Double = 5

    private let feed: SignalFeed
    private let lock = NSLock()
    private var lastPoll: CFTimeInterval = -.infinity
    private var polled = false
    private var state: SignalState?
    private struct Eased { var v: SceneInputValues; var at: CFTimeInterval; var count: Int }
    private var eased: [UUID: Eased] = [:]

    init(baseDir: URL) { feed = SignalFeed(baseDir: baseDir) }

    /// The values for `inst`'s inputs now. `oneOff`: a thumbnail / still — no easing, no history.
    func values(for inst: EffectInstance, inputs: [CustomSceneManifest.Input], oneOff: Bool,
                now: CFTimeInterval = CACurrentMediaTime(), wall: Date = Date()) -> SceneInputValues {
        guard !inputs.isEmpty else { return SceneInputValues() }
        let forced = SignalLink.forced
        let bound = inst.inputs?.isEmpty == false
        lock.lock(); defer { lock.unlock() }
        if bound, !polled || now - lastPoll >= SignalLink.pollSeconds {
            lastPoll = now
            polled = true
            if let p = SignalLink.provider { state = p() } else { feed.poll(); state = feed.state }
        }
        let target = SignalLink.target(inputs, bindings: inst.inputs, state: bound ? state : nil, wall: wall, forced: forced)
        if oneOff || forced != nil { return target }
        var e = eased[inst.id]
        if let old = e, old.count == inputs.count, now >= old.at {
            // ~95 % of the way in easeSeconds, frame-rate independent.
            let k = Float(1 - exp(-(now - old.at) * 3 / SignalLink.easeSeconds))
            var v = old.v
            v.value += (target.value - v.value) * k
            v.live += (target.live - v.live) * k
            e = Eased(v: v, at: now, count: inputs.count)
        } else {
            e = Eased(v: target, at: now, count: inputs.count)        // the first frame just is
        }
        if eased.count > 64 { eased.removeAll() }
        eased[inst.id] = e
        SignalLink.note(inst.id, e!.v)
        return e!.v
    }

    /// Where the inputs are heading: forced, else the bound signal's value (clamped, mixed back
    /// toward the default as it goes stale), else the default.
    static func target(_ inputs: [CustomSceneManifest.Input], bindings: [String: InputBinding]?, state: SignalState?,
                       wall: Date, forced: [String: Double]?) -> SceneInputValues {
        var out = SceneInputValues()
        for (i, inp) in inputs.prefix(8).enumerated() {
            let def = inp.def
            var v = def, f = 0.0
            if let x = forced?[inp.key] {
                v = inp.clamp(x); f = 1
            } else if let sig = bindings?[inp.key]?.signal, let r = reading(sig, state: state, wall: wall) {
                f = r.freshness
                v = def + (inp.clamp(r.value) - def) * f
            }
            out.value[i] = Float(v)
            out.live[i] = Float(f)
        }
        return out
    }

    /// A signal's number now and its freshness (bools 1 / 0; weather.condition as its index).
    static func reading(_ id: String, state: SignalState?, wall: Date) -> (value: Double, freshness: Double)? {
        let key = UUID(uuidString: id)?.uuidString ?? id
        guard let sv = BuiltInSignals.clockValue(key, at: wall) ?? state?.values[key] else { return nil }
        let x: Double
        if let v = sv.v, v.isFinite { x = v }
        else if id == "weather.condition", let s = sv.s, let c = WeatherCondition(rawValue: s) { x = Double(c.index) }
        else { return nil }
        return (x, sv.freshness(at: wall))
    }

    // MARK: What the Inspector shows

    private static let shownLock = NSLock()
    private static var shown: [UUID: SceneInputValues] = [:]

    private static func note(_ id: UUID, _ v: SceneInputValues) {
        shownLock.lock()
        if shown.count > 64 { shown.removeAll() }
        shown[id] = v
        shownLock.unlock()
    }

    /// The eased values a live renderer last drew for this effect (nil: none drew it yet).
    static func lastDrawn(_ id: UUID) -> SceneInputValues? {
        shownLock.lock(); defer { shownLock.unlock() }
        return shown[id]
    }
}

// MARK: - Library

extension Library {
    /// Signals bound to an input of an enabled Custom Scene, in any style (values-map keys).
    var boundSignalKeys: Set<String> {
        var out = Set<String>()
        for p in presets {
            for e in p.effects where e.enabled && e.kind == .custom {
                for b in (e.inputs ?? [:]).values where !b.signal.isEmpty {
                    out.insert(UUID(uuidString: b.signal)?.uuidString ?? b.signal)
                }
            }
        }
        return out
    }

    /// The styles whose Custom Scene inputs a signal drives: (style, input key), in library order.
    func inputBindings(using key: String) -> [(style: Preset, input: String)] {
        var out: [(Preset, String)] = []
        for p in presets {
            for e in p.effects where e.kind == .custom {
                for (k, b) in (e.inputs ?? [:]).sorted(by: { $0.key < $1.key }) where Library.sameSignal(b.signal, key) {
                    out.append((p, k))
                }
            }
        }
        return out
    }

    /// Disconnect every input bound to `key`. Returns whether anything changed.
    @discardableResult
    mutating func unbindSignal(_ key: String) -> Bool {
        var changed = false
        for i in presets.indices {
            for j in presets[i].effects.indices {
                guard let m = presets[i].effects[j].inputs else { continue }
                let kept = m.filter { !Library.sameSignal($0.value.signal, key) }
                if kept.count != m.count {
                    presets[i].effects[j].inputs = kept.isEmpty ? nil : kept
                    changed = true
                }
            }
        }
        return changed
    }

    /// Two signal references to the same signal (a UUID in any case).
    static func sameSignal(_ a: String, _ b: String) -> Bool {
        a == b || (UUID(uuidString: a) != nil && a.caseInsensitiveCompare(b) == .orderedSame)
    }
}

extension EffectInstance {
    /// The Custom Scene's declared inputs (from the app's store), [] for anything else.
    var inputSpecs: [CustomSceneManifest.Input] { customManifest?.inputSpecs ?? [] }
}
