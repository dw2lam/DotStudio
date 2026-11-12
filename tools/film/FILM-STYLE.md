# Design: a "Film" style in DotStudio (not built yet)

This is a design for a style that plays the rendered loops (Commute Day, Golden, Night and Rain)
full screen in both the saver and the wallpaper. It picks a variant by local time and weather,
crossfades between variants, and downloads its clips on demand instead of bundling them.

## What exists today (findings)

**Video plays through the global source only.** `Library.source` is the single source for every
Look. A Look over `SourceSpec(kind: .video, fillMode: 1)` takes the path
`MetalRenderer.loadMedia` → `VideoSource` → the source pass (Fill = cover). Scenes skip the source
pass, so a scene can't show a video. There is also no per-style media.

**Bug: `VideoSource` never delivered a frame.** It attached its `AVPlayerItemVideoOutput` to the
template item it gave `AVPlayerLooper`. The looper only plays copies of that item, and an output
serves only the item it was added to. It also set `actionAtItemEnd = .none`, which stops the
looper's queue from advancing.

`tools/gallery --video` showed the result: 0 of 20 rendered frames matched the clip, and the
renderer silently drew its gradient fallback instead. That fallback drifts, so a "frames are
changing" check passes anyway.

The fix on this branch gives each looping copy its own output and keeps the `CVMetalTexture`
alive. It has not been verified yet. Verify it with:

```sh
DOTSTUDIO_STORE_DIR=$(mktemp -d) tools/gallery/render.sh OUT --size 1280x800 \
  --video clip.mov --videofor 10
```

The run should end in `PLAYING AND LOOPING`.

**Also missing:**

- **No sync:** clips play on AVPlayer's own clock, so they ignore `TimeBase.wallClock`. The saver
  and the wallpaper drift apart.
- **No playability check on import.**
- **No downloader:** there is no media downloader or checksum cache. Sparkle handles app updates
  only.
- **Weather:** `weather.json` from Open-Meteo, read through `WeatherLink`, is available to any
  renderer.
- **Time of day:** `MetalRenderer.solarElevation` / `liveSky` are available too.

## Proposal

### 1. A "Film" scene kind, not a global source

Add `EffectKind.film`, registered like the other scenes in `SceneCatalog`, with these params:

- `film` (menu: Commute)
- `variant` (Auto, Day, Golden, Night, Rain)
- `follow` (the real sun and weather when Auto)

It takes the scene route, so it needs no source pass. It brings its own textures, following
Bounce's slot-6 pattern: a `FilmPlayer` (one `VideoSource` per visible variant, cached per renderer
like `CommutePassenger`) binds the current frame. A tiny `fx_scene_film` shader draws it
aspect-filled and mixes the two textures for crossfades. That gives styles their own clips without
touching `Library.source`, and rotation and per-display styles keep working.

### 2. Choosing the variant (pure function of time + weather)

- **Night:** sun elevation below −4°.
- **Golden:** elevation from −4° to 10°, or within 75 minutes of sunrise or sunset.
- **Rain:** weather is rain, drizzle or thunderstorm, and the sun is up.
- **Day:** otherwise.

Snow and fog fall back to Rain until those variants are rendered.

All inputs are shared with the renderers that already exist (`solarElevation`, `WeatherLink`), so
the saver and the wallpaper agree.

### 3. Crossfades

When the chosen variant changes, crossfade over 6 s. Both clips play the same loop phase, so the
penguin and the scenery line up and only the light changes. The phase is wall-clock time mod 48 s
(`AVPlayer.seek` on start, then `setRate(1, time:atHostTime:)` against the host clock). That also
fixes saver/wallpaper sync.

Only the outgoing and incoming decoders run, and one decoder runs at rest. HEVC 10-bit 2560×1600
decodes in hardware, so memory is about 2 × 4 IOSurfaces.

### 4. On-demand clips (not bundled)

The manifest is `film-manifest.json`, published as a GitHub release asset on a `film-assets`
release separate from app releases. For each film and variant it lists the `url`, `sha256`,
`bytes`, `duration`, `resolution`, `version` and `minAppVersion`. It is fetched at most daily.

| Part | Design |
|---|---|
| Downloader | `FilmLibrary` in App/: a background `URLSession` downloads to `media/film/<film>-<variant>-<version>.mov.part`, verifies SHA-256 streaming, then renames atomically. Sizes are about 80–200 MB each. |
| Who downloads | Only the app downloads. The saver (sandboxed, read-only) just reads `media/film/`. |
| Missing files | If the chosen variant isn't there, the nearest downloaded one plays (Day first). If none are, the scene shows the last poster still that ships with the app (a small JPEG per variant, about 300 KB). |
| Library UI | The style card shows a download state, with "Download (180 MB)" and progress. "Auto" downloads all four variants. |
| Housekeeping | A variant not shown in 30 days is evicted. Old versions are removed after the new one verifies. |
| Integrity | Only files whose SHA-256 matches the manifest are ever played. The manifest is fetched over HTTPS from the repo's own releases, and the check rejects any file that doesn't match. |

### 5. Encoding contract (from `dsfilm.encode`)

- **Codec:** HEVC Main10 with the `hvc1` tag, 24 fps, frames 1..N (frame N+1 equals frame 1, so
  `AVPlayerLooper` loops seamlessly).
- **Format:** 2560×1600 (16:10). Fill crops it for other aspect ratios.
- **Bitrate:** about 25–40 Mb/s at `q:v 62`. That makes 48 s about 150–240 MB.
- **Preview:** an H.264 1280×800 version for the gallery and web.

### Phases

| Phase | Work |
|---|---|
| 1 | Verify the VideoSource fix |
| 2 | FilmPlayer and `.film` scene with one bundled test clip in DEBUG |
| 3 | Variant choice and crossfade |
| 4 | FilmLibrary downloads, manifest and UI |
| 5 | Wall-clock phase sync |
