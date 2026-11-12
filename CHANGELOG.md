# Changelog

## Unreleased

### New
- **Guide Me in System Settings.** The setup guide can now point at the exact control to
  click — Wallpaper, Screen Saver…, the Other section, DotStudio, Done — with a glowing ring
  right in System Settings, and moves on by itself as you click. It never gets in the way of
  your clicks. It asks once for Accessibility permission (it only reads System Settings, and
  only while the guide is open); without it, the illustrated guide works as before.

## 1.4.5 — Meadow and Bloom

### New
- **Meadow.** Wildflowers at your feet and rolling hills under big summer clouds, with a fine
  film grain. Follows the real sun, moon and your weather. Also **Tall Grass**: low in long
  grass, backlit at golden hour. (Rolling Hills and Hillside are in File › Add Built-in Styles.)
- **Bloom.** A single flower swaying in a breeze, set in tiny letters or glowing LED dots at
  24 fps: **Blue Bloom** (a blue poppy on a deep-to-powder blue sky) and **Baby's Breath**.
  White Anemone is in Add Built-in Styles.

### Changed
- **Tidewater is now Golden Hour.** They were the same scene; Follow the Sun is Golden Hour's
  setting. An untouched Tidewater leaves your library, and if you were using it, Golden Hour
  takes its place with Follow the Sun on. An edited Tidewater stays.

### Fixed
- More of the layouts that could crash on macOS 26 and earlier (Settings rows, banners, the
  filter chips) no longer swap controls while the window lays itself out.

## 1.4.4 — Stability

### Fixed
- **Crash on macOS 26 when opening a style.** Opening the editor (double-click a scene, or
  its Edit button) could crash DotStudio on macOS 26: the colour wells in the editor kept
  re-laying the window out. They now pick their layout without measuring mid-layout.
- The screensaver plays black instead of crashing if the library is empty, and the renderer
  falls back to black instead of crashing if the GPU can't create a resource.

### New
- **Crash reports.** If DotStudio ever quits unexpectedly, the next launch shows what
  happened and offers to send a report (opens a pre-filled GitHub issue — nothing is
  uploaded automatically). Help › Report a Problem… does the same any time.
- **Safe mode.** After repeated crashes at launch, DotStudio starts with live previews and
  the live wallpaper paused, with a button to start normally.

## 1.4.3 — Setup, battery and the lock screen

### New
- **Guided setup.** An animated walkthrough of System Settings › Wallpaper › Screen Saver…
  › Other › DotStudio, with a checklist that ticks itself: installed, chosen (on every
  display), "Start Screen Saver when inactive", and a warning when your display sleeps
  before the screensaver starts. Open it any time from Help › Set Up Screensaver….
- **Open at login** is on by default in setup, and DotStudio offers it once when you turn
  on the wallpaper or music.
- **Lock & login screen picture** (optional): DotStudio sets a still of your wallpaper as
  your Mac's picture, refreshed when it locks. Turning it off restores your picture.

### Better on battery
- The live wallpaper's new **On Battery** setting: Efficient (default — 20 fps at a lower
  resolution, about 70–80% less GPU work), Full or Still.
- The screensaver runs at 24 fps and a lower resolution on battery, 15 fps at half
  resolution in Low Power Mode, and its System Settings preview is much lighter.

### Fixed
- The wallpaper no longer cuts out when you switch desktops.
- The screensaver's thumbnail in System Settings shows Liquid Chrome.

## 1.4.2 — Three new clocks

### New
- **StandBy.** The time in huge, bold rounded digits, readable from across the room,
  turning deep red after sunset.
- **Minimal.** Thin, quiet time with the weekday and date set beneath it.
- **Chronometer.** A classic wristwatch dial: sunburst finish, polished indices,
  a sweeping seconds hand and a date window.

### Retired
- Sunray, Opaline, Pipeworks, Brass Pipes, Light Tunnel, Hex Tunnel, Fireflies and
  Blue Hour. They're removed from your library unless you edited them — an edited copy
  stays and keeps working. Anything that pointed at a removed style (your current
  style, night style, rotation or wallpaper) moves to another one; Sunray and Opaline
  hand over to Chronometer.

### Fixed
- **Zen Garden.** The rake cart now ploughs the gravel instead of floating over it — its tines
  sit in the furrows, the new pattern starts right at the tines, gravel heaps in front of the
  rake and the wheels leave ruts.
- Zen Garden now reaches libraries that came from 1.3 and never got it.

## 1.4.1 — Bounce

### New
- **Bounce.** A logo drifts corner to corner, bouncing off the edges and changing
  colour on every bounce — and every couple of minutes it lands exactly in a corner,
  with a little flourish. Use the built-in DotStudio mark, type your own word, or pick
  any image (transparent logos are trimmed to their visible edges and tinted).

## 1.4.0 — What's playing, live skies, and a wallpaper in sync

### New
- **What's playing.** Spotify or Apple Music over any screensaver — in a corner, or
  full screen in Album, Stage or Cover layouts over the album's living art. Play,
  pause and skip from the app or the menu bar.
- **Live wallpaper with SYNC.** Any style behind your windows, or press SYNC and the
  desktop follows the screensaver in step.
- **Live skies.** Tidewater follows the real sun and moon; the sea scenes follow your
  local weather — cloud, rain, storms, fog and snow.
- **New scenes.** Zen Garden, Tidewater, Shallows, Sunray, Pleats, Dichroic and more,
  plus a fidelity pass across the library. Glass Clock is retired (Sunray replaces it).
