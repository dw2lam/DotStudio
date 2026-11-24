//  AppSettings.swift — DotStudio's own settings, for assistants (dotstudio-mcp's get_settings /
//  update_settings): one catalog of every option a user can change in the app — Settings
//  (General, Music, Weather, Screensaver, Live Wallpaper, Transitions, Performance, Updates),
//  the Screensaver card's Playlist menu, the Inspector's Source — plus the read-only state macOS
//  owns (is the screensaver installed and chosen, idle time, login item, text size), with where
//  each lives, its type and allowed values, and a line on what it means.
//
//  Compiled into the app and dotstudio-mcp. The two apply a patch differently:
//    • the app (AIBridgeHost) through its live controllers, so the UI updates at once;
//    • dotstudio-mcp, while the app isn't running, on the files (`apply(_:to:)` here):
//      library.json, wallpaper.json (loose JSON, so fields this build doesn't know survive),
//      and the app's preferences (AppPrefs: the app's defaults domain, or <store>/app-prefs.json
//      under DOTSTUDIO_STORE_DIR — see dotstudio-mcp's PrefsStore).
//  Validation (`validate`) is shared, so both refuse the same things with the same words.

import Foundation
import UniformTypeIdentifiers

/// A setting's type, as assistants see it.
enum SettingType: Equatable {
    case bool
    /// One of these strings.
    case choice([String])
    /// A number in min…max.
    case number(min: Double, max: Double)
    /// One of these numbers (a menu in the app).
    case numberChoice([Double])
    /// {"r","g","b","a"?} display sRGB 0…1.
    case color
    /// A style id (dotstudio-mcp resolves names first).
    case style
    /// source.photos: "builtIn", or absolute paths of images to copy into the library.
    case photos
    /// source.mediaFile: an absolute path of an image or a video to copy into the library.
    case mediaFile
    /// weather.location: "auto", or {"name"?, "lat", "lon"} (the user's own place).
    case location
    /// Shown, never set (macOS owns it, or only the user may change it).
    case readOnly
}

/// Where a setting is kept.
enum SettingStore: String {
    case library      // library.json
    case wallpaper    // wallpaper.json
    case prefs        // the app's preferences (AppPrefs keys below)
    case app          // the running app only (the login item)
    case ai           // ai-settings.json (the user's own permission: read-only)
    case system       // macOS (read-only)
}

struct SettingDef {
    let key: String
    let label: String
    /// Where the user finds it in DotStudio.
    let place: String
    let meaning: String
    let type: SettingType
    var store: SettingStore
    /// Changes what plays on screen: refused while “Let AI change what plays” is off.
    var gated = false
    /// Read-only: how the user changes it.
    var howToChange: String? = nil
    /// The AppPrefs key (store == .prefs) and its default.
    var prefKey: String? = nil
    var prefDefault = true

    var group: String { String(key.split(separator: ".").first ?? "") }
    var readOnly: Bool { type == .readOnly }
    /// Settable only while DotStudio runs (it registers its own login item).
    var needsApp: Bool { store == .app }

    /// The allowed values in words, for get_settings.
    var allowedJSON: JSONValue {
        switch type {
        case .bool: return .string("true | false")
        case .choice(let c): return .array(c.map { .string($0) })
        case .number(let lo, let hi): return .string("\(AppSettings.fmt(lo))…\(AppSettings.fmt(hi))")
        case .numberChoice(let n): return .array(n.map { .number($0) })
        case .color: return .string("{r, g, b, a?} each 0…1")
        case .style: return .string("a style id or exact name (list_styles)")
        case .photos: return .string("\"builtIn\", or an array of absolute paths to image files (copied into the library)")
        case .mediaFile: return .string("an absolute path to an image or video file (copied into the library)")
        case .location: return .string("\"auto\", or {\"name\"?: text, \"lat\": -90…90, \"lon\": -180…180}")
        case .readOnly: return .null
        }
    }
}

enum AppSettings {
    static let groups: [(id: String, title: String)] = [
        ("general", "General"),
        ("screensaver", "Screensaver (Playlist, Transitions, Performance)"),
        ("music", "Music"),
        ("weather", "Weather"),
        ("wallpaper", "Live Wallpaper"),
        ("source", "Source (what Looks restyle)"),
        ("updates", "Updates"),
        ("ai", "AI (the user's own permissions)"),
        ("system", "macOS (read-only)"),
    ]

