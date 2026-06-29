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
| `Collection` | The print room — a **real macOS app screenshot** (`app-preview`, served as webp with a png fallback) floating on a soft cream glow, then a responsive grid of all 16 real gallery renders with gradient captions, plus a scroll-revealed lead |
| `LiveStrip` | "Running right now" — three live `EffectCanvas` tiles (ASCII / Matrix / Halftone) with `live · 60fps` tags |
| `Catalog` | "Forty ways to look" — the full 40-effect index grouped into 7 `#212121` cards of chips |
| `Steps` | "Three steps to a living desktop" — Feed → Stack & tune → Install |
| `Download` | Centered `#101010` CTA card: icon, "Get DotStudio", cream pill download button, release meta |

Two sections from earlier drafts were cut: a personal "About" section, and a
"Features" highlight grid that turned out to repeat Collection/LiveStrip/Catalog/Steps
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

Real assets (`icon.png`, `gallery/*.png`) are copied into `public/` from
`../website/assets`.
