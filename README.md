<p align="center">
  <img src="docs/icon.png" width="128" alt="DotStudio icon">
</p>

<h1 align="center">DotStudio</h1>

<p align="center">
  Living screensavers and wallpaper for your Mac: generative scenes, real clocks,<br>
  live skies, and the song you're playing on top.<br>
  <a href="https://dotstudio.davidlam.online"><b>dotstudio.davidlam.online</b></a> ·
  <a href="https://github.com/dw2lam/DotStudio/releases/latest/download/DotStudio.dmg">Download</a>
</p>

<p align="center">
  <a href="https://github.com/dw2lam/DotStudio/releases/latest"><img src="https://img.shields.io/github/v/release/dw2lam/DotStudio?label=release&color=black" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-Metal-blue" alt="Apple Silicon · Metal">
  <img src="https://img.shields.io/badge/Swift-SwiftUI-orange?logo=swift" alt="Swift · SwiftUI">
</p>

<p align="center">
  <img src="docs/app.png" width="860" alt="The DotStudio gallery: Screensaver and Wallpaper cards joined by the SYNC key above a grid of scenes">
</p>

Pick from the gallery or build your own in a live editor. DotStudio installs one screensaver,
then everything — which style plays, at night, in rotation, behind your windows — happens in
the app. Native, local, free.

## Features

- **Scenes and Looks.** Scenes paint themselves — Liquid Chrome, Topography, Zen Garden, a 3D
  solar system, a black hole. Looks restyle your own photos and video (or the built-in
  public-domain slideshow): film, riso, cyanotype, dithers, ASCII, CRT.
- **Clocks.** StandBy, Minimal and Chronometer are new in 1.4.2, alongside Flip Clock,
  Word Clock and Window Light.
- **Bounce.** A logo drifts corner to corner, changing colour on every bounce, and every couple
  of minutes lands exactly in a corner. Use the DotStudio mark, a word, or your own logo.
- **Meadow and Bloom.** Rolling wildflower hills and tall grass that follow your sky and weather,
  and a single flower set in tiny letters or LED dots at 24 fps.
- **Live skies.** Golden Hour can follow the real sun and moon; the sea scenes follow your local
  weather — cloud, rain, storms, fog and snow.
- **What's playing.** Spotify or Apple Music over any screensaver — in a corner, or full screen
  in Album, Stage or Cover layouts over the album's living art.
- **Live wallpaper with SYNC.** Any style behind your windows, or press SYNC and the desktop plays
  the screensaver's scene in step, so the screensaver starts right where your desktop was.
- **Playlist and Night.** One style, a rotation, and another look after your real sunset.
- **In the menu bar.** Music, wallpaper and styles without opening a window.
- **Instant start.** The screensaver is up the moment your Mac goes idle.
- **Efficient.** Every scene draws with its own GPU pipeline; the wallpaper pauses when windows
  cover it, and frame rate caps on battery. 120 fps on ProMotion displays, when you want it.
- **Updates itself.** New versions arrive from GitHub Releases and install when you quit.
- **Private.** Your library stays on your Mac. Weather is fetched for your approximate location,
  rounded to about 10 km. When a player doesn't hand over a cover, DotStudio looks it up in
  Spotify's or Apple's public catalog — only the song's ID, or its artist and album, is sent.

## Gallery

Every frame here is rendered by the app.

| | | |
|:--:|:--:|:--:|
| <img src="docs/gallery/liquid-chrome.jpg" alt="Liquid Chrome"><br>**Liquid Chrome** | <img src="docs/gallery/topography.jpg" alt="Topography"><br>**Topography** | <img src="docs/gallery/universe.jpg" alt="Universe"><br>**Universe** |
| <img src="docs/gallery/zen-garden.jpg" alt="Zen Garden"><br>**Zen Garden** | <img src="docs/gallery/golden-hour.jpg" alt="Golden Hour at sunset"><br>**Golden Hour** | <img src="docs/gallery/aurora.jpg" alt="Aurora"><br>**Aurora** |
| <img src="docs/gallery/black-hole.jpg" alt="Black Hole"><br>**Black Hole** | <img src="docs/gallery/standby.jpg" alt="StandBy clock"><br>**StandBy** | <img src="docs/gallery/chronometer.jpg" alt="Chronometer clock"><br>**Chronometer** |
| <img src="docs/gallery/minimal.jpg" alt="Minimal clock"><br>**Minimal** | <img src="docs/gallery/bounce.jpg" alt="Bounce with the DotStudio logo"><br>**Bounce** | <img src="docs/gallery/word-clock.jpg" alt="Word Clock"><br>**Word Clock** |
| <img src="docs/gallery/meadow.jpg" alt="Meadow at golden hour"><br>**Meadow** | <img src="docs/gallery/tall-grass.jpg" alt="Tall Grass, backlit at golden hour"><br>**Tall Grass** | <img src="docs/gallery/blue-bloom.jpg" alt="Blue Bloom: a blue poppy set in tiny glyphs"><br>**Blue Bloom** |

