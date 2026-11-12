# AI hero media (`AIHero.tsx`)

Every file the AI hero shows, by slot. The slots are listed in `src/sections/mcpMedia.ts`.
To swap in final renders, overwrite a file with the same name; no code changes.

The current files are **placeholders** made from the Commute work-in-progress stills (day, golden,
night wide shots and the layout workbench renders). `clay`, `materials`, `graded`,
`render-noisy` and the `frame-*` grades were faked from the day/golden/night stills with ffmpeg,
and `final-loop` is a slow push-in on `graded` with a passing shadow, not a render.

All stills: **1600 × 1000 (16:10) WebP, quality ~72, ≤ ~150 KB each**. Same camera (Commute's
`wide`) for everything except `layout`, so the build reads as one shot coming together.

| Slot | File | What it should be |
|---|---|---|
| Build 01 · Set | `layout.webp` | The Commute set blocked out: workbench / bird's-eye view of carriage, viaduct, street. Untextured is fine. |
| Build 02 · Clay | `clay.webp` | `wide` camera, every material overridden with plain clay grey, soft light. |
| Build 03 · Materials | `materials.webp` | `wide`, real materials, flat preview light (no sun shadows yet). |
| Build 04 · Light | `lit.webp` | `wide`, Cycles approval still: ray-traced sun and shadows, no look yet. |
| Build 05 · Look | `graded.webp` | `wide`, the final look: bloom, halation, colour. No baked grain (the page adds live grain, as DotStudio does). |
| Render · first frame | `render-noisy.webp` | A very low-sample frame of the loop (visible noise), shown as the render starts. |
| Render · day | `frame-day.webp` | A finished loop frame, `day` variant, graded. |
| Render · golden | `frame-golden.webp` | Same, `golden`. |
| Render · night | `frame-night.webp` | Same, `night`. |
| Play · loop | `final-loop.webm` | The finished seamless loop: **1280 × 800, 24 fps, VP9, no audio, ≤ ~4 MB** (8–20 s). |
| Play · loop | `final-loop.mp4` | The same loop as **H.264** (`-movflags +faststart`, yuv420p), ≤ ~4 MB. Safari falls back to it. |
| Play · poster | `final-poster.webp` | The loop's first frame, 1600 × 1000 WebP. |

Budget: the site is on Vercel Hobby; keep this folder under ~6 MB in total.

Encoding, for reference:

```sh
cwebp -q 72 still.png -o graded.webp
ffmpeg -i loop.mov -vf scale=1280:800 -c:v libx264 -crf 24 -preset slow -pix_fmt yuv420p -movflags +faststart -an final-loop.mp4
ffmpeg -i final-loop.mp4 -c:v libvpx-vp9 -b:v 0 -crf 38 -row-mt 1 -an final-loop.webm
```

The penguin is an original character; don't name or caption it after any existing franchise.
