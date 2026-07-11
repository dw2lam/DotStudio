# Changelog

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
