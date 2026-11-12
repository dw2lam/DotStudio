# DotStudio App Settings

How DotStudio's settings fit together, for an AI that changes them with tools. A **style** is a name, a stack of effects and a frame rate. The **screensaver** plays a lineup of styles (one, a rotation, an optional night style, or a style per display) from `library.json`. The **live wallpaper** is the app drawing a style behind the desktop icons, configured in `wallpaper.json`, and only runs while the DotStudio app runs. Music, weather and the real sun are layers and inputs over whatever style plays. Per-scene params are in `read_guide("settings/index")`; the custom shader API is in `read_guide("engines/metal")`.

## Files

All in `~/Library/Application Support/DotStudio/` (the tools read and write them for you; never hand-edit while the app runs):

- `library.json`: the styles, the shared source, the screensaver lineup, music settings, per-display screensaver styles. The sandboxed screensaver reads it.
- `wallpaper.json`: live wallpaper settings (app only).
- `weather.json`: the live weather reading, written by the app. Never put weather in `library.json`.
- `media/`: the user's photos, videos and logo images.
- `guides/*.md`: the user's own guides (brand guides). Read them with `list_guides` / `read_guide`.
- `ai-settings.json`: what the user allows the AI to do. If playback changes are not allowed, you can still create and edit styles, but `set_screensaver` and `set_wallpaper` are refused: tell the user and stop.

## Styles

A style (`Preset`) is `name`, `effects` (an ordered stack) and `fps`.

