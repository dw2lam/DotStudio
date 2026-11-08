//  Nature.swift — the Nature scene pack (shader ids 58–61). See SceneCatalog.swift.

import Foundation

extension SceneCatalog {
    /// One SceneSpec per EffectKind case on the "Nature" line of EffectKind. A case that
    /// isn't listed here isn't a Scene and never appears in the app.
    static let nature: [EffectKind: SceneSpec] = [:]
    //  .rainGlass: SceneSpec(name: "…", blurb: "…", shaderID: 58, params: [...]),
    //  .oceanHorizon: SceneSpec(name: "…", blurb: "…", shaderID: 59, params: [...]),
    //  .nightSky: SceneSpec(name: "…", blurb: "…", shaderID: 60, params: [...]),
    //  .snowfall: SceneSpec(name: "…", blurb: "…", shaderID: 61, params: [...]),

    /// Styles this pack adds to the default library.
    static var naturePresets: [Preset] { [] }
}
