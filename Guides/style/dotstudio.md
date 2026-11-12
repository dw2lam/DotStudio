# DotStudio Style

What a DotStudio screensaver or live wallpaper should look like, and what it must never look like. Read this before you call `create_style`, `update_style` or `create_custom_scene`. DotStudio's taste is calm, living and premium: a dark, quiet image that changes so slowly and so organically that it never reads as a loop, with one subject, one accent colour and no gimmicks. Everything below comes from the shipped library, the styles DotStudio's designer kept and promoted, and the eight styles that were retired for looking "cheap, Windows Vista-like". Safety rules in `burn-in` and `power` always apply on top of this guide.

## The three words

- **Calm.** Slow motion, low contrast between frames, no flashes. A person should be able to look at it for an hour without being pulled in. Nothing strobes, nothing races, nothing demands attention.
- **Living.** It is never a still and never an obvious loop. Things breathe, sway, drift, catch light. Rare events (a petal flutters, a shooting star, the penguin waves) arrive irregularly.
- **Premium.** It looks rendered by a careful photographer or a print studio: real light, soft falloff, film grain, restrained colour. Never clip-art, never glossy plastic, never a 2007 screensaver.

## Composition

- Dark-first. Backgrounds sit near black: luminance below about 0.08 (sRGB channels roughly 0.01-0.08). The built-ins use `{"r":0.010,"g":0.012,"b":0.020,"a":1}` (Penguin), `{"r":0.03,"g":0.03,"b":0.05,"a":1}` (Liquid Chrome), `{"r":0.025,"g":0.04,"b":0.085,"a":1}` (Night Sky). Light styles exist (Topography's paper, Minimal's Paper background) but are the exception and are warm off-white, never pure white.
- One subject. One flower (Bloom), one penguin, one sea and a sun (Golden Hour), one surface (Liquid Chrome). Empty space is part of the design.
- Depth through light, not outlines: aerial perspective (far things bluer, softer, lower contrast), form shading from one key light, defocus up close. Meadow's hills are "form-shaded, blue and soft only with real distance".
- Detail must be filtered. Fine repeating detail that shimmers or aliases is a defect: DotStudio's designer rejected Golden Hour's far water when it aliased into streaks ("brushed metal") until it was filtered. Box-filter or defocus anything thinner than about 2 px.
- No on-screen labels, taglines, watermarks or captions by default. Bloom's Captions param exists but defaults to 0. DotStudio's designer removed over-labelling from the app itself.

## Motion

- Slow. Typical built-in `speed` defaults are 0.5-0.6 on a 0-2 range (Liquid Chrome 0.6, Topography 0.5, Currents 0.6, Silk 0.6). Leave speed at or below the default unless the user asks for more energy.
- Never obviously looping. Use long periods, several layers moving at incommensurate rates (ratios like 1 : 1.618 : 2.414, never 1 : 2), and noise rather than sine waves. A sine on position reads as a pendulum within ten seconds.
- Rare events are hashed from time blocks and shuffled, so the same thing never returns on a fixed beat. Penguin plays its eight behaviours in shuffled blocks: one returns no sooner than a minute later, about every two and a half minutes on average.
- Stateless. Every built-in is a pure function of time `t` (and the wall clock), so the screensaver, wallpaper, previews and thumbnails agree. Custom scenes must be too: no frame-to-frame state.
- `t` wraps every hour (`t` is in [0, 3600)), hidden behind a 2 s crossfade. Periods should divide 3600 s or the motion should not care about the jump. Use the wall clock (not `t`) for anything that follows the time of day.
- Respect the frame budget: 30 fps for continuous motion, 24 for the LED/film cadence that Bloom and Penguin use (they step time themselves), 20 or 15 for very slow ambient pieces. Prefer the lowest rate that still reads smooth: if anything moves more than about 3 px per frame at 1080p, raise the rate or slow it down. Details in `power`.

## Type and clocks

