/*
 * Every image and clip the MCP section (MCPDemo.tsx) shows, by slot. The files live in
 * public/media/mcp/ (README.md there lists sizes and formats); the desktop wallpaper is the
 * hero's own Golden Hour still. To swap in final renders, overwrite the files with the same
 * names: nothing else changes.
 */

const DIR = "/media/mcp/";

/** What DotStudio's preview shows while the scene comes together, in order. */
export type BuildStep = "layout" | "clay" | "lit" | "warm";

export const MCP_MEDIA = {
  /** The simulated Mac's desktop picture (already on the page: the hero's first scene). */
  wallpaper: "/media/loops/hero-tidewater.webp",
  /** DotStudio's library window, the real capture docs/app.png (16:10). */
  app: DIR + "app.webp",

  /** 1600 × 1000 stills, all from the same camera except `layout`. */
  build: {
    layout: DIR + "layout.webp",
    clay: DIR + "clay.webp",
    lit: DIR + "lit.webp",
    /** After "Make the light warmer." */
    warm: DIR + "warm.webp",
  } satisfies Record<BuildStep, string>,

  /** The finished scene as the screensaver: seamless loop; poster = its first frame. */
  final: {
    webm: DIR + "final-loop.webm",
    mp4: DIR + "final-loop.mp4",
    poster: DIR + "final-poster.webp",
  },

  /** Intrinsic size of every still (and the loop's 16:10 frame). */
  width: 1600,
  height: 1000,
} as const;