    /// Every setting, in the app's order.
    static let all: [SettingDef] = [
        // General
        SettingDef(key: "general.menuBarMode", label: "Keep running in the menu bar", place: "Settings ▸ General (also Settings ▸ Music)",
                   meaning: "On: closing the window keeps DotStudio in the menu bar, so the live wallpaper and the music card keep going. Off: closing the window quits (unless a live wallpaper plays).",
                   type: .bool, store: .prefs, prefKey: "menuBarMode"),
        SettingDef(key: "general.openAtLogin", label: "Open DotStudio at login", place: "Settings ▸ General",
                   meaning: "DotStudio's own login item: at login it starts quietly in the menu bar (menu-bar mode) or opens its window. Needed for a live wallpaper that's always there.",
                   type: .bool, store: .app),

        // Screensaver: the Playlist menu, Transitions, Performance
        SettingDef(key: "screensaver.changeEveryMinutes", label: "Playlist ▸ Change Every", place: "Main window ▸ Screensaver card ▸ Playlist",
                   meaning: "How often a playlist of 2+ styles moves to the next style, in minutes (stored even with one style, for when there are more).",
                   type: .numberChoice([1, 5, 15, 30, 60]), store: .library, gated: true),
        SettingDef(key: "screensaver.shuffle", label: "Playlist ▸ Shuffle", place: "Main window ▸ Screensaver card ▸ Playlist",
                   meaning: "Play the playlist in a seeded shuffle (every display agrees; nothing repeats until all have shown) instead of in order.",
                   type: .bool, store: .library, gated: true),
        SettingDef(key: "screensaver.crossfadeSeconds", label: "Crossfade", place: "Settings ▸ Transitions",
                   meaning: "Seconds to blend between styles as the playlist changes and at sunrise/sunset; below 0.05 is Off.",
                   type: .number(min: 0, max: 3), store: .library),
        SettingDef(key: "power.frameRate", label: "Frame rate", place: "Settings ▸ Power Saving",
                   meaning: "One frame rate for the screensaver and the live wallpaper: 15, 24, 30, 60 or 120 fps; style = each style's own rate. Battery, Low Power Mode and Slow Down still cap it lower.",
                   type: .choice(["style", "15", "24", "30", "60", "120"]), store: .library),
        SettingDef(key: "screensaver.quality", label: "Quality", place: "Settings ▸ Screensaver Performance",
                   meaning: "The screensaver's render resolution: full (native Retina), balanced (0.75×), efficient (0.5×) — less GPU memory and battery, same look. On battery it also caps its frame rate by itself.",
                   type: .choice(["full", "balanced", "efficient"]), store: .library),
        SettingDef(key: "screensaver.playlist", label: "Playlist", place: "Main window ▸ Screensaver card",
                   meaning: "The styles the screensaver plays by day (one = just that style; several rotate).",
                   type: .readOnly, store: .library, howToChange: "set_screensaver (mode only / add / remove)"),
        SettingDef(key: "screensaver.night", label: "Night", place: "Main window ▸ Screensaver card",
                   meaning: "A different style after sunset, or none.",
                   type: .readOnly, store: .library, howToChange: "set_screensaver (mode night / dayOnly)"),
        SettingDef(key: "screensaver.perDisplay", label: "Displays", place: "Main window ▸ Screensaver card ▸ Displays",
                   meaning: "Displays that play a style of their own instead of the lineup (display key → style).",
                   type: .readOnly, store: .library, howToChange: "set_screensaver with `display` (list_displays for keys); mode unpin to undo"),

        // Music
        SettingDef(key: "music.show", label: "Show music", place: "Settings ▸ Music (and the Screensaver card's Music menu)",
                   meaning: "While Spotify or Apple Music plays: off, the song in a corner of the screensaver, or full screen over it.",
                   type: .choice(["off", "corner", "fullScreen"]), store: .library, gated: true),
        SettingDef(key: "music.corner", label: "Corner", place: "Settings ▸ Music (Corner)",
                   meaning: "Which corner the music card sits in.",
                   type: .choice(["bottomLeft", "bottomRight", "topLeft", "topRight"]), store: .library),
        SettingDef(key: "music.size", label: "Size", place: "Settings ▸ Music (Corner)",
                   meaning: "The corner card's size (even Small reads from across a room).",
                   type: .choice(["small", "medium", "large"]), store: .library),
        SettingDef(key: "music.layout", label: "Layout", place: "Settings ▸ Music (Full Screen)",
                   meaning: "Full Screen's arrangement: album (art left, type right), stage (art centred, type below), cover (the artwork fills the screen).",
                   type: .choice(["album", "stage", "cover"]), store: .library),
        SettingDef(key: "music.behind", label: "Behind the music", place: "Settings ▸ Music (Full Screen)",
                   meaning: "What Full Screen draws behind the song: the artwork's living colour fields (albumArt) or your screensaver, blurred and dimmed. Ignored by the cover layout.",
                   type: .choice(["albumArt", "screensaver"]), store: .library),
        SettingDef(key: "music.onWallpaper", label: "Also on the live wallpaper", place: "Settings ▸ Music",
                   meaning: "Show the music on the live wallpaper too (only while Show music isn't off).",
                   type: .bool, store: .library, gated: true),
        SettingDef(key: "music.keepPausedSongMinutes", label: "Keep a paused song for", place: "Settings ▸ Music",
                   meaning: "Minutes a paused song stays on screen before it fades back to the plain style.",
                   type: .numberChoice([1, 5, 15]), store: .library),
        SettingDef(key: "music.source", label: "Source", place: "Settings ▸ Music",
                   meaning: "Which player to follow: auto (whichever plays), spotify, or music (Apple Music).",
                   type: .choice(["auto", "spotify", "music"]), store: .library),

        // Weather
        SettingDef(key: "weather.live", label: "Live weather", place: "Settings ▸ Weather",
                   meaning: "Ocean Horizon, Shallows and Meadow styles with Weather set to Live show the real sky outside (Open-Meteo, at weather.location, every 20 minutes). Off: they stay clear.",
                   type: .bool, store: .prefs, prefKey: "weatherEnabled"),
        SettingDef(key: "weather.location", label: "Location", place: "Settings ▸ Weather ▸ Location",
                   meaning: "Where DotStudio places this Mac: the live weather, the real sun, moon and stars (Follow the Sun), the night style's sunset, Universe's marker and signals that ask for {lat}/{lon}. \"auto\" = approximate, from the internet connection (IP; a VPN can put it in the wrong city); or the user's own place {name?, lat, lon} — then nothing is looked up. Read back as {mode, name, lat, lon}, coordinates rounded to 0.1° (about 10 km). It's the user's location: set it only when they asked.",
                   type: .location, store: .library),
        SettingDef(key: "weather.inUse", label: "Weather in use", place: "—",
                   meaning: "Whether anything reads the live weather now: a style whose Weather menu is Live (Ocean Horizon, Shallows, Meadow), a film scene that follows the weather with its Weather left on Live, or a When rule / scene input on a weather.* signal. DotStudio fetches the weather only while this is true and weather.live is on; a style pinned to a condition never needs it.",
                   type: .readOnly, store: .library,
                   howToChange: "Follows the library: set a style's Weather to Live (update_style), or test weather.* in a When rule (set_rule)."),

        // Live wallpaper
        SettingDef(key: "wallpaper.on", label: "Use a style as your desktop wallpaper", place: "Settings ▸ Live Wallpaper (and the Wallpaper card)",
                   meaning: "DotStudio draws a style behind the desktop icons while it runs. Turning it on plays the last wallpaper style (or the screensaver's).",
                   type: .bool, store: .wallpaper, gated: true),
        SettingDef(key: "wallpaper.sameAsScreensaver", label: "Same as Screensaver", place: "Settings ▸ Live Wallpaper",
                   meaning: "The wallpaper plays exactly what the screensaver shows (playlist, night style, per display), in step. Turning it on also turns the wallpaper on.",
                   type: .bool, store: .wallpaper, gated: true),
        SettingDef(key: "wallpaper.style", label: "Style", place: "Settings ▸ Live Wallpaper",
                   meaning: "The wallpaper's own style (when not Same as Screensaver). Picking one while the wallpaper is off only remembers it. (set_wallpaper does more: per display, turning it on.)",
                   type: .style, store: .wallpaper, gated: true),
        SettingDef(key: "wallpaper.frameRate", label: "Frame Rate", place: "Settings ▸ Live Wallpaper",
                   meaning: "balanced = 30 fps; smooth = the display's own refresh (120 on ProMotion) — more battery.",
                   type: .choice(["balanced", "smooth"]), store: .wallpaper),
        SettingDef(key: "wallpaper.quality", label: "Quality", place: "Settings ▸ Live Wallpaper",
                   meaning: "Render resolution: full (native), balanced (1.5 px per point), efficient (1 px per point).",
                   type: .choice(["full", "balanced", "efficient"]), store: .wallpaper),
        SettingDef(key: "wallpaper.onBattery", label: "On Battery", place: "Settings ▸ Live Wallpaper",
                   meaning: "Unplugged: efficient (20 fps, lower resolution), full (as on power, at most 30 fps), or still (pause: hold a frame).",
                   type: .choice(["efficient", "full", "still"]), store: .wallpaper),
        SettingDef(key: "wallpaper.otherAppPluggedIn", label: "Another App Focused (plugged in)", place: "Settings ▸ When Plugged In",
                   meaning: "Plugged in, while an app other than DotStudio or the Finder is in front (not full screen — a covered desktop always pauses): keepPlaying, efficient (slow down: 20 fps, lower resolution), or pause (hold the frame until the desktop or DotStudio is focused again).",
                   type: .choice(["keepPlaying", "efficient", "pause"]), store: .wallpaper),
        SettingDef(key: "wallpaper.otherAppOnBattery", label: "Another App Focused (on battery)", place: "Settings ▸ On Battery",
                   meaning: "On battery, while an app other than DotStudio or the Finder is in front: keepPlaying, efficient (slow down: 20 fps, lower resolution), or pause (hold the frame).",
                   type: .choice(["keepPlaying", "efficient", "pause"]), store: .wallpaper),
        SettingDef(key: "wallpaper.fpsModePluggedIn", label: "Frame Rate Mode (plugged in)", place: "Settings ▸ Power Saving ▸ When Plugged In",
                   meaning: "Plugged in: forced (always the set frame rate), dynamic (steps down the divisor ladder 120 → 60 → 40 while the Mac's CPU or GPU is busy, back up when it settles), or reactive (one step down while the user types, clicks or scrolls in another app, back a few seconds after they stop).",
                   type: .choice(["forced", "dynamic", "reactive"]), store: .wallpaper),
        SettingDef(key: "wallpaper.fpsModeOnBattery", label: "Frame Rate Mode (on battery)", place: "Settings ▸ Power Saving ▸ On Battery",
                   meaning: "On battery: forced, dynamic or reactive, as for plugged in — stepping down from the battery's own cap (30, or 20 when Efficient).",
                   type: .choice(["forced", "dynamic", "reactive"]), store: .wallpaper),
        SettingDef(key: "wallpaper.lockScreenPicture", label: "Use as lock & login screen picture", place: "Settings ▸ Live Wallpaper",
                   meaning: "A still of the wallpaper becomes the desktop picture macOS shows on the lock and login screens; off puts the user's own picture back.",
                   type: .bool, store: .wallpaper, gated: true),
        SettingDef(key: "wallpaper.perDisplay", label: "Displays", place: "Main window ▸ Wallpaper card ▸ Displays",
                   meaning: "Displays whose wallpaper is a style of their own (display key → style).",
                   type: .readOnly, store: .wallpaper, howToChange: "set_wallpaper with `display` (list_displays for keys); mode unpin to undo"),

        // Source
        SettingDef(key: "source.kind", label: "Source", place: "Inspector ▸ Source (any Look)",
                   meaning: "What every Look restyles: collection (a photo slideshow: built-in or the user's photos), gradient, image or video. Changing it changes every Look; scenes ignore it.",
                   type: .choice(["collection", "gradient", "image", "video"]), store: .library),
        SettingDef(key: "source.photos", label: "Use Your Own Photos… / Use Built-in Photos", place: "Inspector ▸ Source ▸ Slideshow",
                   meaning: "The slideshow's photos: \"builtIn\" (the curated set) or the user's own images (copied into DotStudio's media folder). Sets the source to collection.",
                   type: .photos, store: .library),
        SettingDef(key: "source.mediaFile", label: "Image / Video", place: "Inspector ▸ Source ▸ Image or Video",
                   meaning: "One image or video file to restyle (copied into DotStudio's media folder); sets the source to image or video.",
                   type: .mediaFile, store: .library),
        SettingDef(key: "source.secondsEach", label: "Seconds Each", place: "Inspector ▸ Source ▸ Slideshow",
                   meaning: "Seconds each slideshow photo holds before cross-fading to the next.",
                   type: .number(min: 6, max: 120), store: .library),
        SettingDef(key: "source.panAndZoom", label: "Pan & Zoom", place: "Inspector ▸ Source ▸ Slideshow",
                   meaning: "Ken Burns pan/zoom strength, 0 (still) to 1.",
                   type: .number(min: 0, max: 1), store: .library),
        SettingDef(key: "source.gradientFrom", label: "From", place: "Inspector ▸ Source ▸ Gradient",
                   meaning: "The gradient's first colour.", type: .color, store: .library),
        SettingDef(key: "source.gradientTo", label: "To", place: "Inspector ▸ Source ▸ Gradient",
                   meaning: "The gradient's second colour.", type: .color, store: .library),
        SettingDef(key: "source.gradientAngle", label: "Angle", place: "Inspector ▸ Source ▸ Gradient",
                   meaning: "The gradient's angle in radians.", type: .number(min: 0, max: 6.28), store: .library),
        SettingDef(key: "source.gradientDrift", label: "Drift", place: "Inspector ▸ Source ▸ Gradient",
                   meaning: "How much the gradient slowly drifts.", type: .number(min: 0, max: 3), store: .library),
        SettingDef(key: "source.scaling", label: "Scaling", place: "Inspector ▸ Source ▸ Image or Video",
                   meaning: "How an image or video fits the screen: fill (crop to cover), fit (letterbox) or stretch.",
                   type: .choice(["fill", "fit", "stretch"]), store: .library),

        // Updates
        SettingDef(key: "updates.checkAutomatically", label: "Check for updates automatically", place: "Settings ▸ Updates",
                   meaning: "Look for new DotStudio versions (GitHub releases) about every hour.",
                   type: .bool, store: .prefs, prefKey: "SUEnableAutomaticChecks"),
        SettingDef(key: "updates.installAutomatically", label: "Download and install updates automatically", place: "Settings ▸ Updates",
                   meaning: "Download new versions in the background and install them when DotStudio quits (needs checkAutomatically on).",
                   type: .bool, store: .prefs, prefKey: "SUAutomaticallyUpdate"),

        // AI: the user's own permissions
        SettingDef(key: "ai.allowPlaybackChanges", label: "Let AI change what plays", place: "Settings ▸ AI",
                   meaning: "Whether assistants may change the screensaver, wallpaper and other settings marked changesWhatPlays. Styles can always be created and edited.",
                   type: .readOnly, store: .ai, howToChange: "Only the user can change this, in DotStudio ▸ Settings ▸ AI. Never ask a tool to."),
        SettingDef(key: "ai.allowSignals", label: "Let AI add live data signals", place: "Settings ▸ AI",
                   meaning: "Whether assistants may add, change and delete signals (live values When rules react to). They never see or set a signal's key either way.",
                   type: .readOnly, store: .ai, howToChange: "Only the user can change this, in DotStudio ▸ Settings ▸ AI. Never ask a tool to."),
        SettingDef(key: "ai.showNotices", label: "Notices", place: "—",
                   meaning: "Each change an assistant makes shows a small notice in the app, with Undo.",
                   type: .readOnly, store: .ai, howToChange: "Only the user decides this (ai-settings.json)."),

        // macOS
        SettingDef(key: "system.screensaverInstalled", label: "Screensaver installed", place: "Settings ▸ Screensaver ▸ Status",
                   meaning: "DotStudio.saver is in ~/Library/Screen Savers.",
                   type: .readOnly, store: .system, howToChange: "app_action install_screensaver (Settings ▸ Screensaver ▸ Install / Reinstall)."),
        SettingDef(key: "system.screensaverChosen", label: "Chosen in System Settings", place: "System Settings ▸ Wallpaper ▸ Screen Saver…",
                   meaning: "Whether macOS shows DotStudio as the screensaver, on how many of the connected displays.",
                   type: .readOnly, store: .system, howToChange: "macOS owns this: the user picks DotStudio in System Settings ▸ Wallpaper ▸ Screen Saver…. app_action open_screensaver_settings opens it; show_setup_guide / guide_me walk them through it."),
        SettingDef(key: "system.startScreenSaverAfter", label: "Start Screen Saver when inactive", place: "System Settings ▸ Lock Screen",
                   meaning: "Minutes of inactivity before macOS starts the screensaver (0 = never; macOS's default is 20).",
                   type: .readOnly, store: .system, howToChange: "macOS owns this: System Settings ▸ Lock Screen (app_action open_lock_screen_settings)."),
        SettingDef(key: "system.displayOffMinutes", label: "Turn display off when inactive", place: "System Settings ▸ Lock Screen",
                   meaning: "Minutes before the display sleeps, per power source; if it's not longer than the screensaver's start time the screensaver never shows.",
                   type: .readOnly, store: .system, howToChange: "macOS owns this: System Settings ▸ Lock Screen (app_action open_lock_screen_settings)."),
        SettingDef(key: "system.loginItemApproval", label: "Login item", place: "System Settings ▸ General ▸ Login Items",
                   meaning: "enabled, off, or requiresApproval (macOS is waiting for the user to allow DotStudio).",
                   type: .readOnly, store: .system, howToChange: "Turn it on with general.openAtLogin; if it says requiresApproval, the user allows DotStudio in System Settings ▸ General ▸ Login Items (app_action open_login_items_settings)."),
        SettingDef(key: "system.accessibilityForGuideMe", label: "Accessibility (Guide Me)", place: "System Settings ▸ Privacy & Security ▸ Accessibility",
                   meaning: "Whether DotStudio may read System Settings to point at the next click in the setup guide's Guide Me.",
                   type: .readOnly, store: .system, howToChange: "macOS owns this: the user allows it when Guide Me asks (app_action guide_me), or in System Settings ▸ Privacy & Security ▸ Accessibility."),
        SettingDef(key: "system.textSize", label: "Text size", place: "System Settings ▸ Accessibility ▸ Display ▸ Text Size",
                   meaning: "DotStudio has no text-size, density or layout-scale setting of its own: its text and layout (layout.scaled) follow macOS's text size and the window's width.",
                   type: .readOnly, store: .system, howToChange: "macOS owns this: System Settings ▸ Accessibility ▸ Display ▸ Text Size."),
    ]

