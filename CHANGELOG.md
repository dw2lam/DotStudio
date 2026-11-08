# Changelog

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
