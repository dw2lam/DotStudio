//  Flowing.swift — the Flowing scene pack (shader ids 54–57). See SceneCatalog.swift.

import Foundation

extension SceneCatalog {
    /// One SceneSpec per EffectKind case on the "Flowing" line of EffectKind. A case that
    /// isn't listed here isn't a Scene and never appears in the app.
    static let flowing: [EffectKind: SceneSpec] = [:]
    //  .flowLines: SceneSpec(name: "…", blurb: "…", shaderID: 54, params: [...]),
    //  .lavaLamp: SceneSpec(name: "…", blurb: "…", shaderID: 55, params: [...]),
    //  .inkFluid: SceneSpec(name: "…", blurb: "…", shaderID: 56, params: [...]),
    //  .fireflies: SceneSpec(name: "…", blurb: "…", shaderID: 57, params: [...]),

    /// Styles this pack adds to the default library.
    static var flowingPresets: [Preset] { [] }
}
