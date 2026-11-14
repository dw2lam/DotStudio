# Signals, scene inputs and When rules (1.6)

Status: approved by the owner 2026-11-14 (phases 1 + 2). Names: **Signals**, **When rules**,
scene **inputs**. Owner's ask: "If someone wants to make a custom field that pulls from
something, that should also be available in the MCP … we're pulling weather as a custom
condition … other people should be able to add their own conditional options."

## 0. How weather flows today (the pattern to copy)

1. Fetch (app only): App/Weather/WeatherService.swift (`WeatherService.shared`, attach at
   App/DotStudioApp.swift:65, start :178). Fetches only while `isNeeded` (enabled && a preset
   follows live weather). Open-Meteo every 20 min, location rounded ~0.1°, backoff 60/120/300/600/
   1200 s. Writes `<store>/weather.json` atomically. Live data NEVER goes in library.json (the saver
   re-applies the playing style when library.json's mtime changes).
2. Store: SharedStore.sharedDir; the sandboxed legacyScreenSaver host reads it read-only. The
   saver never fetches.
3. Read: each MetalRenderer owns a WeatherLink → WeatherFeed.poll() (FileStamp, ≤ every 5 s),
   eased over 90 s; stale readings fade to .clear (WeatherState.freshness: 3 h + 30 min fade).
4. Shaders: built-ins via WeatherLink.fill (u.weather/2/3); Custom Scenes via
   CustomSceneLink.fillStatic → u.scene[4…8] → Runtime.h ds_context → DSContext. FXUniforms.scene
   has 16 float4 (Shared/EffectUniforms.h:66); scene[9…15] were free — CHECK after the film-engine
   merge (it appends DSWeather fields: storm, gust, condition) before claiming slots.
5. What plays: Shared/Playback.swift (pure function of Library): display pin > day/night
   ScheduleSpec > RotationSpec > activeID. Callers: Saver/DotSaverView.reload() (~1 Hz),
   Destinations.nowPlayingID, WallpaperPick.shared/preset (App/WallpaperPower.swift),
   App/DisplayStyles.swift, MCP get_started/list_displays, Library.screensaverLineup.
6. MCP edits: MCP/LibraryAccess.perform (StoreLock) → BridgeRequest to the running app
   (App/AIBridgeHost.handle: AppModel + AINoticePanel with Undo) or LibraryExecutor.run offline.
   AISettings.allowPlaybackChanges gates playback changes in both paths. Saver excludes Shared/AI/**.

## 1. Names

`Source` already means the photo/gradient canvas; "Feed" means a reader of an app-written JSON.
- **Signal** — a live value DotStudio watches. UI "Signals"; MCP `list_signals`…
- **Input** — what a Custom Scene declares (`"inputs"`), read as `ctx.input[i]`.
- **When rule** — "When ⟨condition⟩, play ⟨style⟩". UI "When…" on the Screensaver card; MCP `set_rule`.
Chain: Signal → (binding) → Input or Rule. Packages declare inputs, styles bind them; a shared
style/package can never make a Mac fetch anything.

## 2. Signal kinds and safety

Built-ins (no new network), namespaced ids:
| id | type | from |
|---|---|---|
| weather.condition | string (clear, partlyCloudy, cloudy, fog, drizzle, rain, heavyRain, thunderstorm, snow, sleet) | WeatherService.reading |
| weather.precip / snow / cloud / fog / storm | 0…1 | WeatherMix(reading) |
| weather.wind | m/s | WeatherState |
| weather.tempC | °C | NEW: Open-Meteo `temperature_2m` + WeatherState.temperature (optional, additive) |
| sun.elevation, sun.isDay | deg / bool | CustomSceneLink.sun(at:location:) |
| time.hour, time.weekday | 0–24 / 1–7 | clock |
| power.battery, power.onAC | % / bool | App/WallpaperPower.swift power state + IOPS |
| music.playing | bool | MusicFeedHub |
WeatherService.isNeeded becomes: enabled && (a preset follows live || an enabled rule/binding
references weather.*).

**web** (user/AI): HTTPS JSON. Fields url, pointer (RFC 6901), valueType number|bool|string,
scale, offset, unit, range [lo,hi], default, pollMinutes. https only; GET only; no body; ephemeral
URLSession (no cookies/cache); UA `DotStudio/<ver>`; timeout 10 s; 256 KB cap; ≤ 3 redirects each
re-checked; poll ≥ 5 min (default 15) ±10 % jitter; Retry-After on 429/503; backoff like
WeatherService capped at the interval; ×2 interval in Low Power Mode; ≤ 16 user signals, ≈ 60
fetches/hour total; fetch only while needed (enabled AND referenced by an enabled rule/binding).
Optional `{lat}`/`{lon}` placeholders (opt-in per URL) filled with the weather's rounded location.
Auth: `auth {in: header|query, name}` — the VALUE lives only in the macOS Keychain (generic
password, service com.davidlam.DotStudio.signal, account = signal UUID), never in any file, bridge
message or MCP output. Refuse URLs whose query has key-like params (key|apikey|api_key|token|
access_token|appid|secret|password|sig|signature) → point to auth.
AI-created signals: refuse localhost, *.local, loopback/private/link-local/ULA IP literals.

**file** (user/AI): a file in `<store>/signal-files/` only (realpath must stay inside). JSON +
pointer, or plain text with one number/word. 64 KB cap, stat every 10 s while needed. Covers
Shortcuts ("Save File"), cron, launchd, Home Assistant via SSH. `dotstudio-mcp --set-signal
name=value` writes the file atomically (phase 2).

Not now: shell commands (never), Focus, Calendar (phase 4), HomeKit.

Staleness: staleAfter default max(3 × poll, 30 min); freshness curve like WeatherState (1 → 0
over 30 min); inputs ease to `default` as freshness drops; rules treat stale/missing as FALSE.
Privacy: Settings shows host, last fetch, bytes, value; nothing sent beyond the given URL (+ the
rounded location only with placeholders); no telemetry; AI-created signals marked createdBy "ai"
with a notice + Undo.

## 3. Data model and files

library.json (definitions; additive, tolerant `try?` decode like displayStyles):
```
Library.signals: [Signal]?   // id UUID, name, kind web|file, url|file, pointer, valueType, scale, offset,
                             // unit, range, default, pollMinutes, auth {in,name}? (no value), enabled, createdBy
Library.rules:   [PlayRule]? // id, name, enabled, when: Condition, play: [UUID] (one style or a rotating set),
                             // holdMinutes (default 10)
EffectInstance.inputs: [String: InputBinding]?   // phase 2: manifest input key → {signal: "<uuid>|weather.tempC"}
```
Condition = {all|any: [Clause]}, Clause = {signal, op: gt|gte|lt|lte|eq|neq|in|between,
value|values}, optional timeOfDay: day|night (Playback.isNight).

`<store>/signal-values.json` (NEW; app writes; every host reads; never in library.json):
```
{ "version":1, "writtenAt": t,
  "values": { "<id>": {"v": 42.0, "s": "snow"?, "at": t, "error": "HTTP 503"?} },
  "rule":   { "id": "<ruleID>"|null, "since": t, "validUntil": t+30min } }
```
The app is the ONLY rule evaluator (hysteresis + hold) and writes the decision as a lease
(validUntil, refreshed every 10 min) so every host (saver per display, wallpaper, gallery, MCP)
agrees; a quit app → lease expires → normal lineup.
Hysteresis: numeric thresholds release only after crossing back by 5 % of the signal's range;
an active rule stays ≥ holdMinutes; first matching enabled rule in list order wins.

## 4. Scene inputs (phase 2)

Manifest `"inputs": [{"key":"aqi","label":"Air quality","range":[0,300],"default":0,"unit":"AQI",
"suggest":"weather.tempC"?}]`, ≤ 8, parsed in CustomSceneManifest, validated in the compiler.
DSContext gains `float input[8]` (eased 20 s, clamped, declared units; default when unbound/stale)
and `float inputLive[8]` (freshness 0…1). Runtime.h reads them from free u.scene slots. Cells
shares DotStudio.h. A SignalLink per MetalRenderer (sibling of weatherLink) polls
signal-values.json every 5 s. Style binding EffectInstance.inputs[key] = {signal}; unbound →
default, inputLive 0. Bump the metal engine version / minApp.
Phase 3 (later): drive built-in sliders from a signal (sliders only, deny-list phase-integrated
params like speed/lapse).

## 5. Playback order

display pin > **active When rule** > night schedule > rotation > activeID. The lineup (pool,
screensaverLineup) is unchanged — rules are an overlay. `effectivePreset(in:now:display:live:)`
takes a `SignalState?`, NON-defaulted so the compiler finds every call site. If live.rule is
present, unexpired, enabled and its styles exist → those (rotating with the rotation interval and
shuffledIndex), else today's path. Library.removePreset prunes rule targets (pruneRules()).
Wallpaper "Same as Screensaver" follows rules via WallpaperPick. Independent-wallpaper rules and
per-display rule scope: phase 2.

## 6. MCP (MCP/ToolsSignals.swift, in Toolbox.all; network tools openWorld)

| tool | gate | notes |
|---|---|---|
| list_signals | read-only | built-ins + user's: id, name, kind, host/file, value, unit, freshness, last error, referencedBy |
| test_signal | read-only, openWorld | {id} or an unsaved draft; fetch once; value, status, ms, bytes + an OUTLINE (≤ 60 pointer → number/bool/≤40-char string leaves) — never the raw body/headers. Via the app when running (it has the Keychain); offline only without auth. |
| create_signal / update_signal | AISettings.allowSignals (default on) | SignalPolicy.validate; with auth → needsSecret + "Ask the user to paste the key in DotStudio ▸ Settings ▸ Signals ▸ ⟨name⟩". AI never sets/reads secrets. Notice + Undo. |
| delete_signal | allowSignals | refuses while referenced unless force (unbinds) |
| list_rules | read-only | + activeNow from signal-values.json |
| set_rule / delete_rule | allowPlaybackChanges | same refusal as LibraryExecutor.playbackOff; validates signal, op vs type, styles exist; Undo snapshot includes rules |
| bind_signal (phase 2) | none | {style, effect_index?, input, signal}; also inline in create/update_style effects |
| preview_style (phase 2) | none | `inputs: {"aqi": 180}` override like `weather` |
get_started / readFirst mention the signals guide; list_displays and styleJSON roles add
"screensaver when ⟨rule⟩". New Guides/signals.md (what/limits/privacy — never put a key in the
URL, never ask the user to paste a key into chat — precedence, recipes: AQI with {lat}/{lon},
Home Assistant/script via signal-files, "snowing → Snowfall", "battery < 20 % → a light style";
burn-in: inputs modulate colour/motion, never static numeric readouts). Update docs/ai/CONTRACT.md
and the metal engine guide for inputs.

## 7. UI

- Settings ▸ Signals (App/SignalsSettingsSection.swift, after WeatherSettingsSection in
  SettingsView): "Built in: weather, sun, time, battery, music"; a row per user signal (icon,
  name, host/file, value + unit, "3 min ago", status dot, enable toggle, AI badge); Add Signal…
  sheet: kind, URL or file (Reveal folder), Test (outline; click a leaf → pointer), type/scale/unit,
  range, default, poll, API key SecureField → Keychain (+ header/query name).
- Screensaver card (App/DestinationCards.swift): a "When…" row of rule chips ("❄ Snowing →
  Snowfall"); sentence editor [Signal ▾] [is above/below/is/is one of ▾] [value] [any time/by
  day/only at night] → play [Style ▾]; the Day/Night badge gets a third state "When: Snowing".
- Inspector (phase 2): a row per input of a Custom Scene: "Air quality ← [Signal ▾] · 87 AQI".
- Settings ▸ AI: "Let AI add live data signals".

## 8. Risks

Saver sandbox (never fetch in the saver; Signals/Fetch excluded from the saver target); flapping
(hysteresis, hold, single evaluator, lease); battery (only while needed, 5 min minimum, LPM ×2,
hourly budget); abuse (caps, AI host policy, outline-only test); secrets (Keychain only — ad-hoc
signing may re-prompt after updates: VERIFY EARLY; show "Key needs re-entry" on errSecAuthFailed);
burn-in from static data; hosts disagreeing (non-defaulted `live` + self-test); engine compat
(ctx.input fails on older apps → bump minApp).

## 9. Phase 1 files

New: Shared/Signals/{Signal.swift (types, BuiltInSignals, SignalState + freshness + activeRule),
PlayRule.swift (Condition/Clause/Op, RuleEngine.matches/decide), SignalFeed.swift (FileStamp
reader like WeatherFeed)}, Shared/Signals/Fetch/SignalFetch.swift (SignalPolicy.validate,
SignalFetcher.fetch: session, caps, redirect delegate, JSON Pointer, scale/offset — app + MCP only;
project.yml saver excludes "Signals/Fetch/**"), App/Signals/{SignalKeychain.swift,
SignalService.swift (ObservableObject sibling of WeatherService: schedules, built-ins, decide every
60 s + on change, writes signal-values.json on change + lease refresh)}, MCP/ToolsSignals.swift,
Guides/signals.md, App/SignalsSettingsSection.swift, App/WhenRules.swift.
Changed: Shared/Preset.swift (Library.signals/rules), Shared/Playback.swift (overlay, precedence
comment), Shared/DisplayPins.swift, Shared/AI/LibraryEdits.swift (pruneRules, upsert/delete
signal/rule), Shared/AI/AIBridge.swift (ops upsertSignal/deleteSignal/testSignal/upsertRule/
deleteRule; fields signal/rule/force; result), Shared/AI/AIStore.swift (allowSignals),
App/Weather/WeatherService.swift (isNeeded, temperature_2m), Shared/Weather/WeatherState.swift
(temperature), App/DotStudioApp.swift (attach/start), Saver/DotSaverView.swift (SignalFeed, live,
rule change = changed, crossfade), App/Destinations.swift, App/WallpaperPower.swift,
App/WallpaperController.swift (re-evaluate on activeRule), App/DisplayStyles.swift, MCP/Tools.swift,
App/AIBridgeHost.swift (+ gates, notices, snapshot includes rules), MCP/LibraryAccess.swift
(offline ops), App/DestinationCards.swift, App/SettingsView.swift, App/AISettingsSection.swift +
App/AIConnect.swift (allowSignals toggle).
Tests: tools/wallpaper-selftest (precedence pin > rule > night > rotation, lease expiry, pruning,
hysteresis/hold); tools/mcp-selftest (signals against a local fixture via a test-only
DOTSTUDIO_SIGNAL_ALLOW_LOCAL=1 hook; refusals: http, private IP, ?apikey=; set_rule refused with
playback off, offline and --fake-app).
