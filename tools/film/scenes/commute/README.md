# Commute: a film template

Commute is a photoreal ride inside a Japanese commuter train. The city slides past on a viaduct,
sun patches sweep across the green bench seats, and a chubby teal penguin in a suit dozes on the
end seat. It renders as a seamless 48 s loop.

To make your own version, copy `commute.json`, change the values below, and run it with
`tools/film/run.py`. Everything not listed here is in the Python modules (`carriage.py`,
`city.py`, `penguin.py`, `posters.py`, `scene.py`).

## Settings you can change in the spec (no code)

| key | default | what it does |
|---|---|---|
| `variant` / `--variant` | `day` | `day` (clear, cumulus), `golden` (low warm sun), `night` (lit city, cabin lamps), `rain` (overcast, drops on the glass) |
| `loop.seconds`, `loop.fps` | 48, 24 | Loop length. The scenery strip is always 650 m per loop, so a shorter loop means a faster train. Keep `seconds × fps` a whole number. |
| `params.penguin_color` | `[0.0, 0.42, 0.56]` | Feather colour (linear RGB). Try `[0.55, 0.05, 0.08]` for red or `[0.08, 0.30, 0.10]` for green. |
| `params.penguin` | `true` | `false` leaves the end seat empty |
| `params.sway` | 1.0 | Carriage sway and roll (0 is perfectly steady; 2 is a rough line) |
| `params.cabin` | 1.0 | Brightness of the cabin lamps |
| `params.sun_side_height` | 0.55 | How tall the scenery on the sun side is. It is only ever seen in shadows and reflections. Lower values let more low sun in. |
| `params.lighting.<variant>` | — | Any lighting-preset key: `sun_elev`, `sun_az`, `sun_strength`, `sun_color`, `hdri`, `hdri_rot`, `hdri_strength`, `exposure`. For example, `{"day": {"sun_elev": 25}}` |
| `params.seed` | 7 | Random seed for the city layout |
| `look` | bloom + halation + vignette + preview grain | The film look (`dsfilm.post`). Omit the block, or pass `--no-post`, for the raw render. |
| `render` | Cycles, 1600×1000, 384 samples | Engine, resolution and samples |
| `stills[]` | — | `name`, `camera`, `frame`, `variant`, and optionally `compare: true`, which also writes `-nopost.png` |

There are three cameras:

- `wide`: seated opposite, the bench and windows with the penguin on the right
- `close`: 50 mm, a shallow-focus portrait
- `aisle`: standing, looking down the car

## Settings that need a small code edit

| What | Where |
|---|---|
| Seat moquette colour | `carriage.py`, the `seat_kw` tint |
| Tie colour | `penguin.py`, the `TieSilk` material |
| Suit | `penguin.py`, the `SuitWool` tint |
| Poster artwork and texts | `posters.py` (all fictional brands; regenerate with `python3 -I posters.py`) |
| Facade colours | `city.py`, `HOUSE_WALLS` / `APARTMENT_WALLS` |
| Building heights and density | `city.py`, the row tables |
| The dozing timeline (when he jerks awake, the heavy nod) | `scene.py`, `dozing()` |
| Camera positions and lenses | `scene.py`, `_cameras()` |

## Costs (M5 Pro)

| What | Time |
|---|---|
| Build | about 25 s |
| Cycles still, 1600×1000, 384 samples | about 1 min |
| Build sequence (clay, materials, ray-traced, graded) | about 3 min |
| Loop | Not measured yet. Time 24 frames before committing to all 1152. |

## Assets

The template uses CC0 assets only; they are listed in `assets.json` and fetched automatically.
Every download is logged with its source page in `~/Library/Caches/DotStudio-film/LICENSES.tsv`.
