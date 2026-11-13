/*
 * Every image and clip the MCP section (MCPDemo.tsx) shows, by slot. The files live in
 * public/media/mcp/; public/media/mcp/README.md lists each slot's size and format.
 *
 * To swap in the final renders, overwrite the files with the same names: nothing else
 * changes. (The current files are placeholders made from the Commute work-in-progress
 * stills; see the README.)
 */

const DIR = "/media/mcp/";

/** The build, in order: what Blender shows as the scene comes together. */
export type BuildStep = "layout" | "clay" | "materials" | "lit" | "graded";

export const MCP_MEDIA = {
  /** 1600 × 1000 stills of the build, one per step, all from the same camera except `layout`. */
  build: {
    layout: DIR + "layout.webp",
    clay: DIR + "clay.webp",
    materials: DIR + "materials.webp",
    lit: DIR + "lit.webp",
    graded: DIR + "graded.webp",
  } satisfies Record<BuildStep, string>,

  /** The loop render: a low-sample first frame, then one finished frame per variant. */
  render: {
    noisy: DIR + "render-noisy.webp",
    frames: {
      day: DIR + "frame-day.webp",
      golden: DIR + "frame-golden.webp",
      night: DIR + "frame-night.webp",
    },
  },

  /** The finished film scene, playing on the Mac. Seamless loop; poster = its first frame. */
  final: {
    webm: DIR + "final-loop.webm",
    mp4: DIR + "final-loop.mp4",
    poster: DIR + "final-poster.webp",
  },

  /** Intrinsic size of every still above (and of the loop's 16:10 frame). */
  width: 1600,
  height: 1000,
} as const;

export type Variant = keyof typeof MCP_MEDIA.render.frames;
export const VARIANTS = Object.keys(MCP_MEDIA.render.frames) as Variant[];

