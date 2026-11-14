# Signals and When rules

Signals are live values DotStudio watches — the weather, the sun, the time, the battery, music, and the user's own HTTPS-JSON or file values. When rules use them to choose what plays: "when it snows, play Snowfall". Custom Scenes can also follow them live through their **inputs**: "the air quality thickens the haze". Read this before create_signal, set_rule or bind_signal.

## What there is

- **Built-in signals** (no new network): `weather.condition` (clear, partlyCloudy, cloudy, fog, drizzle, rain, heavyRain, thunderstorm, snow, sleet), `weather.precip` / `snow` / `cloud` / `fog` / `storm` (0…1), `weather.wind` (m/s), `weather.tempC` (°C), `sun.elevation` (degrees), `sun.isDay`, `time.hour` (0–24), `time.weekday` (1 = Sunday … 7), `power.battery` (%), `power.onAC`, `music.playing`.
- **Web signals**: one value out of an https JSON endpoint — `url` + `pointer` (RFC 6901, e.g. `/data/aqi`), `valueType` number / bool / string, optional `scale` and `offset`, `unit`, `range`. Optional `{lat}` / `{lon}` in the URL get the weather's location, rounded to about 10 km.
- **File signals**: a file in DotStudio's `signal-files` folder (next to its library), JSON + `pointer` or plain text with one number or word. Anything that can write a file can feed one: a Shortcut ("Save File"), cron, launchd, a script on a Home Assistant box over SSH.
- **When rules**: `when` = `{all: [tests], any: [tests], timeOfDay: day|night}`, a test = `{signal, op, value | values}` (ops: gt, gte, lt, lte for numbers; eq, neq for anything; in with `values`; between with `values: [low, high]`); `play` = one style, or up to 8 that rotate with the playlist's interval.
- **Scene inputs**: a Custom Scene package declares up to 8 `inputs` (`{key, label, range: [lo, hi], default, unit?, suggest?}`, read as `ctx.input[i]`; read_guide engines/metal); a **style** connects each to a signal — `bind_signal {style, input, signal}` or inline in create_style / update_style effects: `"inputs": {"aqi": {"signal": "Air quality"}}`. The scene gets the value in the input's units, clamped to its range and eased over ~20 s; unconnected, missing or stale, it gets the input's `default` (easing there as the reading goes stale). Numbers and yes/no signals only (yes = 1, no = 0). A package only declares inputs: sharing a style or a package can never make anyone's Mac fetch anything.

## Keys — the one rule that matters

- **Never put an API key in a URL.** DotStudio refuses URLs whose query has a key-like parameter (key, apikey, api_key, token, access_token, appid, secret, password, sig, signature).
- **Never ask the user to paste a key into the chat.** Set `auth` `{in: "header" | "query", name: "X-API-Key"}` on the signal and tell the user: *paste the key in DotStudio ▸ Settings ▸ Signals ▸ ⟨name⟩*. It goes to the macOS Keychain. You can never read or set it, and no tool returns it.
- A signal with a key can only be tested (test_signal) while DotStudio runs: the app holds the key.

## Limits and privacy

- https only, GET only, no cookies, no cache; 10 s timeout, 256 KB at most, 3 redirects (each checked again).
- A web signal is fetched at most every 5 minutes (default 15, ±10 %), twice as slowly in Low Power Mode, and only while an enabled When rule tests it or a style's scene input is bound to it; about 60 fetches an hour in all. Failures back off; 429/503 Retry-After is honoured.
- Signals an assistant makes can't reach this Mac or the local network (localhost, *.local, private, loopback, link-local and ULA addresses), whether the URL names the address or a host name that resolves to one: every fetch and redirect checks where the name points (a test reports "can't reach this Mac or the local network"). For a local service, the user adds the signal themselves in Settings, or a script writes a file signal.
- At most 16 signals. Nothing leaves the Mac beyond the URL you give (plus the rounded location only with `{lat}` / `{lon}`). No telemetry.
- test_signal shows an **outline** (pointer → value, strings cut to 40 characters), never the raw body or headers: pick `pointer` from it.