- **A new home.** Redesigned gallery and cards, an editor that scales to any window,
  a menu-bar app, and a new icon.

### Faster
- The screensaver appears almost instantly (pipelines precompiled per Mac).
- Every scene draws with its own GPU pipeline — 20–80% less GPU per frame.
- Smoother scrolling, far fewer redraws, and a near-idle menu-bar app.
- Signed with a stable identity, so privacy permissions survive updates.

## 1.3.0 — A new DotStudio: gallery, scenes, and making your own

### New
- **A gallery-first app.** Every style is a tile; the Playback bar on top picks
  what plays (One Style, Rotate, Day & Night). Double-click any tile to open the
  editor — a big live preview with Effects and Source side by side.
- **Welcome guide.** Pick a preset or create your own on the spot, then turn the
  screensaver on with a live checklist. Reopen it from Help → Welcome to DotStudio.
- **Scenes and Looks.** Scenes draw themselves; Looks restyle your canvas — now a
  built-in slideshow of public-domain photos that slowly pans and cross-fades, or
  your own photos and video.
- **New scenes**
  - *Clocks* — Glass & Plaster type clocks, a 3D Flip Clock, a Word Clock, and
    Window Light (sunlight drifting across a wall with the real sun).
  - *Flowing* — Lava Lamp, Currents, Fireflies.
  - *Nature* — Golden Hour, Night Sky (with tonight's real moon phase),
    First Snow, and a completely rebuilt Aurora.
  - *Retro* — Neon Horizon, Pipeworks, Light Tunnel, Light Ribbons.
  - *Universe* is now a 3D solar system on a slowly orbiting camera.
- **Automatic updates.** DotStudio checks GitHub hourly, downloads new versions in
  the background and installs them when you quit (or Settings → Updates →
  Restart to Update). The screensaver updates along with the app.

### Fixed / improved
- **"Couldn't Save Changes" is gone.** The library now lives in
  `~/Library/Application Support/DotStudio` instead of the screensaver's sandbox
  container, which macOS blocks after every app update.
- Looks were re-tuned on real photos (ASCII, Atkinson, Floyd–Steinberg, Soft
  Focus, Fluted Glass); dated and duplicate effects were retired from the menus
  (old libraries still open and render them).
- The default library is a curated 28; everything else is in File → Add Built-in
  Styles.

> **Installing:** DotStudio isn't notarized. Open it once, then go to
> System Settings → Privacy & Security and click **Open Anyway**. From 1.3.0 on,
> updates install themselves.

## 1.2.0 — Rotation, day/night, and a trustworthy foundation

### New
- **Rotate through styles** — the screensaver can cycle your presets on an
  interval (1 min – 1 hour), in order or shuffled, with a **GPU crossfade**
  between them. Every display shows the same preset with no coordination.
- **Day / night styles** — pick one preset for daytime and one for night;
  DotStudio follows the actual sun at your location (falls back to your
  time zone) and crossfades at sunrise/sunset.
- **Share presets** — File → Export/Import Screensavers (`.dotstudiopreset`
  files, drag-drop onto the sidebar works too). Files from newer versions
  import gracefully, skipping effects this build doesn't know.
- **Quality setting** (Full / Balanced / Efficient): renders the screensaver
  at reduced resolution — Efficient cuts GPU memory and bandwidth ~4× on
  Retina displays with the same chunky aesthetic.
- **Auto-updates via Sparkle** — the app checks for new releases and refreshes
  the installed screensaver after updating itself.

### Fixed / improved
- **Fixed runaway memory in the macOS screensaver host.** macOS never releases
  screensaver views it has abandoned (a system bug affecting all third-party
  savers) — each activation stranded a full GPU stack, growing the
  `legacyScreenSaver (Wallpaper)` process by hundreds of MB per lock/unlock
  (observed: 5 GB in two days on two displays). DotStudio now tears down its
  Metal resources the moment the host abandons a view; memory stays flat.
- **Your library can no longer be silently wiped.** A damaged `library.json` is
  backed up and reported with a "Reveal Backup" alert; the running screensaver
  keeps its last-good preset. Import and save failures are surfaced too.
- **Battery aware**: frame rate caps at 15 fps on battery, 10 fps in Low Power
  Mode, and the System Settings preview thumbnail now runs at 10 fps.
- **Video presets get real thumbnails** (poster frame) instead of a gradient.
- Releases are now built and published by CI directly from the version tag.
- Debug logging is opt-in (`touch debug.enabled` next to `library.json`).

## 1.1.3 — Critical fix: screensaver memory leak

- **Fixed a severe GPU memory leak** in the screensaver render loop that could grow
  the `legacyScreenSaver` host process to 14 GB+ over time while idle. The per-frame
  Metal draw path was missing an autorelease pool, so each frame's `CAMetalDrawable` /
  IOSurface and command buffer accumulated instead of being released. `MetalRenderer.draw(in:)`
  now runs inside an `autoreleasepool`.
- **Capped frames-in-flight** with a semaphore so at most two frames' GPU resources
  are ever outstanding.
- **Capped the CAMetalLayer drawable pool** (`maximumDrawableCount = 3`). Previously
  uncapped, it had grown to ~13 display drawables (~430 MB). Steady-state footprint
  drops from ~1.2 GB to ~400 MB.

## 1.1.2 and earlier

See the [GitHub releases](https://github.com/dw2lam/DotStudio/releases) for
history prior to this changelog.
