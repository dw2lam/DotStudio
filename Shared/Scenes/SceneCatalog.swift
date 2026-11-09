//  SceneCatalog.swift — metadata for the scene packs (Clocks, Flowing, Nature, Retro, Music).
//
//  Each pack owns three files and nothing else:
//    Shared/Scenes/<Pack>.swift       — `extension SceneCatalog { static let <pack>: [EffectKind: SceneSpec]`
//                                        and `static var <pack>Presets: [Preset] }`
//    Shared/Scenes/<Pack>_funcs.h     — file-scope Metal helpers (included above fx_fragment)
//    Shared/Scenes/<Pack>_cases.h     — `case NN: { … }` blocks (included inside fx_fragment's switch,
//                                        so they see uv, res, px, t, u, src, glyphs, samp, base, L…)
//  EffectKind's switches fall back to this catalog for any case not handled inline.
//  Params are packed in order into p0.xyzw, p1.xyzw, p2.xyzw (max 12).

import Foundation

struct SceneSpec {
    let name: String
    let blurb: String
    let shaderID: Int32
    let params: [ParamSpec]
    var colorA: RGBA? = nil
    var colorB: RGBA? = nil
    var colorALabel = "Background"
    var colorBLabel = "Foreground"
}

enum SceneCatalog {
    static let all: [EffectKind: SceneSpec] = clocks
        .merging(flowing) { a, _ in a }
        .merging(nature) { a, _ in a }
        .merging(retro) { a, _ in a }
        .merging(music) { a, _ in a }

    static func spec(_ kind: EffectKind) -> SceneSpec? { all[kind] }

    /// Default-library presets contributed by the packs, in pack order.
    static var presets: [Preset] { clocksPresets + flowingPresets + naturePresets + retroPresets + musicPresets }
}
