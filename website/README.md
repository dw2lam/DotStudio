# DotStudio — website

Landing page for **DotStudio**, the macOS app that runs any gradient, image or
video through dither / ASCII / halftone / matrix / VHS and 30+ live effects, then
installs the result as a real Mac screensaver.

Aesthetic: a darkroom / terminal **art gallery** — monospace-forward, halftone +
scanline textures, CRT-green phosphor. Same page structure as the NotchTune site,
deliberately different skin.

## Files

| File | What it is |
|------|------------|
| `index.html` | All page structure and copy |
| `styles.css` | Design system (dark navy + CRT-green, monospace-forward) |
| `engine.js`  | The in-browser effects engine — a small canvas renderer that re-creates the app's effects (dither, ascii, halftone, dots, matrix, scanlines, vhs, voronoi, thermal, gameboy, neon, hex). Powers the hero, the live Exhibition tiles, and the Lab. |
| `app.js`     | Page wiring: live GitHub release fetch, scroll reveals, nav, hero effect cycler, the interactive Lab |
| `assets/`    | `icon.png` and `gallery/*.png` (real exports copied from `../docs/`) |
| `vercel.json`| Static-serve config (clean URLs + asset cache headers) |

This folder lives inside the main `dotstudio` repo, alongside the macOS app. It is
the only part of the repo Vercel deploys.

## Preview locally

```bash
cd website
python3 -m http.server 8731
# open http://localhost:8731
```

It's a fully static site — no build step.

## GitHub release / download button

`app.js` sets `REPO = "dw2lam/dotstudio"` and fetches
`api.github.com/repos/dw2lam/dotstudio/releases/latest` on load. It rewrites the
version eyebrow, the download buttons (pointing them at the latest `.dmg`/`.zip`
asset) and the release meta. If the request fails it keeps the static `v1.0.0`
fallback baked into the HTML.

## Deploy (GitHub → Vercel)

The repo holds both the macOS app and this site, so point Vercel at the subfolder:

1. Vercel → **Add New… → Project** → import `dw2lam/dotstudio`.
2. **Root Directory** → set to `website` (the important step — keeps Vercel away
   from the Xcode project at the repo root).
3. **Framework Preset** → *Other*. No build command, output is the folder itself.
4. Deploy. Every push to `main` that touches `website/` ships automatically.

`vercel.json` handles clean URLs and asset caching. No server needed — it's a
static site, so Netlify / GitHub Pages / Cloudflare Pages work the same way
(serve the `website/` folder).
