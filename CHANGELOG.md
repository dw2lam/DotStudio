# Changelog

## 1.2.0 — Trustworthy & efficient

- **Your library can no longer be silently wiped.** A damaged `library.json` is
  backed up and reported with a "Reveal Backup" alert; the running screensaver
  keeps its last-good preset. Import and save failures are surfaced too.
- **New Quality setting** (Full / Balanced / Efficient): renders the screensaver
  at reduced resolution — Efficient cuts GPU memory and bandwidth ~4× on Retina
  displays with the same chunky aesthetic.
- **Battery aware**: frame rate caps at 15 fps on battery, 10 fps in Low Power
  Mode, and the System Settings preview thumbnail now runs at 10 fps.
- **Video presets get real thumbnails** (poster frame) instead of a gradient.
- **Auto-updates via Sparkle** — the app checks for new releases and refreshes
  the installed screensaver after updating itself.
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