- For a clock, start from the built-in clocks (`standbyClock`, `minimalClock`, `watchClock`, `flipClock`, `wordClock`) and restyle them. They idle at one frame a second on the wallpaper and the StandBy pack drifts against burn-in; a custom shader clock gets neither.
- Readable from across a room. StandBy's figures are SF Pro Rounded Heavy at full height; Minimal's thin SF Pro Light time is large (Time Size 1.0 of 0.6-1.5) with generous space.
- Contrast: text at least 0.85 luminance on a background below 0.10, or the reverse on paper. Never thin grey on grey. Never pure white either: the built-ins use 0.93-0.97 (`{"r":0.96,"g":0.96,"b":0.97,"a":1}` StandBy, `{"r":0.93,"g":0.92,"b":0.90,"a":1}` Minimal).
- Weights: Medium or Regular for secondary lines; DotStudio's designer found heavy music type too heavy. Text is never cut off: wrap or shrink, never truncate.
- Shadows on type are soft and two-layered, never a hard drop shadow. No boxes or cards behind text: use a feathered scrim that fades with no edge.
- At night, dim. StandBy turns its figures deep red after sunset: `{"r":0.58,"g":0.035,"b":0.025,"a":1}` at the figure's relative brightness.

## Colour

Rules:

- Two or three colours plus neutrals. One accent. The accent covers well under a fifth of the screen.
- Colours are sRGB floats 0-1 in DotStudio's RGBA form: `{"r":0.16,"g":0.45,"b":0.86,"a":1}`. `a` is always 1 for effect colours.
- No pure saturated primaries or secondaries (`1,0,0`, `0,1,0`, `0,0,1`, `1,0,1`, `0,1,1`). Pull every accent toward the light it represents: sunlight is `1.0, 0.85, 0.62`, not yellow.
- No rainbow hue cycling. Colour changes come from light (sun, sky, weather), not from a hue wheel. (Bounce's colour-on-every-bounce is a deliberate DVD homage, not a template.)
- Whites are warm or cool off-whites (0.92-0.98). Blacks are tinted near-blacks, rarely `0,0,0`.
- Neon is a single exception (Neon Horizon, a retro homage). Do not use it as a starting point.

Palettes that fit (colorA usually the background or shadow, colorB the subject or light; check each scene's colour labels with `describe_scene`):

1. **Blue Bloom** (the blue DotStudio's designer fell for: #214785 at the top to #72a3da at the bottom). Sky `{"r":0.129,"g":0.278,"b":0.522,"a":1}`, petals `{"r":0.16,"g":0.45,"b":0.86,"a":1}`.
2. **Baby's Breath** (warm dark grey #372e27, white clusters). Ground `{"r":0.216,"g":0.180,"b":0.153,"a":1}`, flowers `{"r":0.97,"g":0.96,"b":0.93,"a":1}`.
3. **Chrome** (Liquid Chrome). Shadow `{"r":0.03,"g":0.03,"b":0.05,"a":1}`, highlight `{"r":0.92,"g":0.94,"b":1.0,"a":1}`. Monochrome; the only colour is a faint pearl iridescence.
4. **Golden Hour** (Ocean Horizon). Deep water `{"r":0.02,"g":0.09,"b":0.13,"a":1}`, sunlight `{"r":1.0,"g":0.85,"b":0.62,"a":1}`.
5. **Afterlight** (dusk sea). Water `{"r":0.02,"g":0.06,"b":0.12,"a":1}`, light `{"r":1.0,"g":0.70,"b":0.62,"a":1}`.
6. **Night Sky**. Sky `{"r":0.025,"g":0.04,"b":0.085,"a":1}`, horizon glow `{"r":1.0,"g":0.62,"b":0.36,"a":1}`.
7. **Penguin LED**. Background `{"r":0.010,"g":0.012,"b":0.020,"a":1}`, penguin `{"r":0.16,"g":0.44,"b":1.0,"a":1}`.
8. **Ink on Paper** (Topography). Ink `{"r":0.05,"g":0.06,"b":0.07,"a":1}`, paper `{"r":0.93,"g":0.90,"b":0.82,"a":1}`.
9. **Silk Amber**. Shadow `{"r":0.03,"g":0.03,"b":0.06,"a":1}`, sheen `{"r":0.98,"g":0.78,"b":0.55,"a":1}`.
10. **Cyanotype**. Prussian `{"r":0.05,"g":0.19,"b":0.42,"a":1}`, cream `{"r":0.95,"g":0.93,"b":0.87,"a":1}`.
11. **Evening Anemone**. Sky `{"r":0.106,"g":0.169,"b":0.318,"a":1}`, petals `{"r":0.95,"g":0.95,"b":0.97,"a":1}`.

## What DotStudio's designer liked, and why

- **Liquid Chrome** (`liquidChrome`; the default style in 1.3, on the installer and the website). A rippling mirror reflecting a studio: horizon, softboxes, floor. Why it works: monochrome with one pastel pearl wash (Iridescence 0.12), real reflections instead of drawn highlights, softbox glints that roll off gently instead of clipping to flat pills, contours that never fuse into hard X/Y junctions, and slow motion (the shader runs at `t * speed * 0.2`). About 5.4 ms at 5K.
- **Golden Hour** (`oceanHorizon`, `weather` 0 = Live). Open sea with a low gold sun (Sun Height 4), haze 0.55, sea state 0.45. Rendered in linear light and tone-mapped once, so glows and reflections add up like real light. Optional Follow the Sun (`live` 1) tracks the real sun and moon; the live weather changes clouds, rain and fog around it while the gold light stays. The far water is filtered, never aliased.
- **Meadow** (`meadow`). Built "after DotStudio's designer's references": vivid green rolling hills, form-shaded, receding through blue air under big bright cumulus, wildflowers softly defocused at the lens, backlit golden grass. A film finish (halation, grain, a fine ordered dither) makes it feel photographed, not rendered. Follows the real sun, moon and weather. Tall Grass is the same scene low in the grass at 18:54.
- **Bloom** (`flowerBloom`: Blue Bloom, Baby's Breath). One procedural flower swaying in a breeze, slowly turning and nodding, a petal fluttering now and then. Only the flower is drawn in cells (tiny glyphs, LED cells or round dots); the sky stays a smooth gradient, so the effect frames the subject instead of covering everything. Exactly two colours. 24 fps stepped cadence. 1.6-2.4 ms at 5K.
- **Penguin** (kind `waddle`; "Penguin LED"). A chubby original penguin on a dark LED panel: round LED dots at 80 % of the pitch with a soft bloom, a backdrop (drifts, pines, an igloo, peaks, moon and stars) drawn in the same cells at about a third of the brightness. It walks, waves, belly-slides, dances and dozes in shuffled 20 s episodes. Depth from parallax layers and dimmer, softer far dots; joy from rare moments (aurora, a shooting star, bursts of hearts when it waves). The panel stays dark: only shapes are lit. Follow the Clock dims it and makes it doze more at night. 24 fps, 2.5-2.7 ms at 5K. If `list_scenes` does not show it, this build does not have it yet.
- Also loved: **Topography** (ink contour lines on paper), **Universe** (a 3D solar system on a slowly orbiting camera), **Zen Garden** (a rake cart ploughing real furrows). Looks DotStudio's designer kept: ASCII (source-coloured glyphs on near-black), the 1-bit dithers (Atkinson graphite on warm paper).

Common thread: one subject, real light, physical materials (metal, water, grass, paper, LEDs), two or three colours, slow organic motion with rare surprises, a film or print finish.

## Where to start from a request

Start from the closest built-in (`duplicate_style`) and tune it before you reach for a custom scene. A tuned built-in almost always beats a new shader.

- "Calm", "minimal", "for my desk": Liquid Chrome, Silk, Topography, Afterglow (`meshGradient`, indigo to coral), Currents.
- "Nature", "relaxing", "sunset": Golden Hour, Meadow or Tall Grass, Night Sky, First Snow, Shallows.
- "Something cute", "a character", "LED", "pixel": Penguin; Bloom with Render = Dots or Pixels.
- "A clock": StandBy (across the room), Minimal (quiet), Chronometer (a watch). Recolour and resize; do not build a shader clock.
- "Space": Universe, Night Sky; Black Hole only on a desktop Mac (it is the heaviest style).
- "My photos": a Look over the slideshow: Film, Cyanotype, Atkinson, Riso Duotone, ASCII, Soft Focus.
- "My brand / logo": Bounce with the user's image or word, in the brand's colours, on a near-black background.
- "Retro": Neon Horizon or Light Ribbons, with speed lowered; never Pipeworks or the tunnels.

When the user names a colour, translate it into a muted, light-like value from the palettes above rather than a pure hue ("blue" is `0.16, 0.45, 0.86`, not `0, 0, 1`).

## What was rejected, and why

Retired in 1.4.2 as "cheap, Windows Vista-like" (DefaultPresets.retiredStyles; their kinds are hidden from Add Effect by EffectKind.isRetired). Never recreate these looks:

- **Sunray / Opaline** (`dialClock`). A photoreal watch dial filling the screen like a macro photograph, sunray-brushed, polished hands, a big "Shine". It had itself replaced Glass Clock, which DotStudio's designer called "too cheap". Superseded by the StandBy clocks: the lesson is that a clock should be readable and quiet first, a showpiece second; heavy specular shine on a skeuomorphic object reads as cheap.
- **Pipeworks / Brass Pipes** (`pipes`). Glossy lacquered pipes growing through a dark room, ray-traced with reflections. The Windows 95 pipes, re-rendered: "dated, glossy 'Vista' look". Gloss on primary-coloured plastic is the anti-pattern.
- **Light Tunnel / Hex Tunnel** (`demoTunnel`). A demoscene tunnel of brushed-metal panels and racing neon rings. Same verdict: dated and glossy, plus fast forward motion and neon.
- **Fireflies / Blue Hour** (`fireflies`). Glowing dots drifting over a dusk meadow with shallow depth of field. Retired in the same batch with no separate note; it reads as generic particle glow (the stock "magical sparkles" screensaver) with no subject, and Blue Hour paired it with a lime glow `0.78, 1.0, 0.42`.

Also dropped earlier: Fisheye, Swirl and Ripple ("Photo Booth-era warps"), Toon ("dated cel-shade filter"), Truchet ("novelty tile maze"), Voronoi ("edgeless, muddy mosaic"). DotStudio's designer called Liquid Glass "soap" and an early Aurora "fake/cheap". Ink Bloom, Sumi and Ember Ribbons are withheld because they "don't hold up yet".

## Anti-patterns

- Gloss, bevels, chrome-on-plastic, lens flares, specular stars, "Aqua" or "Vista" sheen.
- Busy screens: many subjects, many colours, particles everywhere, every region moving.
- High-contrast strobing, flashes, lightning that is not rare and soft, full-screen brightness swings.
- Fast motion: racing tunnels, warp speed, anything over a few pixels per frame.
- Neon overload: several saturated hues glowing at once.
- Clip-art and cartoon icons (the Penguin works because it is an LED panel with craft, not a sticker).
- Obvious loops: a sine sway, a 10-second cycle, a rotation you can count.
- Rainbow hue cycling and pure saturated primaries.
- Tiny or thin low-contrast text; text cut off; boxes and cards behind text; hard drop shadows.
- Pure-white full-screen backgrounds or large pure-white areas (glare at night, burn-in risk for anything static over them).
- Aliasing, moire and shimmer on fine detail.
- Static bright elements with no drift (see `burn-in`).

## The user's own guides

Users can add their own guides (brand guides, house styles) as `.md` files in `~/Library/Application Support/DotStudio/guides/`. `list_guides` lists them; read every one that applies before designing and honour it. A user guide overrides this guide's palettes, subjects and mood. It never overrides the safety rules: burn-in protection, the power budget and readable type always hold. If a brand guide asks for something unsafe (a pure-white static logo, a 60 fps raymarcher), keep the brand intent and make it safe (drift and dim the logo, cap the cost) and say so.

## Checklist before you call create_style

1. Did you read `settings/index` (and `describe_scene` for your scene) so every param key and menu index is real?
2. One subject, two or three colours, one accent, dark background (or a warm paper one on purpose)?
3. No pure primaries, no rainbow, no pure white areas, no gloss or flares?
4. Speed at or below the scene's default unless asked; nothing moves more than about 3 px a frame?
5. Motion layered and noise-driven, no visible loop within a few minutes; rare events irregular?
6. `fps` set deliberately: 30 for continuous motion, 24 only for Bloom/Penguin, 15-20 for very slow pieces?
7. Anything static (text, logo, horizon, card) drifts and dims (see `burn-in`)?
8. Type large, high contrast, Regular or Medium weight, nothing cut off?
9. User guides read and honoured?
10. A short, plain style name (two words, no emoji, no "AI").

## How to iterate

1. Create the style, then `preview_style` at t = 0, 30 and 300 seconds. Compare: the frames should feel like the same calm place, not the same frame (static) and not three different scenes (too fast).
2. Ask for a contact sheet (`preview_style` with several frames) to check for loops, flashes and composition drift over minutes.
3. For time-of-day scenes, preview at a few clock times (morning, golden hour, night); for weather scenes, preview Live in a few conditions; for anything with text, preview with the music card on.
4. `benchmark_style`: aim for 4 ms or less per frame at 5K, never over 6 ms (see `power`). If it is heavy, lower quality params (density, octaves, flowers, clouds) before lowering fps.
5. Change one thing at a time with `update_style`, re-preview, and stop when it is calm. Fewer, better changes beat many.
