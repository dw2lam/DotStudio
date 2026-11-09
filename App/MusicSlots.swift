//  MusicSlots.swift — where the music feature plugs into the app's chrome. Each slot renders
//  NOTHING until the music stage fills it (replace the bodies; keep the type names, the call
//  sites already place them).
//
//  ┌ MUSIC SLOT: menu bar ─────────────────────────────────────────────────────────────────┐
//  │ MenuBarMusicSlot — the TOP of the DotStudio menu-bar menu (MenuBarMenu.swift,          │
//  │ DotStudioMenu). Menu-style content: the current track as a disabled line              │
//  │ ("Song — Artist", via menuName(_:) so it stays one line), Play/Pause, Previous, Next  │
//  │ (Button items; Space as the play/pause shortcut is fine inside the menu), then a       │
//  │ trailing Divider(). While nothing is playing render nothing at all — not even the     │
//  │ divider — so the menu starts with the Screensaver line. Environment: AppModel,        │
//  │ UpdateController. Real menus can't scale text; UIShots renders it as a column         │
//  │ (MenuPreview in Shots.swift) at every text size.                                      │
//  └───────────────────────────────────────────────────────────────────────────────────────┘
//  ┌ MUSIC SLOT: Settings ─────────────────────────────────────────────────────────────────┐
//  │ MusicSettingsSlot — a whole Form Section placed right after Settings › General        │
//  │ (SettingsView.swift). Follow WallpaperSettingsSection: SettingsHeader("Music"),       │
//  │ .formSwitchSize() toggles, SettingsValueRow for segmented pickers, SettingsNote       │
//  │ footers, text through .textRole(...). The "keep running in the menu bar" and login    │
//  │ switches it needs already live in General (AppPresence.menuBarMode).                  │
//  └───────────────────────────────────────────────────────────────────────────────────────┘

import SwiftUI

/// MUSIC SLOT (menu bar): track + Play/Pause, Previous, Next, then its own Divider().
struct MenuBarMusicSlot: View {
    var body: some View { EmptyView() }
}

/// MUSIC SLOT (Settings): the Music section, after General.
struct MusicSettingsSlot: View {
    var body: some View { EmptyView() }
}
