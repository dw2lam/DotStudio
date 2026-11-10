//  Preset.swift — the document model shared by the app and the saver.

import Foundation
import simd

struct RGBA: Codable, Equatable, Hashable {
    var r: Double, g: Double, b: Double, a: Double
    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    var simd: simd_float4 { simd_float4(Float(r), Float(g), Float(b), Float(a)) }

    static let black = RGBA(0, 0, 0)
    static let white = RGBA(1, 1, 1)
    static let crtGreen = RGBA(0.18, 1.0, 0.36)
    static let amber = RGBA(1.0, 0.72, 0.20)
    static let ink = RGBA(0.07, 0.08, 0.10)
    static let paper = RGBA(0.93, 0.92, 0.88)
    static let navy = RGBA(0.05, 0.07, 0.16)
    static let cyan = RGBA(0.2, 0.9, 1.0)
}

enum SourceKind: String, Codable, CaseIterable {
    case gradient, image, video
    /// A slowly panning, cross-fading photo slideshow: the built-in curated set, or the
    /// user's own photos when `SourceSpec.mediaFilenames` is non-empty.
    case collection

    /// Unknown kinds (a library written by a newer build) decode as a gradient instead
    /// of failing the whole library.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SourceKind(rawValue: raw) ?? .gradient
    }
}

struct SourceSpec: Codable, Equatable, Hashable {
    var kind: SourceKind = .gradient
    var mediaFilename: String?            // file inside the shared media/ folder
    var colorA: RGBA = .navy              // gradient start
    var colorB: RGBA = .cyan              // gradient end
    var gradientAngle: Double = 1.1
    var gradientDrift: Double = 1.0
    var fillMode: Int = 1                 // 0 fit, 1 cover, 2 stretch

    // Collection (slideshow) settings. Optional so older libraries still decode.
    /// The user's own slideshow photos (files in media/); nil or empty = the built-in set.
    var mediaFilenames: [String]?
    /// Seconds each photo holds before cross-fading to the next; nil = default.
    var slideSeconds: Double?
    /// Ken Burns pan/zoom strength, 0 (still) – 1; nil = default.
    var motion: Double?

    static let defaultSlideSeconds = 24.0
    static let defaultMotion = 1.0
    var slideInterval: Double { max(slideSeconds ?? SourceSpec.defaultSlideSeconds, 4) }
    var motionAmount: Double { min(max(motion ?? SourceSpec.defaultMotion, 0), 1) }
    var usesBuiltInPhotos: Bool { kind == .collection && (mediaFilenames ?? []).isEmpty }

    /// The built-in photo slideshow: the default canvas for Looks.
    static var builtInPhotos: SourceSpec {
        var s = SourceSpec(); s.kind = .collection; return s
    }
}

struct EffectInstance: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var kind: EffectKind
    var enabled: Bool = true
    var params: [String: Double] = [:]
    var colorA: RGBA?                     // overrides palette default when set
    var colorB: RGBA?

    // Bounce (Retro pack): the logo that bounces (BounceLogo in Scenes/Bounce.swift). All nil
    // (and never written) for every other effect, and for Bounce's built-in DotStudio mark.
    // Optional and add-only, so older libraries decode and save back unchanged.
    /// Which logo: nil = the built-in mark.
    var logoKind: BounceLogoKind?
    /// The Text logo's word (kept while another kind is picked, so switching back restores it).
    var logoText: String?
    /// The Image logo: a file in the shared media/ folder (SharedStore.importMedia).
    var logoFile: String?

    init(_ kind: EffectKind) {
        self.kind = kind
        self.params = kind.defaultParams
        self.colorA = kind.defaultColorA
        self.colorB = kind.defaultColorB
    }
}

/// A named effect style. The source it renders is global (see Library.source).
struct Preset: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String
    var effects: [EffectInstance] = []
    var fps: Int = 30

    /// Legacy per-style source — only decoded so old libraries can migrate.
    var source: SourceSpec?

    /// Effects of a kind this build doesn't know (a library or share file written by a newer
    /// DotStudio), kept verbatim with their place in the stack: never drawn or shown, but
    /// written back on save, so opening a newer library here doesn't destroy them.
    var unknownEffects: [UnknownEffect] = []
}

/// An effect this build can't decode, as it was in the file (see Preset.unknownEffects).
struct UnknownEffect: Equatable, Hashable {
    /// Its position in the stored `effects` array.
    var index: Int
    var json: JSONValue
}

