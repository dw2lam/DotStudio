# DotStudio — web (React)

A redesigned DotStudio landing page built on the **Prisma** design language:
dark, moody, cinematic, warm cream (`#DEDBC8`). Same product as the static
`../website`, different skin and stack.

## Stack

- **Vite + React 18 + TypeScript**
- **Tailwind CSS 3** — `primary` (`#DEDBC8`), `font-serif` = Instrument Serif italic
- **framer-motion** — word pull-ups, fade-ins, scroll-linked text reveal, card entrances
- **lucide-react** — `ArrowRight`, `Check`

## Sections

Hero is the anchor; every section below it shares one cinematic-cream card language
(noise texture, `WordsPullUpMultiStyle` headers, `#212121` cards, `Reveal`
scale/fade entrances).

| Section | What it is |
|---------|-----------|
| `AIHero` | First thing on the page: NEW, "Make your own screensaver with AI", Download + How it works CTAs, and a ~38 s auto-playing session with the MCP server (prompt → real tool calls in a log → Blender build stages → loop render readout → the loop on a Mac display). Script in `aiSequence.ts`, media slots in `mcpMedia.ts` + `public/media/mcp/README.md`; paused off screen, pause button, chapter tabs seek, `?ai=<seconds>` opens it paused; reduced motion gets a four-frame storyboard. Carries the nav pill |
| `Hero` | Inset rounded viewport, **live ASCII effect canvas** backdrop (no stock video), hanging black nav pill, giant `DotStudio` wordmark, pitch + "Get DotStudio" CTA |
| `Showcase` | "The best of the library": the owner's favourites only: Liquid Chrome (silent render loop), Zen Garden, Tidewater (four renders of its live sky cross-fading: dusk, night, morning, snow), Topography, Universe |
| `NowPlaying` | New in 1.4: what's playing (Spotify / Apple Music) over any screensaver; Album / Stage / Cover / Corner switcher (images load on demand, fictional demo track) |
| `Studio` | The app itself: the gallery with Screensaver + Wallpaper cards joined by SYNC, Playlist / Night / Wallpaper, a details strip (live weather, 120 fps, menu bar, instant start), and the editor |
| `Packs` | Clocks (2×2 uncropped 16:10 stills: StandBy, Chronometer, Minimal, Window Light), Flowing (Lava loop), Water & Sky (Shallows), Retro (Neon Horizon loop); scene lists = the default library's styles of each pack; no style repeated from Showcase |
| `Looks` | One built-in photo, six Looks, switchable in place (images load on demand) |
| `HowItWorks` | `#how-it-works`: MCP setup in three cards (get DotStudio → connect Claude Desktop / Claude Code / other MCP apps → ask), film-scene costs (Blender 5.1+, installed by the user) and the "you stay in charge" note |
| `Steps` | Install: DMG → Open Anyway in Privacy & Security → welcome guide; auto-updates + library location |
| `Download` | Centered `#101010` CTA card: icon, "Get DotStudio", cream pill download button, release meta |

Each style appears once on the page. Earlier versions had a 16-render Collection, a
live-canvas strip and a 40-effect Catalog; the redesigned (gallery-first) app made them
obsolete. Two sections from earlier drafts were cut: a personal "About" section, and a
"Features" highlight grid that turned out to repeat the other sections
(and whose per-card "Learn more → GitHub" links pulled visitors off the page before
the Download CTA). The only outbound CTAs now are the Hero and Download buttons.

## Shared animation components (`src/components/animations/`)

- `WordsPullUp` — split-by-space words slide up `y:20→0`, staggered; optional `showAsterisk`
- `WordsPullUpMultiStyle` — same, with per-segment classNames (e.g. an italic serif clause)
- `AnimatedParagraph` — per-character opacity `0.2→1` driven by `useScroll` (`start 0.8 → end 0.2`)

## Live effects

`src/components/EffectCanvas.tsx` is a small, dependency-free canvas renderer that
re-creates three of DotStudio's signature looks (`ascii` / `matrix` / `halftone`)
over a drifting plasma field — cream on black. It replaces the spec's stock
`cloudfront` videos with the app's own visuals and honors
`prefers-reduced-motion`.

## Develop

```bash
npm install
npm run dev       # http://localhost:5173
npm run build     # tsc -b && vite build  → dist/
npm run preview   # serve the production build
```

## Deploy (Vercel)

This is a **build** project (unlike the static `../website`). `vercel.json` sets
`framework: vite`, `buildCommand: npm run build`, `outputDirectory: dist`. Point a
Vercel project's **Root Directory** at `web` to ship it.

## Media (`public/media/`)

All renders come from the app's own offscreen renderer (`tools/gallery/render.sh … --size 1920x1200`,
always with `DOTSTUDIO_STORE_DIR=$(mktemp -d)`); app shots are the offscreen UIShots renders
(`DOTSTUDIO_UI_SHOTS`, dark, 1440x900 window) framed as a window in CSS. Nothing is a screen capture.

- `scenes/*.webp`: 1600 px stills (1280 for the small tiles; Tidewater = `--weather` × `--clock` renders;
  the clocks = `--clock` renders at a set time). Retired styles' stills are deleted with them (1.4.2:
  `sunray`, and `flip-clock` once the Clocks card moved to the new clocks)
- `loops/*.{webm,mp4,webp}`: 1280x800 silent loops + posters; lazy, play only in view. Liquid Chrome
  is 300 frames rendered on an eased there-and-back time path, so it loops without a seam or ghosting
- `music/*.webp`: `--full art --layout album|stage|cover` and `--card bottomLeft`, fed a fictional
  fixture (`DOTSTUDIO_MUSIC_FAKE`, artwork from tools/music-fixtures)
- `looks/*.webp`: 1280x800, one built-in photo (Wadi Rum, CC0) per Look
- `app/*.webp`: gallery (`dest-sync-on`) and editor (`editor-scene`, cropped) UIShots
- `icon.png`: 256 px of the Chrome Drop icon (`tools/icon/build.sh <dir>` → `chrome.png`)