    static func def(_ key: String) -> SettingDef? { all.first { $0.key == key } }
    static var settable: [SettingDef] { all.filter { !$0.readOnly } }
    static var prefKeys: [(key: String, def: Bool)] { all.compactMap { d in d.prefKey.map { ($0, d.prefDefault) } } }

    static func fmt(_ d: Double) -> String {
        d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(format: "%g", d)
    }

    // MARK: State

    /// Everything the stored settings come from. The app fills it from its live objects;
    /// dotstudio-mcp from the files.
    struct State {
        var library: Library
        /// wallpaper.json as loose JSON (WallpaperSettings' keys).
        var wallpaper: [String: JSONValue]
        /// AppPrefs values (missing = the setting's default).
        var prefs: [String: Bool]
        var ai: AISettings
        /// The store, for what reads Custom Scene packages (weather.inUse); nil = only the
        /// manifests already read.
        var store: URL? = nil
    }

    // MARK: Read

    /// The current value of every stored setting (system / app-only ones are the caller's).
    static func read(_ s: State) -> [String: JSONValue] {
        var o: [String: JSONValue] = [:]
        let lib = s.library
        func name(_ id: UUID) -> JSONValue {
            .object(["id": .string(id.uuidString), "name": .string(lib.presets.first { $0.id == id }?.name ?? "(deleted style)")])
        }
        for (k, def) in prefKeys {
            if let d = all.first(where: { $0.prefKey == k }) { o[d.key] = .bool(s.prefs[k] ?? def) }
        }
        let rot = lib.rotation ?? RotationSpec()
        o["screensaver.changeEveryMinutes"] = .number(rot.intervalMinutes)
        o["screensaver.shuffle"] = .bool(rot.shuffle)
        o["screensaver.crossfadeSeconds"] = .number(rot.transitionSeconds)
        o["screensaver.quality"] = .string(qualityName(lib.renderScale))
        o["power.frameRate"] = .string(lib.frameRate.map(String.init) ?? "style")
        let lineup = lib.screensaverLineup
        o["screensaver.playlist"] = .array(lineup.playlist.map(name))
        o["screensaver.night"] = lineup.night.map(name) ?? .null
        o["screensaver.perDisplay"] = .object((lib.displayStyles ?? [:]).mapValues { pin in
            .object(["display": .string(pin.name ?? "?"), "style": name(pin.presetID)])
        })

        let m = lib.musicSettings
        o["music.show"] = .string(m.displayMode.rawValue)
        o["music.corner"] = .string(m.corner.rawValue)
        o["music.size"] = .string(m.cardSizePreference.rawValue)
        o["music.layout"] = .string(m.layout.rawValue)
        o["music.behind"] = .string(m.backdrop.rawValue)
        o["music.onWallpaper"] = .bool(m.drawsOnWallpaper)
        o["music.keepPausedSongMinutes"] = .number(m.linger)
        o["music.source"] = .string(m.sourcePreference.rawValue)

        o["weather.location"] = location(lib)
        o["weather.inUse"] = .bool(WeatherLink.needed(by: lib, store: s.store))

        let w = s.wallpaper
        let enabled = w["enabled"]?.boolValue ?? false
        let follows = w["followsScreensaver"]?.boolValue ?? false
        o["wallpaper.on"] = .bool(enabled)
        o["wallpaper.sameAsScreensaver"] = .bool(enabled && follows)
        o["wallpaper.style"] = w["presetID"]?.stringValue.flatMap(UUID.init).map(name) ?? .null
        o["wallpaper.frameRate"] = .string((w["frameRate"]?.doubleValue ?? 30) > 30 ? "smooth" : "balanced")
        o["wallpaper.quality"] = .string(["full", "balanced", "efficient"].first { $0 == w["quality"]?.stringValue } ?? "balanced")
        let battery = w["batteryMode"]?.stringValue ?? ((w["freezeOnBattery"]?.boolValue ?? false) ? "still" : "efficient")
        o["wallpaper.onBattery"] = .string(["efficient", "full", "still"].contains(battery) ? battery : "efficient")
        for k in ["otherAppPluggedIn", "otherAppOnBattery"] {
            let v = w[k]?.stringValue ?? ""
            o["wallpaper." + k] = .string(["efficient", "pause"].contains(v) ? v : "keepPlaying")
        }
        for k in ["fpsModePluggedIn", "fpsModeOnBattery"] {
            let v = w[k]?.stringValue ?? ""
            o["wallpaper." + k] = .string(["dynamic", "reactive"].contains(v) ? v : "forced")
        }
        o["wallpaper.lockScreenPicture"] = .bool(w["lockScreen"]?.boolValue ?? false)
        var wpins: [String: JSONValue] = [:]
        if case .object(let pins)? = w["displayStyles"] {
            for (k, v) in pins {
                guard case .object(let p) = v, let id = p["presetID"]?.stringValue.flatMap(UUID.init) else { continue }
                wpins[k] = .object(["display": p["name"] ?? .string("?"), "style": name(id)])
            }
        }
        o["wallpaper.perDisplay"] = .object(wpins)

        let src = lib.source
        o["source.kind"] = .string(src.kind.rawValue)
        o["source.photos"] = (src.mediaFilenames ?? []).isEmpty ? .string("builtIn")
            : .object(["yourPhotos": .integer(Int64(src.mediaFilenames?.count ?? 0))])
        o["source.mediaFile"] = src.mediaFilename.map { .string($0) } ?? .null
        o["source.secondsEach"] = .number(src.slideInterval)
        o["source.panAndZoom"] = .number(src.motionAmount)
        o["source.gradientFrom"] = color(src.colorA)
        o["source.gradientTo"] = color(src.colorB)
        o["source.gradientAngle"] = .number(src.gradientAngle)
        o["source.gradientDrift"] = .number(src.gradientDrift)
        o["source.scaling"] = .string(scalingName(src.fillMode))

        o["ai.allowPlaybackChanges"] = .bool(s.ai.allowPlaybackChanges)
        o["ai.showNotices"] = .bool(s.ai.showNotices)
        o["ai.allowSignals"] = .bool(s.ai.allowSignals)
        o["system.textSize"] = .string("follows macOS")
        return o
    }

