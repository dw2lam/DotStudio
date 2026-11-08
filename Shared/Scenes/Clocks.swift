//  Clocks.swift — the Clocks scene pack (shader ids 50–53). See SceneCatalog.swift.

import Foundation

extension SceneCatalog {
    /// One SceneSpec per EffectKind case on the "Clocks" line of EffectKind. A case that
    /// isn't listed here isn't a Scene and never appears in the app.
    static let clocks: [EffectKind: SceneSpec] = [:]
    //  .typeClock: SceneSpec(name: "…", blurb: "…", shaderID: 50, params: [...]),
    //  .flipClock: SceneSpec(name: "…", blurb: "…", shaderID: 51, params: [...]),
    //  .wordClock: SceneSpec(name: "…", blurb: "…", shaderID: 52, params: [...]),
    //  .dateGlow: SceneSpec(name: "…", blurb: "…", shaderID: 53, params: [...]),

    /// Styles this pack adds to the default library.
    static var clocksPresets: [Preset] { [] }
}
