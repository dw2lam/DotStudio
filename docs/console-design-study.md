# Console — design study (issue #6)

What the references in issue #6 actually look like, studied page by page on 2026-11-24
(full scroll-throughs of teenage.engineering: home, TX-6, OP-1 field, EP-133, TP-7, OB-4, CM-15,
field system, the TX-6 and OP-1 guides, the guides index, "now"; plus Playdate, Nothing, Vitsœ).
Reference captures (study only — never shipped, never copied): the scratchpad `te-study/`
contact sheets. **Inspired by, never copied:** no TE logos, names, typefaces, product shapes,
pictograms or artwork. We take the *principles* and draw our own.

The first Console attempt missed because it kept a generic landing-page/app layout (bold
headlines, rounded cards, mono caps everywhere) and only reskinned it. The references are
structural: their layouts are different, not just their colours.

## 1. Principles (observed)

| # | Principle | Where it shows |
|---|---|---|
| P1 | **Thin, light type.** A light geometric grotesk, lower case, large sizes in a thin weight. Bold almost never. Mono is NOT the voice. | every page: nav words, headings ("smallest of its kind."), product names |
| P2 | **Full-bleed bands, never cards.** Alternating black bands (product imagery) and light-grey bands (one centred sentence + a centred paragraph + one small coloured text link). | TX-6, CM-15, TP-7, OB-4, field system |
| P3 | **One object, huge and centred.** The product alone on a plain field; dramatic light on black, soft light on grey. | every product page hero |
| P4 | **The name as type art.** Product names in thin or outline letters, with a tiny spec stack beside them ("128 MB SAMPLER COMPOSER", "44.1 KHZ USB-C 2.0") and hairline rules. | EP-133 "K.O. II" outline, EP/BC, OP–1 [field] tag |
| P5 | **Line art.** 1 px dark-grey drawings of the product and its parts; "what's in the box" as outlined squares; diagrams inside thin boxes. | TX-6 / OP-1 guides |
| P6 | **The nav is a layout, not a bar.** Thin pictogram + big thin word + 3 tiny sub-links, per group, on the grid; a tiny text block; an outline mark. | all pages |
| P7 | **Callouts as brackets.** Thin leader lines with brackets to parts ("usb-c", "3.5 mm audio in"), tiny lowercase labels. | TX-6 side views |
| P8 | **Feature tiles.** Black squares with a white pictogram; under each a 2-line lowercase label and TINY UPPERCASE fine print. | TX-6 "size is only half the story." |
| P9 | **The device's own screens.** A grid of small tiles, each one of the product's screens: black with thin colourful vector UI (OP-1) or white LCD with heavy condensed pixel numerals (TX-6 "80", "50"). | TX-6 system screens, OP-1 screens |
| P10 | **Lists as texture.** Long centred columns of tiny uppercase feature lines; two-column indexes of plain links. | OP-1 "100 new features", guide index |
| P11 | **Colour = the object's colour.** Pages are black / light grey / off-white; colour comes from the product (knob caps navy/tan/grey/orange, an orange or blue text link). The guides index fills each row with that product's body colour. | guides index, OP-1 caps |
| P12 | **Devices:** rows of knurled knobs; off-white rounded-square keycaps with thin line icons; round black keys; LEDs as tiny dots; legends printed small and lower case on the chassis. | TX-6, OP-1, EP-133 |

Rams (Vitsœ): less, but better — every element earns its place. Playdate (designed with TE): one
colour, one object, plain big statements. Nothing: monochrome + one accent, dot-matrix readouts.

## 2. Our own system (what we use)

- **Type:** Inter (open licence) — Light 300 for headings and nav words, Regular 400 for small
  text; tiny UPPERCASE fine print at 9–10 px. In the app: SF Pro (system) at `.light`/`.thin`
  weights, lower case. Readouts on "screens": a dot-matrix face (Doto, open licence) on the site;
  in the app, heavy condensed system numerals on a white LCD tile (no bundled font).
- **Fields:** black `#000`, light grey `#e3e3e1`, off-white paper `#efeee9`. Ink `#1a1a1a`,
  secondary `#6b6b68`. Link/accent: signal orange `#f2551d` (text on light: `#a33609`).
