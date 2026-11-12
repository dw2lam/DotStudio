//  SafeNumbers.swift — float → integer conversions that never trap, and the clamp every
//  effect param gets when a library or a shared .dotstudiopreset is decoded.
//
//  Swift's Int(_:) traps on NaN, ±infinity and anything outside Int's range. Params come from
//  files (a library written by another build, a preset someone shared), so any conversion of a
//  param or a value derived from one uses these instead; decoding also clamps every param to its
//  ParamSpec range (EffectInstance.sanitizeParams), so a shader never sees 1e300 either.

import Foundation

extension Int {
    /// `v` rounded by `rule` (default: toward zero, as Int(_:) does), never trapping: NaN gives
    /// `nan`, ±infinity and out-of-range values the nearest of ±2⁵³ (exact in a Double, far
    /// outside any index or count this code uses).
    init<F: BinaryFloatingPoint>(saturating v: F, _ rule: FloatingPointRoundingRule = .towardZero, nan: Int = 0) {
        guard !v.isNaN else { self = nan; return }
        let limit = 9_007_199_254_740_992.0           // 2⁵³
        let d = Double(v).rounded(rule)
        self = Int(Swift.min(Swift.max(d, -limit), limit))
    }
}

extension Int32 {
    /// As Int(saturating:), clamped to Int32's range.
    init<F: BinaryFloatingPoint>(saturating v: F, _ rule: FloatingPointRoundingRule = .towardZero, nan: Int32 = 0) {
        guard !v.isNaN else { self = nan; return }
        let d = Double(v).rounded(rule)
        self = Int32(Swift.min(Swift.max(d, Double(Int32.min)), Double(Int32.max)))
    }
}

extension UInt32 {
    /// As Int(saturating:), clamped to UInt32's range (negative → 0).
    init<F: BinaryFloatingPoint>(saturating v: F, _ rule: FloatingPointRoundingRule = .towardZero) {
        guard !v.isNaN else { self = 0; return }
        let d = Double(v).rounded(rule)
        self = UInt32(Swift.min(Swift.max(d, 0), Double(UInt32.max)))
    }
}

extension UInt8 {
    /// As Int(saturating:), clamped to 0…255.
    init<F: BinaryFloatingPoint>(saturating v: F, _ rule: FloatingPointRoundingRule = .towardZero) {
        guard !v.isNaN else { self = 0; return }
        self = UInt8(Swift.min(Swift.max(Double(v).rounded(rule), 0), 255))
    }
}

extension Double {
    /// Self when finite, else `fallback`.
    func finite(or fallback: Double) -> Double { isFinite ? self : fallback }
}

// MARK: - Param sanitizing

extension ParamSpec {
    /// `v` inside this param's range; a non-finite value becomes the default. An in-range value
    /// is returned untouched (bit for bit).
    func sanitize(_ v: Double) -> Double {
        guard v.isFinite else { return def }
        let lo = Swift.min(min, max), hi = Swift.max(min, max)
        return v < lo ? lo : v > hi ? hi : v
    }
}

extension EffectInstance {
    /// Every known param clamped to its ParamSpec range (non-finite → the default); params this
    /// build has no spec for are kept unless they're non-finite (then dropped: nothing here reads
    /// them, and the effect's own default stands in). Returns whether anything changed.
    @discardableResult
    mutating func sanitizeParams() -> Bool {
        var changed = false
        // A Custom Scene's package reference is a folder name: anything that isn't one (a path, a
        // hand-edited file) is dropped, and the style draws its stand-in (CustomScenes.isValidID).
        // Its params have no spec here (they're the package manifest's): kept while finite, and
        // clamped to the manifest's ranges when they're packed (CustomSceneLink).
        if let ref = custom, kind != .custom || !CustomScenes.isValidID(ref.id) { custom = nil; changed = true }
        guard !params.isEmpty else { return changed }
        let specs = kind.params
        for (key, v) in params {
            if let spec = specs.first(where: { $0.key == key }) {
                let s = spec.sanitize(v)
                if s.bitPattern != v.bitPattern { params[key] = s; changed = true }
            } else if !v.isFinite {
                params[key] = nil
                changed = true
            }
        }
        return changed
    }
}

extension Preset {
    /// Params clamped (EffectInstance.sanitizeParams) and fps kept to 1…120. Returns whether
    /// anything changed.
    @discardableResult
    mutating func sanitize() -> Bool {
        var changed = false
        for i in effects.indices where effects[i].sanitizeParams() { changed = true }
        let f = Swift.min(Swift.max(fps, 1), 120)
        if f != fps { fps = f; changed = true }
        return changed
    }
}

extension Library {
    /// Every style (and the ones kept for a newer build) sanitized, and the few library-level
    /// numbers a renderer divides by or converts kept finite and in range. Cheap: a walk over the
    /// params, run once per decode.
    @discardableResult
    mutating func sanitize() -> Bool {
        var changed = false
        for i in presets.indices where presets[i].sanitize() { changed = true }
        for i in unknownPresets.indices where unknownPresets[i].preset.sanitize() { changed = true }
        if let r = renderScale, !(r.isFinite && r > 0) { renderScale = nil; changed = true }
        else if let r = renderScale, r > 1 { renderScale = 1; changed = true }
        if var rot = rotation {
            // (Playback floors the interval at 15 s itself; only what it can't handle is replaced)
            let iv = rot.intervalMinutes.isFinite && rot.intervalMinutes > 0 ? rot.intervalMinutes : 5
            let tr = rot.transitionSeconds.isFinite && rot.transitionSeconds >= 0 ? rot.transitionSeconds : 1.5
            if iv != rot.intervalMinutes || tr != rot.transitionSeconds {
                rot.intervalMinutes = iv; rot.transitionSeconds = tr
                rotation = rot; changed = true
            }
        }
        if let s = source.slideSeconds, !s.isFinite { source.slideSeconds = nil; changed = true }
        if let m = source.motion, !m.isFinite { source.motion = nil; changed = true }
        if let la = locationLat, !(la.isFinite && abs(la) <= 90) { locationLat = nil; changed = true }
        if let lo = locationLon, !(lo.isFinite && abs(lo) <= 180) { locationLon = nil; changed = true }
        return changed
    }
}