    static func qualityName(_ scale: Double?) -> String {
        guard let s = scale, s < 1 else { return "full" }
        if abs(s - 0.75) < 0.01 { return "balanced" }
        if abs(s - 0.5) < 0.01 { return "efficient" }
        return "custom (\(fmt(s)))"
    }

    static func scalingName(_ fill: Int) -> String { fill == 0 ? "fit" : fill == 2 ? "stretch" : "fill" }

    /// ~0.1° (about 10 km) — what WeatherService sends Open-Meteo, and all an assistant is told.
    static func roundedCoordinate(_ d: Double) -> Double { (d * 10).rounded() / 10 }

    /// weather.location as read: {mode, name, lat, lon}, coordinates rounded (null while unknown).
    static func location(_ lib: Library) -> JSONValue {
        func num(_ d: Double?) -> JSONValue { d.map { .number(roundedCoordinate($0)) } ?? .null }
        return .object(["mode": .string(lib.usesManualLocation ? "manual" : "auto"),
                        "name": lib.locationPlaceName.map { .string($0) } ?? .null,
                        "lat": num(lib.locationLat), "lon": num(lib.locationLon)])
    }

    /// The longest place name kept.
    static let maxPlaceName = 80

    static func color(_ c: RGBA) -> JSONValue {
        .object(["r": .number(c.r), "g": .number(c.g), "b": .number(c.b), "a": .number(c.a)])
    }

