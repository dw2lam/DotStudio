# MCP section media (`MCPDemo.tsx`)

Every file the MCP demo shows, by slot (listed in `src/sections/mcpMedia.ts`). To swap in final
renders, overwrite a file with the same name; no code changes.

Stills: **1600 × 1000 (16:10) WebP, quality ~72, ≤ ~150 KB each**, all from Commute's `wide`
camera except `layout`.

| When | File | What it should be |
|---|---|---|
| Desktop | `app.webp` | DotStudio's library window on the simulated desktop: the real capture `docs/app.png` (1600 × 1000) at 1280 × 800, WebP q86 (~80 KB). Replace this one file when the app's UI changes (e.g. the MCP button in its top bar). The desktop picture is the hero's `/media/loops/hero-tidewater.webp`. |
| Build | `layout.webp` | The set blocked out: high three-quarter view into the carriage, grey viewport shading. |
| Build | `clay.webp` | `wide`, clay materials. |
| "Here's a first look." | `lit.webp` | `wide`, the first lit still. |
| "Make the light warmer." → "Done." | `warm.webp` | `wide`, the same shot in warmer light: frame 1 of the golden loop. Also shown, dimmed, while rendering. |
| Enjoy | `final-loop.webm` | The finished seamless loop: **1280 × 800, 24 fps, VP9, no audio, ≤ ~4 MB**. The real 24 s golden-hour Commute loop (EEVEE ray-traced, bloom + halation baked, no grain), from `tools/film/dsfilm/encode.py --web`. |
| Enjoy | `final-loop.mp4` | The same loop as **H.264** (yuv420p, `-movflags +faststart`), ≤ ~4 MB. Safari uses it. |
| Enjoy | `final-poster.webp` | The loop's first frame, 1600 × 1000 WebP (same file as `warm`). |

Budget: the site is on Vercel Hobby; keep this folder under ~8 MB. A visitor downloads only one of the two clips (~3.8 MB), and only once the demo reaches Enjoy.

```sh
cwebp -q 72 still.png -o warm.webp
ffmpeg -i loop.mov -vf scale=1280:800 -c:v libx264 -crf 24 -preset slow -pix_fmt yuv420p -movflags +faststart -an final-loop.mp4
ffmpeg -i final-loop.mp4 -c:v libvpx-vp9 -b:v 0 -crf 38 -row-mt 1 -an final-loop.webm
```

The penguin is an original character; don't name or caption it after any existing franchise.
