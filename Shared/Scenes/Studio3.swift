//  Studio3.swift — new-scene slot 3 (shader id 69). Empty until a builder fills it; an
//  unused slot is removed before release. See SceneCatalog.swift for how packs work.

import Foundation

extension SceneCatalog {
    /// SceneSpec for the slot's EffectKind case (`studio3` — rename it on its own line in
    /// Effects.swift). Empty ⇒ the case isn't a Scene and never appears in the app.
    static let studio3: [EffectKind: SceneSpec] = [:]

    /// Styles this scene adds to the default library.
    static var studio3Presets: [Preset] { [] }
}