    // MARK: Validate

    struct Change {
        let def: SettingDef
        /// Normalized: bools, choice strings, numbers, a style id string, colour objects,
        /// "builtIn" or [paths] for photos, a path for mediaFile.
        let value: JSONValue
    }

    /// Check a whole patch; any problem refuses all of it (the message lists every problem).
    static func validate(_ patch: [String: JSONValue], library: Library) -> Result<[Change], SettingsError> {
        var problems: [String] = []
        var out: [Change] = []
        guard !patch.isEmpty else { return .failure(SettingsError("Pass at least one setting, e.g. {\"music.show\": \"corner\"}. get_settings lists them.")) }
        for key in patch.keys.sorted() {
            let v = patch[key]!
            guard let d = def(key) else {
                let near = suggestions(key)
                problems.append("“\(key)” isn't a setting" + (near.isEmpty ? "" : " — did you mean \(near.joined(separator: " or "))?"))
                continue
            }
            if d.readOnly {
                problems.append("\(key) is read-only. \(d.howToChange ?? "")")
                continue
            }
            switch check(d, v, library) {
            case .success(let n): out.append(Change(def: d, value: n))
            case .failure(let e): problems.append("\(key): \(e.message)")
            }
        }
        // The app disables "install automatically" while checks are off.
        let checks = out.first { $0.def.key == "updates.checkAutomatically" }?.value.boolValue
        if out.contains(where: { $0.def.key == "updates.installAutomatically" && $0.value.boolValue == true }), checks == false {
            problems.append("updates.installAutomatically needs updates.checkAutomatically on (the app greys it out while checks are off).")
        }
        if patch["source.photos"] != nil && patch["source.mediaFile"] != nil {
            problems.append("Pass source.photos (a slideshow) or source.mediaFile (one image or video), not both.")
        }
        if !problems.isEmpty {
            return .failure(SettingsError("Nothing was changed:\n- " + problems.joined(separator: "\n- ") + "\nget_settings lists every setting with its allowed values."))
        }
        return .success(out)
    }

