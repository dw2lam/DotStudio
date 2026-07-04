# Changelog

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