## What plays

A display's own style > the active When rule > the night style > the rotation > the active style. The running app is the only one that decides (the first enabled rule that matches, in list order): a numeric threshold lets go only after the value crosses back by 5 % of the signal's range, and a rule that starts stays at least `hold_minutes` (default 10). It writes its decision as a lease that every display, the wallpaper (when it matches the screensaver) and these tools read; if DotStudio quits, the lease runs out within 30 minutes and the normal lineup plays. A stale or missing value counts as false. Changing rules changes what plays: set_rule and delete_rule need "Let AI change what plays"; signals need "Let AI add live data signals" (Settings ▸ AI).

## Recipes

1. **Snowing → a snowy style.** `set_rule {name: "Snow day", when: {all: [{signal: "weather.condition", op: "in", values: ["snow", "sleet"]}]}, play: ["Snowfall"]}`. The weather is already watched; nothing else to add.
2. **Battery low → a light style.** `set_rule {name: "Low battery", when: {all: [{signal: "power.battery", op: "lt", value: 20}, {signal: "power.onAC", op: "eq", value: false}]}, play: ["Paper"]}` — pick a style that benchmark_style shows is cheap.
3. **Air quality with the location.** test_signal `{draft: {url: "https://air-quality-api.open-meteo.com/v1/air-quality?latitude={lat}&longitude={lon}&current=us_aqi", pointer: "/current/us_aqi"}}` → create_signal `{name: "Air quality", url: …, pointer: "/current/us_aqi", unit: "AQI", range: [0, 300]}` → set_rule `{when: {all: [{signal: "Air quality", op: "gt", value: 150}]}, play: ["Haze"]}`. A provider that needs a key: `auth`, and the user pastes it in Settings.
4. **Home Assistant or any script.** The user (or their script) writes `office.json` into `signal-files` — e.g. `{"temp": 23.5}` — and you add `create_signal {name: "Office temp", kind: "file", file: "office.json", pointer: "/temp", unit: "°C"}`. From a shell: `"/Applications/DotStudio.app/Contents/MacOS/dotstudio-mcp" --set-signal office=23.5` writes `signal-files/office.txt` atomically (plain text, one value; pair it with `file: "office.txt"`).

## Binding recipes (scene inputs)

5. **Air quality thickens a haze.** Make the signal (recipe 3), then a scene that declares it — the metal engine's `examples/haze` declares `{"key": "aqi", "label": "Air quality", "range": [0, 300], "default": 0, "unit": "AQI"}` — and connect it: `bind_signal {style: "Haze", input: "aqi", signal: "Air quality"}`. Check both ends before showing the user: `preview_style {style: "Haze", inputs: {"aqi": 0}}` and `{"aqi": 250}` (pins the value for that preview only).
6. **Temperature warms a palette.** A scene input `{"key": "warm", "range": [-10, 35], "default": 15, "unit": "°C", "suggest": "weather.tempC"}` mixing colour A toward colour B with `saturate((ctx.input[0] + 10.0) / 45.0)`; `bind_signal {…, input: "warm", signal: "weather.tempC"}`. The weather is fetched only while something uses it.
7. **Rain quickens the motion.** Bind an input `rain` (`range [0, 1]`) to `weather.precip` and scale a drift speed by `1 + ctx.input[0]` — integrate nothing per frame; just scale periodic motion gently.
8. **Battery dims the scene.** Bind `power.battery` (`range [0, 100]`, `default 100`) and lower brightness below 30 %.
9. **Disconnect**: `bind_signal {…, signal: null}` — the input reads its default again.

## Burn-in

Signals choose what plays, and steer a scene's colour, density or motion through its inputs. Never turn one into a static number or readout on screen: values change slowly, and a fixed readout is a burn-in risk (read_guide burn-in). validate_custom_scene warns when an input seems to drive digits or a readout.