    /// Near keys for a typo: same leaf, a close spelling, or the app's label.
    static func suggestions(_ key: String) -> [String] {
        let k = key.lowercased()
        let leaf = k.split(separator: ".").last.map(String.init) ?? k
        let scored: [(String, Int)] = all.compactMap { d in
            let dk = d.key.lowercased()
            let dleaf = dk.split(separator: ".").last.map(String.init) ?? dk
            if dk.hasSuffix("." + leaf) || (leaf.count >= 4 && (dk.contains(leaf) || d.label.lowercased().contains(leaf))) { return (d.key, 0) }
            let dist = min(distance(k, dk), distance(leaf, dleaf) + (k.contains(".") && !dk.hasPrefix(k.split(separator: ".")[0] + ".") ? 2 : 0))
            return dist <= max(2, leaf.count / 3) ? (d.key, dist) : nil
        }
        return Array(scored.sorted { $0.1 < $1.1 }.prefix(3).map(\.0))
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var prev = row[0]
            row[0] = i
            for j in 1...b.count {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return row[b.count]
    }

    private static func check(_ d: SettingDef, _ v: JSONValue, _ lib: Library) -> Result<JSONValue, SettingsError> {
        switch d.type {
        case .bool:
            guard let b = v.boolValue else { return .failure(SettingsError("expected true or false")) }
            return .success(.bool(b))
        case .choice(let c):
            guard let s = v.stringValue, c.contains(s) else {
                return .failure(SettingsError("\(v.display) isn't one of \(c.joined(separator: ", "))"))
            }
            if d.key == "source.kind", s == "image" || s == "video" {
                // The app picks image/video by importing a file; switching back needs that file.
                guard let f = lib.source.mediaFilename, !f.isEmpty else {
                    return .failure(SettingsError("there's no \(s) in the library yet — pass source.mediaFile (an absolute path) instead"))
                }
                if mediaKind(f) != s { return .failure(SettingsError("the library's media file is \(mediaKind(f) ?? "not an image or video") — pass source.mediaFile with a \(s) file")) }
            }
            return .success(.string(s))
        case .number(let lo, let hi):
            guard let n = v.doubleValue, n.isFinite else { return .failure(SettingsError("expected a number \(fmt(lo))…\(fmt(hi))")) }
            guard n >= lo, n <= hi else { return .failure(SettingsError("\(fmt(n)) is outside \(fmt(lo))…\(fmt(hi))")) }
            return .success(.number(n))
        case .numberChoice(let opts):
            guard let n = v.doubleValue, opts.contains(n) else {
                return .failure(SettingsError("\(v.display) isn't one of \(opts.map(fmt).joined(separator: ", ")) (the app's menu)"))
            }
            return .success(.number(n))
        case .color:
            guard case .object(let o) = v, let r = o["r"]?.doubleValue, let g = o["g"]?.doubleValue, let b = o["b"]?.doubleValue else {
                return .failure(SettingsError("expected a colour {\"r\":0…1,\"g\":0…1,\"b\":0…1,\"a\":0…1 (optional)}"))
            }
            let a = o["a"]?.doubleValue ?? 1
            guard [r, g, b, a].allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else {
                return .failure(SettingsError("colour components must be 0…1"))
            }
            return .success(color(RGBA(r, g, b, a)))
        case .style:
            guard let s = v.stringValue, let id = UUID(uuidString: s), lib.presets.contains(where: { $0.id == id }) else {
                return .failure(SettingsError("no such style (pass an id or exact name from list_styles)"))
            }
            return .success(.string(id.uuidString))
        case .photos:
            if v.stringValue == "builtIn" { return .success(.string("builtIn")) }
            guard case .array(let items) = v, !items.isEmpty, items.count <= 200 else {
                return .failure(SettingsError("expected \"builtIn\" or an array of 1–200 absolute image paths"))
            }
            var paths: [JSONValue] = []
            for item in items {
                guard let p = item.stringValue, p.hasPrefix("/") else { return .failure(SettingsError("\(item.display) isn't an absolute path")) }
                guard FileManager.default.isReadableFile(atPath: p) else { return .failure(SettingsError("can't read \(p)")) }
                guard mediaKind(p) == "image" else { return .failure(SettingsError("\(p) isn't an image file")) }
                paths.append(.string(p))
            }
            return .success(.array(paths))
        case .mediaFile:
            guard let p = v.stringValue, p.hasPrefix("/") else { return .failure(SettingsError("expected an absolute path")) }
            guard FileManager.default.isReadableFile(atPath: p) else { return .failure(SettingsError("can't read \(p)")) }
            guard mediaKind(p) != nil else { return .failure(SettingsError("\(p) isn't an image or a video file")) }
            return .success(.string(p))
        case .location:
            let usage = "expected \"auto\" or {\"name\": \"Toronto, Ontario\" (optional), \"lat\": -90…90, \"lon\": -180…180}"
            if v.stringValue == "auto" { return .success(.string("auto")) }
            guard case .object(let o) = v, let lat = o["lat"]?.doubleValue, let lon = o["lon"]?.doubleValue else {
                return .failure(SettingsError(usage))
            }
            let extra = o.keys.filter { !["name", "lat", "lon"].contains($0) }.sorted()
            guard extra.isEmpty else { return .failure(SettingsError("unknown field(s) \(extra.joined(separator: ", ")) — \(usage)")) }
            guard lat.isFinite, lon.isFinite else { return .failure(SettingsError("lat and lon must be finite numbers")) }
            guard abs(lat) <= 90 else { return .failure(SettingsError("lat \(fmt(lat)) is outside -90…90")) }
            guard abs(lon) <= 180 else { return .failure(SettingsError("lon \(fmt(lon)) is outside -180…180")) }
            var name = ""
            if let n = o["name"], n != .null {
                guard let s = n.stringValue else { return .failure(SettingsError("name must be text")) }
                name = s.trimmingCharacters(in: .whitespacesAndNewlines)
                guard name.count <= maxPlaceName else { return .failure(SettingsError("name is longer than \(maxPlaceName) characters")) }
            }
            if name.isEmpty { name = NamedPlace.coordinateName(lat, lon) }
            return .success(.object(["name": .string(name), "lat": .number(lat), "lon": .number(lon)]))
        case .readOnly:
            return .failure(SettingsError("read-only"))
        }
    }

    /// "image" / "video" by the file's extension, else nil.
    static func mediaKind(_ path: String) -> String? {
        guard let t = UTType(filenameExtension: (path as NSString).pathExtension) else { return nil }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return "video" }
        if t.conforms(to: .image) { return "image" }
        return nil
    }

