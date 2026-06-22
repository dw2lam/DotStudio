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

enum SourceKind: String, Codable, CaseIterable { case gradient, image, video }

struct SourceSpec: Codable, Equatable, Hashable {
    var kind: SourceKind = .gradient
    var mediaFilename: String?            // file inside the shared media/ folder
    var colorA: RGBA = .navy              // gradient start
    var colorB: RGBA = .cyan              // gradient end
    var gradientAngle: Double = 1.1
    var gradientDrift: Double = 1.0
    var fillMode: Int = 1                 // 0 fit, 1 cover, 2 stretch
}

struct EffectInstance: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var kind: EffectKind
    var enabled: Bool = true
    var params: [String: Double] = [:]
    var colorA: RGBA?                     // overrides palette default when set
    var colorB: RGBA?

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
}

/// The whole on-disk library: one shared source + the saved styles.
struct Library: Codable, Equatable {
    var presets: [Preset] = []
    var source: SourceSpec = SourceSpec()
    var activeID: UUID?
    var version: Int = 2
    var locationLat: Double?     // resolved device location (for the Universe marker)
    var locationLon: Double?
}