- **Knob caps (our palette, not theirs):** blue `#2e6bf0`, green `#1fa35b`, white `#f7f6f2`,
  orange `#f2551d` — knurled sides, a pointer line, no glossy gradient.
- **Our pictograms:** drawn ourselves in 1.5 px line: a 2×2 pad grid (styles), a knob (editor),
  a sun arc (live sky), a cloud with rain strokes (weather), a box (download), an open booklet
  (guide), a screen with a moon (screensaver), a desktop with windows (wallpaper).
- **Our mark:** a dot in a circle (the LED dot), outline; the wordmark "dotstudio" in Inter Light.

## 3. Website layout (new)

1. **Nav (P6):** "dot / studio" stacked thin, left. Groups: *styles* (pad pictogram; sub: scenes,
   looks, clocks), *studio* (knob; sub: editor, power, music), *guide* (booklet; sub: install,
   questions, spec), *download* (box; sub: 1.6.8, release notes, github). Tiny text block; outline mark.
2. **Black band hero (P3, P4):** a full-bleed scene loop (our own renders, `media/loops`), the
   name "DOTSTUDIO" in outline letters centred, a tiny spec stack beside it
   ("LIVING SCREENSAVER / LIVE WALLPAPER · MACOS 14 · APPLE SILICON"), hairline rules.
3. **Grey band (P2):** "a small studio for your screen." + centred paragraph + orange "download".
4. **Object band (P3, P7):** the app window huge on grey, bracket callouts to the pads, the
   channel strip, the screensaver / wallpaper channels.
5. **Feature tiles (P8):** 10 black squares with our pictograms: live sky, live weather, clocks,
   music, per display, power saving, frame rate, editor, export, MCP — each with a 2-line label and
   tiny uppercase fine print (facts verified in the repo).
6. **Screens (P9):** a grid of the styles themselves as small rounded tiles ("38 styles in a fresh
   library") — the product's own screens.
7. **Black band:** the editor in use, dramatic, with one centred line.
8. **Feature list (P10):** "everything in 1.6.8" as a centred column of tiny uppercase lines.
9. **Guide (P5, off-white):** header row "dotstudio / screensaver studio / user guide / v1.6.8";
   the app drawn as line art; a two-column index; "what's in the box" boxes (disk image, app,
   screensaver, menu bar item); booklet spreads for install and questions.
10. **Style index (P11):** every style as a full-width row filled with its own dominant colour
    (name · kind · live · fps).
11. **Download:** one centred thin line, a tiny spec stack and the checksum, one orange link.

## 4. App layout (new) — the window is the device

- **Header = the nav pattern (P6):** "dot / studio" stacked thin; groups *screensaver*, *wallpaper*,
  *power*, each with its pictogram, a big thin word and 2–3 tiny live sub-lines (what's playing,
  playlist, night; playing / paused; plugged in · 120 fps). Clicking a group opens what the cards
  did. Replaces the two big glass destination cards.
- **Stage = black band (P3, P4):** the selected style plays large on black, its name in thin
  outline letters, a tiny spec stack (scene · live sky · 30 fps · on screensaver).
- **Gallery = keys (P12):** a tight grid of square keys on light grey (rounded-square keycaps,
  the picture inset as the key's face), number printed small, name printed lower case under the
  key, LEDs as tiny dots. Filters as a row of small thin words, not chips.
- **Editor = the mixer (P12, P9):** the preview as a black screen; under it, on the grey chassis,
  rows of knurled knobs (the four most important large with coloured caps, the rest small),
  legends printed lower case under each, toggles as square keys with an LED, menus as small white
  LCD tiles you click through; one LCD readout showing the knob in your hand ("mass 40%").
- **Type everywhere:** thin/light, lower case; no mono caps legends.

## 5. Guardrails (unchanged, from the issue)

Only real controls; no decorative knobs or fake meters; legends only where they help; keyboard,
VoiceOver (knobs are sliders), Dynamic Type, Reduce Motion, Light/Dark; WCAG AA; Classic stays
the default and unchanged; no sounds.
