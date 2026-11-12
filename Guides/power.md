# Power and Performance

How much a DotStudio style may cost, what the app already does to save battery, and how to keep a new style cheap. A screensaver runs for hours and a live wallpaper runs while the user works, so GPU time per frame times frames per second is battery and heat. Aim for 4 ms or less of GPU per frame at 5K (5120x2880), never more than 6 ms, at the lowest frame rate that still reads smooth, and measure with `benchmark_style` before you hand a style to the user.

## The numbers to remember

- **GPU per frame at 5K, measured on an Apple M5 Pro with `benchmark_style`:**
  - Target: 4 ms or less.
  - Ceiling: 6 ms. This is the repo's own budget (`DotSaverView.costBudgetMs = 6.0`): "well inside a 120 Hz frame's 8.3 ms with the compositor's share, and half a 60 Hz one". The screensaver shrinks its drawable to hold 6 ms only for a few built-in heavy pipelines (Meadow's weather skies); a custom scene gets no automatic cap.
  - Over 8.3 ms drops frames at 120 Hz; over 16.7 ms drops frames at 60 Hz. Never ship that.
  - Intel and AMD GPUs are assumed 2.5x slower per pixel than Apple GPUs, so a 6 ms style is 15 ms on an older Intel Mac.
- **GPU duty** = ms per frame x fps / 1000. 4 ms at 30 fps = 12 % of the GPU busy all the time; 8 ms at 60 fps = 48 %. Keep a wallpaper under about 10 %.
- **Frame rate**: `Preset.fps`, default 30. Use 30 for continuous motion, 24 only for the built-in stepped styles (Bloom, Penguin), 20 or 15 for very slow ambient pieces. Rates that divide 60 and 120 (60, 30, 20, 15, 12, 10) pace evenly everywhere; 24 divides 120 but becomes 20 on a 60 Hz display.

Measured built-ins at 5K (M5 Pro), for calibration:

| Style | GPU ms | Note |
|---|---|---|
| Penguin | 2.5-2.7 | LED cells, parallax backdrop |
| Bloom (Blue Bloom, Baby's Breath, White Anemone) | 1.9 / 2.4 / 1.6 | one flower in cells |
| Meadow (clear) | 5.9 | Rolling Hills 3.2, Tall Grass 7.0, Hillside 3.2 |
| Meadow with weather | +60-75 % | Tall Grass in heavy snow ~16 ms: capped by the saver |
| Liquid Chrome | ~5.4 | 3 surface taps per pixel |
| Golden Hour | ~7.0 | was 9.5 before optimisation |
| Tidewater (Golden Hour, Follow the Sun), clear | 4.6 | 8.1 partly cloudy |
| Neon Horizon | 6.5 | was 7.8 |
| Pleats, Dichroic | ~7.1 | |
| Black Hole | ~11.5 | the heaviest built-in; do not use as a model |

## What the screensaver does

The screensaver (Saver/DotSaverView.swift) draws at the style's `fps` and the user's Quality, then caps both by power state (`PowerBudget`):

| State | Max fps | Max render scale (per axis) |
|---|---|---|
| Plugged in | the style's fps | the user's Quality: Full 1.0, Balanced 0.75, Efficient 0.5 (`Library.renderScale`) |
| On battery | 24 (20 on a 60 Hz display) | 0.6 |
| Low Power Mode | 15 (12 for a 24 fps stepped style) | 0.5 |
| System Settings thumbnail | 10 | 0.35 |

Frame rates snap to an exact divisor of the display's refresh so every frame is held for the same number of refreshes (`FramePacing`, `divisorFPS`): 24 on 120 Hz, 20 on 60 Hz. A stepped style (Bloom) is drawn at the slowest divisor at or above its step rate (24 on 120 Hz, 30 on 60 Hz) and, under a lower budget, at a whole fraction of it (12, "on twos"), so no step is dropped unevenly.

Reduced resolutions are upscaled by the compositor; whole factors use nearest-neighbour to keep dot and pixel styles crisp. Design so a 0.5 scale still looks intentional: soft gradients and large forms survive, 1 px hairlines do not.

## What the live wallpaper does

The wallpaper (App/WallpaperController.swift, App/WallpaperPower.swift) only runs while the DotStudio app runs. Its settings live in `wallpaper.json`:

- **Frame Rate**: Balanced 30 fps (default) or Smooth = the display's refresh, up to 120 Hz on ProMotion. Balanced is capped further by the style's `fps`; Smooth ignores it.
- **Quality** (pixels per point): Full = the display's own density, Balanced = 1.5 (0.75 per axis on Retina, about 56 % of the pixels; default), Efficient = 1.0 (a quarter of the pixels on Retina). A 5K benchmark number is roughly halved at Balanced.
- **On Battery**: Efficient (default) = 20 fps at 0.6x Quality's pixels per point (about 0.36x the pixels, roughly 70-80 % less GPU work); Full = as on power but never above 30 fps; Still = hold one frame.
- **Stills**: Low Power Mode, a hot Mac (thermal state serious or critical) and On Battery: Still hold one frame. A clock still turns over once a minute.
- **Pauses**: nothing is drawn and nothing wakes while the wallpaper cannot be seen: covered by windows, screen locked, display or Mac asleep, screensaver running, or paused from the menu bar.
- **Clocks idle**: the built-in clock kinds draw one frame a second and only animate for a short burst around each change (StandBy 0.65 s a minute, Flip Clock 0.8 s). A clock wallpaper costs almost nothing. Custom scenes and every other scene always count as continuous motion, so build clocks from the built-in clock kinds.
- **Still Looks**: a Look over a still photo whose effects never read time is drawn once.
- Rendering runs on its own thread, on the GPU that drives each display.

## What makes a shader expensive

Cost is per pixel, and 5K is 14.7 million pixels. In rough order of impact:

1. **Raymarching.** Steps x cost of the distance function. 64 steps of a 10-operation SDF is 640 operations per pixel before lighting. Cap steps (32-48), use bounding volumes to skip empty space, and stop early. Retro's pipes and tunnel were ray-traced and are retired anyway.
2. **Fractal noise (fbm).** Each octave is a full noise evaluation. Use 3-5 octaves, fewer for distant or blurred areas; integer-hash value noise or a constant table, never `sin`-based hashes. Domain warping multiplies the cost by the number of warp levels.
3. **Per-pixel loops over objects.** Never loop over every particle per pixel. Put particles on a jittered grid with one candidate per cell and check only the 3x3 neighbourhood (how Fireflies and the Bloom/Penguin cell grids stay cheap).
4. **Neighbour taps.** Gradients by finite differences triple the cost (Liquid Chrome pays for 3 surface evaluations). Prefer analytic derivatives.
5. **Wide blurs and glows in one pass.** A 30-tap glow per pixel is slow; use a small pyramid (the music veil uses a Kawase pyramid at about 1.1 ms) or an analytic falloff.
6. **Transcendentals inside loops**: `pow`, `exp`, `sin`, `atan2`. Hoist them, approximate (`1 / (1 + k * d * d)` instead of `exp(-k * d * d)`, as Bloom does).
7. **Work in empty regions.** Add cheap bounds first: if nothing is near this pixel, return the background (Bloom: "cheap bound: nothing near, transparent"; Penguin skips each cell's corners).
8. **Divergent branches** across neighbouring pixels cost both sides.

Cheap things: a couple of gradients, a few noise octaves, analytic shapes and soft falloffs, a fine dither, grain. Most of the loved styles are cheap: Bloom 2 ms, Penguin 2.6 ms.

## Fewer frames, same look

- Slow motion reads smooth at low frame rates. If on-screen motion stays under about 2-3 px per frame, 20 fps is indistinguishable from 30 for an ambient piece.
- The stepped 24 fps cadence (film, LED panel) is a look, not a saving trick; it is built in only for Bloom and Penguin. A custom shader that floors its own time will judder on 60 Hz displays because the host does not know its step rate. Prefer continuous motion in custom scenes.
- Do not set `fps` above 30 for a style. 60 is allowed by the format but doubles the cost for motion that should be slow anyway.

## How to measure

1. `benchmark_style` with the style id: GPU ms per frame at 5K. Run it after every change that adds detail.
2. Benchmark the worst case, not the average: the most demanding param values the style uses, weather on if it follows the weather, night and day if it follows the sun.
3. If over 4 ms: reduce detail params (density, count, octaves, flowers, clouds, glow radius) first; then simplify the shader; lower `fps` last.
4. Report the number to the user with the style ("about 3 ms a frame at 5K, light on battery").