    /// The patch touches what plays (needs “Let AI change what plays”).
    static func gatedKeys(_ changes: [Change]) -> [String] { changes.filter(\.def.gated).map(\.def.key) }

    static let shortGroup: [String: String] = ["general": "General", "screensaver": "Screensaver", "music": "Music",
                                                "weather": "Weather", "wallpaper": "Live Wallpaper", "source": "Source",
                                                "updates": "Updates"]

    /// One line for a change ("Music ▸ Show music: fullScreen").
    static func describe(_ c: Change, library: Library) -> String {
        var v = c.value.display
        if let b = c.value.boolValue { v = b ? "on" : "off" }
        if c.def.type == .style, let id = c.value.stringValue.flatMap(UUID.init) {
            v = "“\(library.presets.first { $0.id == id }?.name ?? id.uuidString)”"
        }
        if c.def.type == .photos, case .array(let a) = c.value { v = "\(a.count) photo\(a.count == 1 ? "" : "s")" }
        if c.def.type == .location { v = place(c.value).map(\.name) ?? "automatic (from the internet connection)" }
        return "\(shortGroup[c.def.group] ?? c.def.group) ▸ \(c.def.label): \(v)"
    }

    // MARK: Apply (on the files: dotstudio-mcp while the app isn't running, and its stand-in app)

    /// Apply validated changes. `importMedia` copies a file into the library's media folder and
    /// returns its stored name (SharedStore.importMedia).
    static func apply(_ changes: [Change], to s: inout State, importMedia: (URL) throws -> String) throws {
        for c in changes { try apply(c, to: &s, importMedia: importMedia) }
        // Library.syncTimeBase mirrors "a wallpaper is matching the screensaver" (the app keeps it
        // so too, at launch and on every wallpaper change).
        let on = s.wallpaper["enabled"]?.boolValue == true && s.wallpaper["followsScreensaver"]?.boolValue == true
        s.library.syncTimeBase = on ? true : nil
    }

    private static func apply(_ c: Change, to s: inout State, importMedia: (URL) throws -> String) throws {
        let v = c.value
        if let pk = c.def.prefKey { s.prefs[pk] = v.boolValue; return }
        var lib = s.library
        defer { s.library = lib }
        func rotation(_ f: (inout RotationSpec) -> Void) { var r = lib.rotation ?? RotationSpec(); f(&r); lib.rotation = r }
        func music(_ f: (inout MusicSpec) -> Void) { var m = lib.musicSettings; f(&m); lib.music = m }
        switch c.def.key {
        case "screensaver.changeEveryMinutes": rotation { $0.intervalMinutes = v.doubleValue ?? 5 }
        case "screensaver.shuffle": rotation { $0.shuffle = v.boolValue ?? false }
        case "screensaver.crossfadeSeconds": rotation { $0.transitionSeconds = v.doubleValue ?? 1.5 }
        case "screensaver.quality": lib.renderScale = renderScale(v.stringValue)
        case "power.frameRate": lib.frameRate = v.stringValue.flatMap { Int($0) }
        case "music.show": music { $0.setDisplay(MusicSpec.Display(rawValue: v.stringValue ?? "") ?? .corner) }
        case "music.corner": music { $0.cardCorner = MusicSpec.Corner(rawValue: v.stringValue ?? "") }
        case "music.size": music { $0.cardSize = MusicSpec.CardSize(rawValue: v.stringValue ?? "") }
        case "music.layout": music { $0.fullLayout = MusicSpec.FullLayout(rawValue: v.stringValue ?? "") }
        case "music.behind": music { $0.fullBackdrop = MusicSpec.Backdrop(rawValue: v.stringValue ?? "") }
        case "music.onWallpaper": music { $0.cardOnWallpaper = v.boolValue }
        case "music.keepPausedSongMinutes": music { $0.lingerMinutes = v.doubleValue }
        case "music.source": music { $0.source = MusicSpec.SourcePreference(rawValue: v.stringValue ?? "") }
        case "weather.location":
            // The app also restarts (or stops) its IP lookup (AppModel.setLocation).
            if let p = place(v) { lib.setManualLocation(p) } else { lib.setAutomaticLocation() }
        case "wallpaper.on":
            if v.boolValue == true {
                s.wallpaper["enabled"] = .bool(true)
                if s.wallpaper["followsScreensaver"]?.boolValue != true {
                    // WallpaperController.setEnabled(true): the last style, else the screensaver's.
                    let id = existing(s.wallpaper["presetID"]?.stringValue, lib) ?? lib.activeID ?? lib.presets.first?.id
                    if let id { s.wallpaper["presetID"] = .string(id.uuidString) }
                }
            } else {
                s.wallpaper["enabled"] = .bool(false)
            }
        case "wallpaper.sameAsScreensaver":
            if v.boolValue == true {
                s.wallpaper["followsScreensaver"] = .bool(true)
                s.wallpaper["enabled"] = .bool(true)
            } else {
                // Leaving it keeps a style on screen: the chosen one, else what plays now.
                if existing(s.wallpaper["presetID"]?.stringValue, lib) == nil, !lib.presets.isEmpty {
                    // (the lineup's pick: a When rule playing now is a passing overlay, not a choice)
                    s.wallpaper["presetID"] = .string(Playback.effectivePreset(in: lib, now: Date(), live: nil).id.uuidString)
                }
                s.wallpaper["followsScreensaver"] = .bool(false)
            }
        case "wallpaper.style":
            s.wallpaper["presetID"] = v
            if s.wallpaper["enabled"]?.boolValue == true { s.wallpaper["followsScreensaver"] = .bool(false) }
        case "wallpaper.frameRate": s.wallpaper["frameRate"] = .integer(v.stringValue == "smooth" ? 120 : 30)
        case "wallpaper.quality": s.wallpaper["quality"] = v
        case "wallpaper.onBattery":
            s.wallpaper["batteryMode"] = v
            s.wallpaper["freezeOnBattery"] = .bool(v.stringValue == "still")   // what a 1.4 build reads
        case "wallpaper.otherAppPluggedIn": s.wallpaper["otherAppPluggedIn"] = v
        case "wallpaper.otherAppOnBattery": s.wallpaper["otherAppOnBattery"] = v
        case "wallpaper.fpsModePluggedIn": s.wallpaper["fpsModePluggedIn"] = v
        case "wallpaper.fpsModeOnBattery": s.wallpaper["fpsModeOnBattery"] = v
        case "wallpaper.lockScreenPicture": s.wallpaper["lockScreen"] = v
        case "source.kind": lib.source.kind = SourceKind(rawValue: v.stringValue ?? "") ?? .collection
        case "source.photos":
            lib.source.kind = .collection
            if case .array(let items) = v {
                lib.source.mediaFilenames = try items.compactMap(\.stringValue).map { try importMedia(URL(fileURLWithPath: $0)) }
            } else {
                lib.source.mediaFilenames = nil
            }
        case "source.mediaFile":
            guard let p = v.stringValue else { return }
            lib.source.mediaFilename = try importMedia(URL(fileURLWithPath: p))
            lib.source.kind = mediaKind(p) == "video" ? .video : .image
        case "source.secondsEach": lib.source.slideSeconds = v.doubleValue
        case "source.panAndZoom": lib.source.motion = v.doubleValue
        case "source.gradientFrom": lib.source.colorA = rgba(v) ?? lib.source.colorA
        case "source.gradientTo": lib.source.colorB = rgba(v) ?? lib.source.colorB
        case "source.gradientAngle": lib.source.gradientAngle = v.doubleValue ?? lib.source.gradientAngle
        case "source.gradientDrift": lib.source.gradientDrift = v.doubleValue ?? lib.source.gradientDrift
        case "source.scaling": lib.source.fillMode = fillMode(v.stringValue)
        default:
            throw SettingsError("\(c.def.key) can only be changed while DotStudio is running — ask the user to open DotStudio, then try again.")
        }
    }