extension Preset {
    /// Scene = the first enabled effect generates its own image (no source needed).
    var isScene: Bool { effects.first(where: { $0.enabled })?.kind.isScene ?? false }
}

/// Sun-driven day/night preset scheduling.
struct ScheduleSpec: Codable, Equatable {
    var enabled: Bool = false
    var dayPresetID: UUID?
    var nightPresetID: UUID?
}

/// Automatic preset rotation for the screensaver.
struct RotationSpec: Codable, Equatable {
    var enabled: Bool = false
    var intervalMinutes: Double = 5
    var shuffle: Bool = false
    var transitionSeconds: Double = 1.5
    /// Restrict rotation to these presets; nil = rotate through all.
    var presetIDs: [UUID]?
}

/// The whole on-disk library: one shared source + the saved styles.
struct Library: Codable, Equatable {
    var presets: [Preset] = []
    var source: SourceSpec = SourceSpec()
    var activeID: UUID?
    var version: Int = 4          // 3 = slideshow source era, 4 = seenBuiltIns (see AppModel.migrate)
    var locationLat: Double?     // resolved device location (for the Universe marker)
    var locationLon: Double?
    /// Saver render resolution as a fraction of native (1 = full Retina). Optional so
    /// older builds still decode the library; nil means full quality.
    var renderScale: Double?
    /// Automatic preset rotation; nil = show the active preset only.
    var rotation: RotationSpec?
    /// Day/night scheduling; when enabled it overrides rotation.
    var schedule: ScheduleSpec?
    /// Music card / take-over settings (Shared/Music/MusicSpec.swift); nil = defaults.
    var music: MusicSpec?
    /// Names of built-in presets this library has already been offered, so new built-ins
    /// (e.g. Now Playing, Tidewater) are added to existing libraries exactly once (migration v4).
    var seenBuiltIns: [String]?
    /// "Match Screensaver" sync: the saver (and a wallpaper that follows it) animate on the
    /// shared wall-clock time base (MetalRenderer.TimeBase.wallClock), so the screensaver
    /// starts on exactly the frame the desktop was showing. nil/false = per-instance time.
    var syncTimeBase: Bool?

    /// Styles made only of effects this build doesn't know (Preset.isUnknownToThisBuild), with
    /// their place in the stored list: left out of `presets` (nothing here can draw them), but
    /// written back on save.
    var unknownPresets: [UnknownPreset] = []
}

/// A style this build can't draw, kept for the newer DotStudio that wrote it (Library.unknownPresets).
struct UnknownPreset: Equatable {
    /// Its position in the stored `presets` array.
    var index: Int
    var preset: Preset
}

/// Forward compatibility: an effect whose kind this build doesn't know is skipped, not fatal
/// (a newer DotStudio adds kinds; an unknown one used to make the whole library undecodable).
/// Every other field decodes exactly as the synthesized Codable did.
extension Preset {
    private enum CodingKeys: String, CodingKey { case id, name, effects, fps, source }
    private enum KindKey: String, CodingKey { case kind }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        var items = try c.nestedUnkeyedContainer(forKey: .effects)
        var index = 0
        while !items.isAtEnd {
            let item = try items.superDecoder()
            let kind = try item.container(keyedBy: KindKey.self).decode(String.self, forKey: .kind)
            if EffectKind(rawValue: kind) != nil {
                effects.append(try EffectInstance(from: item))
            } else {
                unknownEffects.append(UnknownEffect(index: index, json: try JSONValue(from: item)))
            }
            index += 1
        }
        fps = try c.decode(Int.self, forKey: .fps)
        source = try c.decodeIfPresent(SourceSpec.self, forKey: .source)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        var list = c.nestedUnkeyedContainer(forKey: .effects)
        var known = effects[...]
        var unknown = unknownEffects[...]
        var index = 0
        // Each unknown effect back at its stored position (or at the end, if the stack shrank).
        while !known.isEmpty || !unknown.isEmpty {
            if let u = unknown.first, u.index <= index || known.isEmpty {
                try list.encode(u.json); unknown = unknown.dropFirst()
            } else {
                try list.encode(known.first!); known = known.dropFirst()
            }
            index += 1
        }
        try c.encode(fps, forKey: .fps)
        try c.encodeIfPresent(source, forKey: .source)
    }

    /// Every stored effect was of an unknown kind: nothing this build could draw.
    var isUnknownToThisBuild: Bool { effects.isEmpty && !unknownEffects.isEmpty }
}

