//  Studio4.swift — new-scene slot 4 (shader id 70). Empty until a builder fills it; an
//  unused slot is removed before release. See SceneCatalog.swift for how packs work.

import Foundation

extension SceneCatalog {
    /// SceneSpec for the slot's EffectKind case (`studio4` — rename it on its own line in
    /// Effects.swift). Empty ⇒ the case isn't a Scene and never appears in the app.
    static let studio4: [EffectKind: SceneSpec] = [:]

    /// Styles this scene adds to the default library.
    static var studio4Presets: [Preset] { [] }
}