### What's playing

| | |
|:--:|:--:|
| <img src="docs/gallery/music-album.jpg" alt="Full Screen music, Album layout"><br>**Full Screen** · Album | <img src="docs/gallery/music-corner.jpg" alt="A now-playing card in the corner of Topography"><br>**Corner** · over Topography |

<sub>Demo track and artwork.</sub>

### The editor

Double-click any tile. A big live preview beside every dial — angle, speed, colour, frame rate.
Stack effects on top of a scene, or start from nothing with **Create Your Own**.

<p align="center">
  <img src="docs/editor.png" width="860" alt="The DotStudio editor: a live Black Hole preview beside its scene and Bloom layers">
</p>

## Install

1. Download **[DotStudio.dmg](https://github.com/dw2lam/DotStudio/releases/latest/download/DotStudio.dmg)**
   from the [latest release](https://github.com/dw2lam/DotStudio/releases/latest), open it and
   drag **DotStudio** into **Applications**.
2. Open DotStudio from Applications. It isn't notarized yet, so macOS stops the first launch
   with "Apple could not verify…". Click **Done** (not Move to Trash).
3. Open **System Settings › Privacy & Security** and scroll down to **Security**. Next to
   "DotStudio was blocked to protect your Mac", click **Open Anyway**, confirm with your password
   or Touch ID, then click **Open Anyway** once more. The button shows for about an hour after
   the blocked launch; if it's gone, open DotStudio again and come back.
   (On macOS 15 and later, right-click › Open no longer skips this step.)
4. Follow the welcome guide. It installs the screensaver, walks you through choosing it, and
   explains music and the menu bar. It's always under **Help › Welcome to DotStudio…**.

You only do this once. Updates are automatic: DotStudio checks GitHub Releases, downloads new
versions in the background and installs them when you quit (or **Settings › Updates › Restart
to Update**). The screensaver updates along with the app. Releases are signed with a stable
identity, so privacy permissions (like Automation for Spotify and Music) survive updates.

Requires macOS 14 or later. Made and tested on Apple Silicon.

## Using DotStudio

### The screensaver

DotStudio installs one screensaver; which style it plays is chosen in the app. To turn it on,
open **System Settings › Wallpaper**, click **Screen Saver…**, and pick **DotStudio** under
**Other**. The guided setup (**Help › Set Up Screensaver…**, or **Settings › General › Run Setup
Again…**) shows each click beside a live checklist.

From then on, pick styles in the gallery: one style, a playlist that rotates, and another style
for the night.

### Live wallpaper

Any style can play behind your windows from the **Wallpaper** card, or press **SYNC** and the
desktop plays the screensaver's scene in step. It plays while DotStudio is running (closing the
window keeps it in the menu bar) and costs nothing while it can't be seen: it pauses when
windows cover the desktop, the screen locks or sleeps, or the screensaver starts.

- **On battery** (**Settings › Live Wallpaper › On Battery**): **Efficient**, the default, plays
  at 20 fps and a lower resolution; **Full** plays as when plugged in (up to 30 fps); **Still**
  holds a frame.
- **Low Power Mode**, or a Mac running hot, holds a still frame and the Wallpaper card says so
  ("Still — Low Power Mode"). It moves again when Low Power Mode is off. Clocks still turn over
  every minute.

### Music (Spotify & Apple Music)

While a song plays in Spotify or Apple Music, the screensaver shows it over whatever style is
playing, and optionally on the live wallpaper too. When the music stops, it goes away; a paused
song stays for 5 minutes (or 1, or 15).

- **Show music**: **Off**, **Corner** (the default; pick the corner and size), or **Full
  Screen** in an **Album**, **Stage** or **Cover** layout, over the album's living art or over
  your screensaver, softly blurred.
- **Where to change it**: the **Music** key on the Screensaver card, or **Settings › Music**,
  which also has **Also on the live wallpaper**, how long a paused song stays, and the
  **Source**: **Automatic**, **Spotify** or **Apple Music**.
- **Controls**: Play/Pause, Previous and Next in the DotStudio menu-bar menu and Settings ›
  Music; Play/Pause and Next on the song line of the Screensaver card.

**How it connects.** No Spotify login, no API keys. DotStudio listens for the now-playing
notifications the Spotify and Music apps on your Mac already send, and talks to them with Apple
Events (macOS Automation), only while they're open; it never launches them. The first time a
song plays, macOS asks once whether DotStudio may control Spotify (or Music). Allow it for exact
progress, the player's own artwork and the controls.

If you don't, the song still shows, but the controls are off and Settings › Music shows **Needs
permission** with an **Allow…** button. To change your answer, open **System Settings › Privacy &
Security › Automation**, expand **DotStudio**, and turn on **Spotify** or **Music**. To be asked
again from scratch, run `tccutil reset AppleEvents com.davidlam.DotStudio` in Terminal (it
resets DotStudio's Automation answers for every app).

**What leaves your Mac.** Song details come from the players on this Mac and stay there. When a
player doesn't hand over the cover, DotStudio looks it up in Spotify's or Apple's public catalog;
only the song's ID, or its artist and album, is sent.

**Keep it running.** The screensaver only knows what's playing while DotStudio runs. With **Keep
running in the menu bar** (on by default), closing the window leaves it in the menu bar; turn on
**Open DotStudio at login** in **Settings › General** so it's back after a restart.

## Troubleshooting

- **"Apple could not verify DotStudio…"**: expected on first launch. Use **Open Anyway** in
  System Settings › Privacy & Security ([Install](#install), step 3).
- **DotStudio isn't in the screensaver list**: open DotStudio, choose **Help › Set Up
  Screensaver…** and click **Install** (it goes into `~/Library/Screen Savers`). Then quit and
  reopen System Settings and look under **Other**.
- **The live wallpaper is still or paused**: the Wallpaper card says why. *Still — Low Power
  Mode*, *Still — Mac is running hot* and *Still — on battery* (On Battery set to Still) hold a
  frame on purpose; it also pauses while windows cover the desktop, and plays only while
  DotStudio is running.
- **Music doesn't show**: check that **Show music** isn't Off, DotStudio is running, and the song
  is playing in the Spotify or Music app on this Mac (not on another device). If the controls are
  greyed out, allow DotStudio in **System Settings › Privacy & Security › Automation**.
- **Something else**: **Help › Report a Problem…** shows a report you can read first; **Send Report…**
  copies it and opens a new GitHub issue to paste it into.

### Build from source

Needs Xcode 26 or later (the app uses the macOS 26 SDK) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
git clone https://github.com/dw2lam/DotStudio.git && cd DotStudio
xcodegen generate
xcodebuild -project DotStudio.xcodeproj -scheme DotStudio -configuration Release \
  -derivedDataPath build build
open build/Build/Products/Release
```

If the first build asks for the Metal toolchain: `xcodebuild -downloadComponent MetalToolchain`.

## How it works

- **One screensaver.** The app embeds a single universal `DotStudio.saver`. It reads the shared
  library in `~/Library/Application Support/DotStudio` (read-only, from the sandboxed screensaver
  host) and plays whatever the library says. The app writes the library, plus the music and
  weather state the screensaver shows. Switching styles never touches System Settings.
- **A pipeline per scene.** Each scene is compiled into its own Metal pipeline, and after an
  install or update the app precompiles them for your Mac into a pipeline archive, so the
  screensaver draws its first frame almost immediately.
- **Wallpaper.** Desktop-level windows paced to the display. They stop drawing entirely while
  covered, locked, asleep or under the screensaver, and hold still when the Mac runs hot.

## Development

Headless tools — nothing is shown on screen, and each one runs against a throwaway store
(`DOTSTUDIO_STORE_DIR=$(mktemp -d)`), never your real library.

| Tool | What it does |
|---|---|
| `tools/gallery/render.sh <dir> --only "Aurora" --size 1280x800` | Renders the default styles to PNGs (`--clock`, `--weather`, `--logo`, music flags; see `main.swift`) |
| `tools/perf/run.sh renderer\|saver\|wallpaper\|idle` | CPU, allocation, file-system and wake-up costs of the render loops |
| `tools/startup/run.sh` | Time to first frame, cold and warm |
| `tools/music-selftest/run.sh` | End-to-end music detection, driven by synthetic player notifications |
| `tools/icon/build.sh <dir>` | Regenerates the app icon from the renderer |
| `DOTSTUDIO_UI_SHOTS=<dir>` on the app binary | Off-screen renders of every app screen (`DOTSTUDIO_UI_ONLY`, `_SIZES`, `_APPEARANCE`; see `App/Shots.swift`) |

Release history is in [CHANGELOG.md](CHANGELOG.md). Tagging `v*` builds, signs and publishes a
release with its Sparkle appcast (`.github/workflows/release.yml`).

## Credits

Built with SwiftUI and Metal. Updates by [Sparkle](https://sparkle-project.org).

- Weather: [Weather data by Open-Meteo.com](https://open-meteo.com/), licensed
  [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
- Earth and planet maps in **Universe**: [Solar System Scope](https://www.solarsystemscope.com/textures/),
  licensed [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
- Built-in slideshow photos: CC0 and public domain, via Wikimedia Commons — see
  [Shared/Photos/CREDITS.md](Shared/Photos/CREDITS.md).
- The Looks were inspired by [grain.rad](https://grainrad.com) and [ditherit.com](https://ditherit.com).