- **Scene**: the first enabled effect is a generator (`list_scenes`), so the style draws itself and ignores the source. Effects after it post-process it (Black Hole is `blackhole` followed by `bloom`).
- **Look**: no scene first; the effects restyle the one shared source (`Library.source`): the built-in photo slideshow (default), the user's own photos, an image, a video or a gradient. The source is global: changing it changes every Look. A Look on its own generates nothing; what it shows depends on the source.
- `fps`: 30 by default; 24 for Bloom and Penguin; see `power`.
- Each effect: `kind` (the effect's id, e.g. `flowerBloom`, `oceanHorizon`, `liquidChrome`, `meadow`, `standbyClock`), `params` (key to number), `colorA` / `colorB` (optional; missing means the kind's defaults), `enabled`.
- Params are numbers. Sliders take their range (`describe_scene` lists min, max, default). Menus take a 0-based index (`flower` 0 = Blue Poppy, 1 = Baby's Breath, 2 = White Anemone). Toggles take 0 or 1. Out-of-range or non-finite values are clamped to the range on load (`SafeNumbers`); a missing param uses its default; an unknown key is kept but ignored.
- Colours are sRGB floats 0-1: `{"r":0.16,"g":0.45,"b":0.86,"a":1}`. What colorA and colorB mean depends on the kind (Bloom: Sky, Petals; Ocean Horizon: Deep Water, Sunlight; Meadow: Grass, Sunlight). `describe_scene` gives the labels.
- Bounce and Penguin also carry `logoKind` (`builtIn`, `text`, `image`), `logoText`, `logoFile` (a file in `media/`). Leave them out unless the user asks for their own logo or character.

### What create_style takes

```json
{
  "name": "Blue Bloom",
  "fps": 24,
  "effects": [
    {
      "kind": "flowerBloom",
      "params": {"flower": 0, "render": 0, "cell": 11, "breeze": 0.5, "gradient": 1,
                 "glow": 0.6, "captions": 0, "size": 1},
      "colorA": {"r": 0.129, "g": 0.278, "b": 0.522, "a": 1},
      "colorB": {"r": 0.16, "g": 0.45, "b": 0.86, "a": 1},
      "enabled": true
    }
  ]
}
```

### How it is stored

The same style in `library.json` (the tools add the ids; `id`, `kind`, `enabled` and `params` are required on disk, colours are optional):

```json
{
  "id": "6F1C2A4E-8B3D-4F0A-9C55-2E7D1B9A0C11",
  "name": "Blue Bloom",
  "effects": [
    {
      "id": "A9D3E5F7-1B2C-4D6E-8F90-1A2B3C4D5E6F",
      "kind": "flowerBloom",
      "enabled": true,
      "params": {"breeze": 0.5, "captions": 0, "cell": 11, "flower": 0, "glow": 0.6,
                 "gradient": 1, "render": 0, "size": 1},
      "colorA": {"r": 0.129, "g": 0.278, "b": 0.522, "a": 1},
      "colorB": {"r": 0.16, "g": 0.45, "b": 0.86, "a": 1}
    }
  ],
  "fps": 24
}
```

A two-effect scene, Black Hole with a bloom pass:

```json
{"name": "Black Hole", "fps": 30, "effects": [
  {"kind": "blackhole", "params": {"angle": 0.22, "mass": 0.4, "brightness": 5, "speed": 1,
   "stars": 1, "rot": -8.7, "disk": 1}, "colorA": {"r": 0, "g": 0, "b": 0, "a": 1}, "enabled": true},
  {"kind": "bloom", "params": {"thr": 0.4, "inten": 1.0, "rad": 4.5}, "enabled": true}
]}
```

Prefer `duplicate_style` on a built-in and `update_style` on the copy when the user wants a variation: it starts from tuned values. Do not edit the built-ins in place unless asked. Retired kinds (`dialClock`, `pipes`, `demoTunnel`, `fireflies`, `fisheye`, `swirl`, `ripple`, `toon`, `truchet`, `voronoi`, `blockify`, `dots`, `nowPlaying`) still render for old libraries but must not be used for new styles.

## The screensaver lineup

Stored in `library.json`; `set_screensaver` writes it in the app's canonical form:

- **One style**: `activeID` = the style, `rotation.enabled` = false.
- **Playlist** (2 or more): `rotation.enabled` = true, `rotation.presetIDs` = the styles in library order, `intervalMinutes` (the app offers 1, 5, 15, 30, 60; minimum 0.25; default 5), `shuffle` (default false; a seeded shuffle, so displays agree and nothing repeats until all have shown), `transitionSeconds` (crossfade, 0-3, default 1.5).
- **Night style** (optional): `schedule.enabled` = true, `schedule.nightPresetID` = one style that plays after sunset (sun below -0.833 degrees at the library's location), `dayPresetID` = null so the playlist plays by day.
- Precedence, per display: the display's own style, then the night style (after sunset), then the rotation, then `activeID`.

## Per-display styles

With more than one display, each display can play a style of its own instead of the lineup.

- Screensaver: `Library.displayStyles`, keyed by the display's stable key (from `list_displays`): `{"presetID": ..., "name": "LG HDR 4K", "seen": ...}`.
- Wallpaper: `WallpaperSettings.displayStyles` in `wallpaper.json`, same shape.
- One style per display: no per-display playlists or night styles. A pin to a deleted style is ignored (that display plays the lineup). Pins for up to 8 disconnected displays are kept.
- With one display, do not pin: just set the lineup.

## Live wallpaper

The app draws the style in a desktop-level window on every display and Space, below the icons. It runs only while DotStudio runs (in the menu bar when its window is closed); suggest Open at login if the user wants it always. `wallpaper.json`:

- `enabled`, `presetID` (the shared pick).
- `followsScreensaver` ("Match Screensaver" / SYNC): show exactly what the screensaver would show on each display, rotation and night style included, on the shared wall-clock time base (`Library.syncTimeBase`), so the screensaver starts on the very frame the desktop was showing. While on, `presetID` and the wallpaper's own display pins are kept but unused.
- `frameRate`: `30` (Balanced, default) or `120` (Smooth, the display's own refresh).
- `quality`: `"full"`, `"balanced"` (default, 1.5 px per point), `"efficient"` (1 px per point).
- `batteryMode`: `"efficient"` (default: 20 fps at reduced resolution), `"full"` (at most 30 fps), `"still"`.
- `lockScreen`: opt-in; a still of the wallpaper becomes the lock and login screen picture.
- `displayStyles`: per-display wallpaper styles.

Low Power Mode and a hot Mac always hold a still frame; the wallpaper pauses entirely while covered, locked, asleep or under the screensaver. See `power`.

## Screensaver quality

`Library.renderScale`: Full = 1 (stored as absent), Balanced = 0.75, Efficient = 0.5. On battery the screensaver caps itself at 24 fps and 0.6 scale, in Low Power Mode at 15 fps and 0.5. Leave Quality to the user unless they ask about battery or heat.

## Music

Spotify or Apple Music over any style; music never replaces the style. `Library.music` (all optional, defaults shown):

- `display`: `"off"`, `"corner"` (default), `"fullScreen"`.
- Corner: `cardCorner` (`"bottomLeft"` default, `"bottomRight"`, `"topLeft"`, `"topRight"`), `cardSize` (`"small"`, `"medium"` default, `"large"`). Artwork, title, artist and a thin bar straight on the scene over a feathered scrim: no box.
- Full Screen: `fullLayout` (`"album"` default, `"stage"`, `"cover"`), `fullBackdrop` (`"albumArt"` = the artwork's living colour fields, default; `"screensaver"` = the style blurred and dimmed; ignored by Cover).
- `cardOnWallpaper`: also show it on the live wallpaper (default false).
- `lingerMinutes`: how long a paused song stays (default 5); then it fades back to the plain style.
- `source`: `"auto"`, `"spotify"`, `"music"`.

When you design a style, leave room for the corner card (bottom left by default): no important detail or static bright element there. Check with `preview_style` and the music card on.

## Live weather and the sun

- **Follow the Sun** (`live` = 1 on Ocean Horizon / Golden Hour, Meadow, Shallows, Pleats, Dichroic, Sand Garden; `follow` on Window Light): the real sun, moon and stars at the library's location (`locationLat` / `locationLon`). Off: a fixed time (`sun` height on Ocean Horizon, `hour` on Meadow). `lapse` (Time Lapse, minutes per simulated day; 0 = real time) runs either clock forward.
- **Weather** (`weather` menu on Ocean Horizon, Shallows, Meadow): 0 = Live, then Clear, Partly Cloudy, Overcast, Fog, Rain, Storm, Snow. Live needs Settings > Weather > Live weather on in the app; the app fetches Open-Meteo every 20 minutes for the approximate location (about 10 km) and stale readings fade back to clear. Weather costs 60-75 % more GPU on Meadow.
- Clocks follow the local time; StandBy's Night Mode and the night style follow the real sunset.

## Custom and film scenes

- Custom scenes (`create_custom_scene`) are small shader packages in `<store>/scenes/`; styles use them as `{"kind": "custom", "scene": "<id>"}` like any scene. They need DotStudio's scene-engine update.
- Film scenes are photoreal video loops rendered in Blender (`read_guide engines/film`). They are BIG: Blender itself (about 1 GB, installed by the user), the film engine pack, about a minute per approval still, hours per loop, and 150–250 MB of video per variant (0.6–1 GB for all four). Always tell the user the time and disk cost before rendering, render only the variants they want, and never start a render they haven't agreed to. Playback is cheap (hardware video decode), so a finished film scene suits the live wallpaper well.

## Sharing

A `.dotstudiopreset` file is JSON (Shared/AI/PresetShare.swift, `PresetExport`):

```json
{"formatVersion": 1, "preset": { ...a stored style as above... }, "source": { ...only for a gradient source... }}
```

`export_style` writes one; `import_style` reads one, gives the style and its effects fresh ids, clamps every param, skips effects this build does not know (a style made only of unknown effects cannot import), and adopts a gradient source only if the library's source is a gradient. Photos, videos and logo images do not travel with a share file.

## Before changing what plays

- Create and preview first; change the screensaver or wallpaper only when the user asked for it.
- Say what you changed in one line ("Blue Bloom is now your screensaver; the night style is still Night Sky").
- Keep the user's existing lineup unless asked: adding a style to a playlist is not the same as replacing it.