/// Library: as the synthesized Codable, except `presets` (see unknownPresets).
extension Library {
    private enum CodingKeys: String, CodingKey {
        case presets, source, activeID, version, locationLat, locationLon, renderScale, rotation,
             schedule, music, seenBuiltIns, syncTimeBase
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try c.decode([Preset].self, forKey: .presets)
        for (i, p) in stored.enumerated() {
            if p.isUnknownToThisBuild { unknownPresets.append(UnknownPreset(index: i, preset: p)) }
            else { presets.append(p) }
        }
        source = try c.decode(SourceSpec.self, forKey: .source)
        activeID = try c.decodeIfPresent(UUID.self, forKey: .activeID)
        version = try c.decode(Int.self, forKey: .version)
        locationLat = try c.decodeIfPresent(Double.self, forKey: .locationLat)
        locationLon = try c.decodeIfPresent(Double.self, forKey: .locationLon)
        renderScale = try c.decodeIfPresent(Double.self, forKey: .renderScale)
        rotation = try c.decodeIfPresent(RotationSpec.self, forKey: .rotation)
        schedule = try c.decodeIfPresent(ScheduleSpec.self, forKey: .schedule)
        music = try c.decodeIfPresent(MusicSpec.self, forKey: .music)
        seenBuiltIns = try c.decodeIfPresent([String].self, forKey: .seenBuiltIns)
        syncTimeBase = try c.decodeIfPresent(Bool.self, forKey: .syncTimeBase)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        var stored = presets
        for u in unknownPresets { stored.insert(u.preset, at: min(u.index, stored.count)) }
        try c.encode(stored, forKey: .presets)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(activeID, forKey: .activeID)
        try c.encode(version, forKey: .version)
        try c.encodeIfPresent(locationLat, forKey: .locationLat)
        try c.encodeIfPresent(locationLon, forKey: .locationLon)
        try c.encodeIfPresent(renderScale, forKey: .renderScale)
        try c.encodeIfPresent(rotation, forKey: .rotation)
        try c.encodeIfPresent(schedule, forKey: .schedule)
        try c.encodeIfPresent(music, forKey: .music)
        try c.encodeIfPresent(seenBuiltIns, forKey: .seenBuiltIns)
        try c.encodeIfPresent(syncTimeBase, forKey: .syncTimeBase)
    }

    /// The effects and styles this build skipped (a library written by a newer DotStudio).
    var unknownCounts: (effects: Int, presets: Int) {
        (presets.reduce(0) { $0 + $1.unknownEffects.count }, unknownPresets.count)
    }
}

extension Library {
    /// The renderer time base the screensaver uses for this library.
    var rendererTimeBase: MetalRenderer.TimeBase { (syncTimeBase ?? false) ? .wallClock : .instance }
}

/// Any JSON value, kept verbatim: what this build can't model but must write back unchanged
/// (UnknownEffect).
enum JSONValue: Codable, Equatable, Hashable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        if var a = try? decoder.unkeyedContainer() {
            var out: [JSONValue] = []
            while !a.isAtEnd { out.append(try a.decode(JSONValue.self)) }
            self = .array(out)
        } else if let o = try? decoder.container(keyedBy: AnyKey.self) {
            var out: [String: JSONValue] = [:]
            for k in o.allKeys { out[k.stringValue] = try o.decode(JSONValue.self, forKey: k) }
            self = .object(out)
        } else {
            let v = try decoder.singleValueContainer()
            if v.decodeNil() { self = .null }
            else if let b = try? v.decode(Bool.self) { self = .bool(b) }
            else if let n = try? v.decode(Double.self) { self = .number(n) }
            else { self = .string(try v.decode(String.self)) }
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .array(let a):
            var c = encoder.unkeyedContainer()
            for v in a { try c.encode(v) }
        case .object(let o):
            var c = encoder.container(keyedBy: AnyKey.self)
            for (k, v) in o { try c.encode(v, forKey: AnyKey(k)) }
        case .null:
            var c = encoder.singleValueContainer(); try c.encodeNil()
        case .bool(let b):
            var c = encoder.singleValueContainer(); try c.encode(b)
        case .number(let n):
            var c = encoder.singleValueContainer(); try c.encode(n)
        case .string(let s):
            var c = encoder.singleValueContainer(); try c.encode(s)
        }
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
