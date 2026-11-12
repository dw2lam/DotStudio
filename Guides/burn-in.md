# Burn-in and Image Retention

How to keep a DotStudio style from marking the screen. A screensaver exists to protect the display, so a style that holds bright pixels still for hours defeats its purpose. OLED panels (external OLED monitors, OLED TVs used as displays) can burn in permanently; LCD and mini-LED Macs can show temporary image retention after long static high-contrast content. Design for OLED: anything that does not change on its own must drift slowly, dim at night, and avoid pure white.

## What is static in a screensaver

- **Clock digits and dials.** The same figures sit in the same place for a minute at a time, and the colon, the frame and the dial furniture never change.
- **Logos and words.** A brand mark, a watermark, a title.
- **The music card.** Artwork, title and artist in a fixed corner for the length of a song (Corner mode), or the big Album/Stage/Cover type in Full Screen.
- **Horizon lines and ridges.** Golden Hour's sea horizon, Meadow's ridges, Night Sky's ridge, Neon Horizon's grid horizon: a long edge with the same contrast in the same row.
- **UI chrome.** Borders, frames, vignettes with hard edges, progress bars, labels.
- **Still frames.** The live wallpaper holds one frame in Low Power Mode, when the Mac is hot, and on battery when set to Still; the optional lock-screen picture is a still.

## What DotStudio already does

- **StandBy, Minimal and Chronometer drift** (Shared/Scenes/ClockKit_funcs.h, `clockkit_drift`). The whole picture shifts along a slow Lissajous loop: amplitude about 0.25 % of the screen height (2.5 px at 1000 px, 7 px at 5K, never under 1 px), about 0.02 px per second, with periods of 24 h / 31 and 24 h / 23 so it never jumps at midnight. It is a pure function of the local time of day, so the saver, wallpaper and thumbnails agree. It is invisible to the eye.
- **StandBy dims after sunset.** Night Mode Auto turns the figures a deep red, `{"r":0.58,"g":0.035,"b":0.025,"a":1}` scaled by their brightness, from just after the real sunset.
- **Chronometer's lume** glows only after dark; its seconds hand sweeps (Seconds: Sweep).
- **Penguin's Follow the Clock** dims the panel at night, and the penguin and its camera are always moving.
- **Bounce** never stops moving.
- **Music hides itself.** The corner card and the full-screen layouts show only while music plays or is paused within the linger time (default 5 minutes), then fade back to the plain screensaver. They never show an empty "Not Playing" screen. They do not drift while a song plays, so do not add more static elements next to them.
- **Live skies move horizons' light.** Follow the Sun and Live weather change the colour and contrast around horizons through the day.
- **Rotation.** A playlist of several styles (`rotation.intervalMinutes`, 1-60 in the app) changes the whole screen.
- Gaps to know: the older clocks (Flip Clock, Type Clock, Word Clock) do not drift. Prefer StandBy, Minimal or Chronometer for a clock that runs for hours on an OLED display, or put a Flip/Word clock in a rotation.

## Rules for new designs

1. **Drift anything static.** Move the whole static layer (text, logo, dial) by at least 0.25 % of the screen height, about 3-8 px at 5K, along a smooth closed path over many minutes to hours. Keep the speed under about 0.05 px per second so nobody sees it. Derive it from the wall clock, not from frame-to-frame state. Use incommensurate periods (for example 24 h / 31 and 24 h / 23, as ClockKit does).
2. **Dim periodically.** After sunset, or after the style has been up for a long time, take static bright elements down to 40-60 % brightness or a deep warm colour. Use the scene's night or Follow the Sun / Follow the Clock options where they exist.
3. **No pure white static elements.** Cap static text and logos at about 0.93-0.97 per channel (StandBy uses 0.96, Minimal 0.93). Thin text can be brighter than large fills; a large static white fill is never acceptable.
4. **No static high-contrast chrome.** No borders, frames, hard vignettes, permanent labels, watermarks or progress bars. If something must frame the image, make it soft and low contrast, and let it move.
5. **Keep horizons soft and alive.** A horizon line should be a gradient, not a hairline, and its light should change (sun, haze, weather, slow camera drift). Do not draw a bright fixed line across the screen.
6. **Large static areas go dark.** Black or near-black backgrounds are fine and save OLED power; mid-grey or bright static backgrounds are not.
7. **Logos bounce or drift.** A user's logo belongs in Bounce (it moves constantly) or, in a custom scene, drifting and fading. Never a fixed corner logo.
8. **Prefer motion everywhere.** If every region of the image changes over a few minutes (light, noise, sway), there is nothing to burn in.

## How to check

1. `preview_style` at t = 0, 600 and 3600 seconds (and at a few clock times for clocks). Any bright element at exactly the same pixels in all three is static: drift it or dim it.
2. Preview with the music card on: the card should not sit on top of another static bright element.
3. For clocks, preview at 12:00, 18:00 and 23:30: the figures should shift by a few pixels across those times and dim at night.
4. Tell the user what protects their display ("the time drifts a few pixels over the hour and turns red after sunset").
