//  Retro.swift — the Retro scene pack (shader ids 62–65). See SceneCatalog.swift.

import Foundation

extension SceneCatalog {
    /// One SceneSpec per EffectKind case on the "Retro" line of EffectKind. A case that
    /// isn't listed here isn't a Scene and never appears in the app.
    static let retro: [EffectKind: SceneSpec] = [:]
    //  .synthGrid: SceneSpec(name: "…", blurb: "…", shaderID: 62, params: [...]),
    //  .pipes: SceneSpec(name: "…", blurb: "…", shaderID: 63, params: [...]),
    //  .polyTrails: SceneSpec(name: "…", blurb: "…", shaderID: 64, params: [...]),
    //  .demoTunnel: SceneSpec(name: "…", blurb: "…", shaderID: 65, params: [...]),

    /// Styles this pack adds to the default library.
    static var retroPresets: [Preset] { [] }
}