    /// A validated weather.location value → the user's place (nil = "auto").
    static func place(_ v: JSONValue) -> NamedPlace? {
        guard case .object(let o) = v, let lat = o["lat"]?.doubleValue, let lon = o["lon"]?.doubleValue else { return nil }
        return NamedPlace(name: o["name"]?.stringValue ?? NamedPlace.coordinateName(lat, lon), lat: lat, lon: lon)
    }

    static func existing(_ id: String?, _ lib: Library) -> UUID? {
        guard let id = id.flatMap(UUID.init), lib.presets.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    static func renderScale(_ name: String?) -> Double? {
        switch name { case "balanced": return 0.75; case "efficient": return 0.5; default: return nil }
    }

    static func fillMode(_ name: String?) -> Int { name == "fit" ? 0 : name == "stretch" ? 2 : 1 }

    static func rgba(_ v: JSONValue) -> RGBA? {
        guard case .object(let o) = v, let r = o["r"]?.doubleValue, let g = o["g"]?.doubleValue, let b = o["b"]?.doubleValue else { return nil }
        return RGBA(r, g, b, o["a"]?.doubleValue ?? 1)
    }

    // MARK: Actions (the running app only)

    /// "Do it for me": things the app's own buttons do, which an assistant may trigger.
    static let actions: [(id: String, meaning: String)] = [
        ("install_screensaver", "Install (or reinstall) DotStudio's screensaver in ~/Library/Screen Savers — Settings ▸ Screensaver ▸ Install. If it isn't chosen yet, System Settings opens where the user picks it."),
        ("open_screensaver_settings", "Open System Settings ▸ Wallpaper, where the user clicks Screen Saver… and picks DotStudio (Settings ▸ Screensaver ▸ Open Wallpaper Settings)."),
        ("show_setup_guide", "Open the step-by-step setup guide panel (Help ▸ Set Up Screensaver…, Settings ▸ General ▸ Run Setup Again…): install, choose DotStudio, the idle and display-sleep times, open at login."),
        ("guide_me", "Open the setup guide and start Guide Me: DotStudio rings the next control to click in System Settings. The first time, macOS asks the user to allow Accessibility."),
        ("open_lock_screen_settings", "Open System Settings ▸ Lock Screen (when the screensaver starts, when the display turns off)."),
        ("open_login_items_settings", "Open System Settings ▸ General ▸ Login Items (for a login item waiting for approval)."),
        ("check_for_updates", "Settings ▸ Updates ▸ Check Now: look for a new DotStudio (Sparkle shows what it finds). Never installs by itself."),
        ("open_settings", "Open DotStudio's Settings window."),
        ("open_main_window", "Open DotStudio's main window (the gallery)."),
        ("show_welcome", "Show the welcome tour again (Help ▸ Welcome to DotStudio…)."),
    ]
}

struct SettingsError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

extension JSONValue {
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var doubleValue: Double? {
        switch self {
        case .number(let d): return d
        case .integer(let i): return Double(i)
        default: return nil
        }
    }

    /// Compact, for messages.
    var display: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .integer(let i): return String(i)
        case .number(let d): return AppSettings.fmt(d)
        case .string(let s): return s
        case .array(let a): return "[" + a.map(\.display).joined(separator: ", ") + "]"
        case .object(let o):
            if let r = o["r"]?.doubleValue, let g = o["g"]?.doubleValue, let b = o["b"]?.doubleValue {
                return String(format: "rgb(%.2f, %.2f, %.2f)", r, g, b)
            }
            return "{" + o.keys.sorted().map { "\($0): \(o[$0]!.display)" }.joined(separator: ", ") + "}"
        }
    }
}
