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
| `Hero` | Inset rounded viewport, **live ASCII effect canvas** backdrop (no stock video), hanging black nav pill, giant `DotStudio` wordmark, pitch + "Get DotStudio" CTA |
| `Showcase` | "The best of the library": a bento of the owner's favourite scenes, Liquid Chrome / Golden Hour / Neon Horizon as silent render loops, Universe / Topography / Aurora as stills |
| `Studio` | The app itself: native window grabs of the gallery (Playback bar: One Style / Rotate / Day & Night), the editor on Lava Lamp, and the welcome sheet's Create Your Own tab |
| `Packs` | The four new scene packs (Clocks, Flowing, Nature, Retro), one card each, no style repeated from Showcase |
| `Looks` | One built-in photo, six Looks, switchable in place (images load on demand) |
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

All renders come from the app's own renderer (`tools/gallery/render.sh … --size 2400x1500`),
app grabs are native window captures (`screencapture -l`, shadow included) of a Debug
build run against a scratch library (`DOTSTUDIO_STORE_DIR`) with the dev-only
`DOTSTUDIO_DEMO_*` hooks in `App/ContentView.swift`.

- `scenes/*.webp`: 1600 px stills (Flip Clock rendered natively at 2560x800 for its wide tile)
- `loops/*.{webm,mp4,webp}`: 1280x800 silent loops + posters; lazy, play only in view
- `looks/*.webp`: 1280x800, one built-in photo (Wadi Rum, CC0) per Look
- `app/*.webp`: 2400 px window grabs with transparent shadow margin
