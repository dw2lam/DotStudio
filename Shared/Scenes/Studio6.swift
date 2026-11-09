//  Studio6.swift — new-scene slot 6 (shader id 72). Empty until a builder fills it; an
//  unused slot is removed before release. See SceneCatalog.swift for how packs work.

import Foundation

extension SceneCatalog {
    /// SceneSpec for the slot's EffectKind case (`studio6` — rename it on its own line in
    /// Effects.swift). Empty ⇒ the case isn't a Scene and never appears in the app.
    static let studio6: [EffectKind: SceneSpec] = [:]

    /// Styles this scene adds to the default library.
    static var studio6Presets: [Preset] { [] }
}
