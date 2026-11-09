//  StyleFilter.swift — tags, chips and search for the gallery.
//
//  Tags are derived, never stored: from the style's lead effect (its first enabled
//  effect), the scene pack that effect belongs to, and the categories of its effects.

import Foundation

enum StyleTag: String, CaseIterable, Identifiable, Hashable {
    case clocks, nature, flowing, retro, space, abstract, music

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clocks: return "Clocks"
        case .nature: return "Nature"
        case .flowing: return "Flowing"
        case .retro: return "Retro"
        case .space: return "Space"
        case .abstract: return "Abstract"
        case .music: return "Music"
        }
    }

    var symbol: String {
        switch self {
        case .clocks: return "clock"
        case .nature: return "leaf"
        case .flowing: return "water.waves"
        case .retro: return "tv"
        case .space: return "moon.stars"
        case .abstract: return "scribble.variable"
        case .music: return "music.note"
        }
    }

    /// Lead-effect kinds that belong to a tag beyond their scene pack.
    private static let spaceKinds: Set<EffectKind> = [.universe, .blackhole, .starfield, .nightSky]
    private static let abstractKinds: Set<EffectKind> = [.liquidChrome, .meshGradient, .topography, .silk,
                                                    .flowLines, .lavaLamp, .inkFluid, .polyTrails]
    private static let natureKinds: Set<EffectKind> = [.aurora]

    static func tags(for preset: Preset) -> Set<StyleTag> {
        guard let kind = preset.leadKind else { return [] }
        var tags: Set<StyleTag> = []
        if SceneCatalog.clocks[kind] != nil { tags.insert(.clocks) }
        if SceneCatalog.nature[kind] != nil || natureKinds.contains(kind) { tags.insert(.nature) }
        if SceneCatalog.flowing[kind] != nil { tags.insert(.flowing) }
        if SceneCatalog.retro[kind] != nil { tags.insert(.retro) }
        if spaceKinds.contains(kind) { tags.insert(.space) }
        if abstractKinds.contains(kind) { tags.insert(.abstract) }
        // Now Playing styles (they show what Spotify / Music is playing).
        if kind == .nowPlaying || preset.isMusicScene { tags.insert(.music) }
        // Looks: a CRT/console/tape effect anywhere in the stack makes it Retro.
        if !preset.isScene,
           preset.effects.contains(where: { $0.enabled && $0.kind.category == .retro }) {
            tags.insert(.retro)
        }
        return tags
    }
}

enum GalleryFilter: Hashable, Identifiable {
    case all, playing, scenes, looks
    case tag(StyleTag)

    static var chips: [GalleryFilter] {
        [.all, .playing, .scenes, .looks] + StyleTag.allCases.map(GalleryFilter.tag)
    }

    var id: String {
        switch self {
        case .all: return "all"
        case .playing: return "playing"
        case .scenes: return "scenes"
        case .looks: return "looks"
        case .tag(let t): return t.rawValue
        }
    }

    var title: String {
        switch self {
        case .all: return "All"
        case .playing: return "Playing"
        case .scenes: return "Scenes"
        case .looks: return "Looks"
        case .tag(let t): return t.title
        }
    }

    var symbol: String? {
        switch self {
        case .all: return nil
        case .playing: return "play.fill"
        case .scenes: return "sparkles"
        case .looks: return "camera.filters"
        case .tag(let t): return t.symbol
        }
    }

    /// Chips that would show nothing are hidden, except the fixed ones.
    var alwaysShown: Bool {
        switch self {
        case .all, .playing, .scenes, .looks: return true
        case .tag: return false
        }
    }

    init?(demoName: String) {
        guard let f = GalleryFilter.chips.first(where: { $0.id == demoName.lowercased() }) else { return nil }
        self = f
    }
}

/// Everything the gallery needs to decide whether a tile shows.
struct StyleMatcher {
    let filter: GalleryFilter
    let query: String
    /// Styles on a destination (screensaver playlist, night pick, wallpaper).
    let playing: Set<UUID>

    private var terms: [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    var isFiltering: Bool { filter != .all || !terms.isEmpty }

    func matches(_ p: Preset) -> Bool {
        passesFilter(p) && matchesQuery(p)
    }

    func passesFilter(_ p: Preset) -> Bool {
        switch filter {
        case .all: return true
        case .playing: return playing.contains(p.id)
        case .scenes: return p.isScene
        case .looks: return !p.isScene
        case .tag(let t): return StyleTag.tags(for: p).contains(t)
        }
    }

    /// Every word must appear in the name, kind, pack, tags or effect names.
    func matchesQuery(_ p: Preset) -> Bool {
        let words = terms
        guard !words.isEmpty else { return true }
        let haystack = StyleMatcher.searchText(for: p)
        return words.allSatisfy { haystack.contains($0) }
    }

    static func searchText(for p: Preset) -> String {
        var parts = [p.name, p.isScene ? "scene" : "look"]
        parts += StyleTag.tags(for: p).map(\.title)
        for e in p.effects where e.enabled {
            parts.append(e.kind.displayName)
            parts.append(e.kind.category.rawValue)
        }
        return parts.joined(separator: " ").lowercased()
    }
}
