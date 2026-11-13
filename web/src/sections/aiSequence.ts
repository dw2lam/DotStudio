import type { BuildStep, Variant } from "./mcpMedia";

/*
 * The MCP section's script: one session with DotStudio's MCP server, condensed to ~38 s.
 * Tool names, arguments and the shape of each answer are the server's own (MCP/Tools.swift,
 * MCP/ToolsCustom.swift, Guides/engines/film.md): film_status → list_film_templates →
 * create_film_scene → render_film_stills (the user approves) → render_film_loop →
 * film_job_status → create_style → set_screensaver (only because the user asked).
 * The log shows the main calls only (a real session also reads guides and checks film_status),
 * with results shortened for the page. Times are seconds from the start of the loop.
 */

export const PROMPT =
  "Make me a screensaver: a sunny commuter train, a penguin in a suit dozing on the end seat. Make it look real.";

export type ChapterId = "ask" | "build" | "render" | "play";

export const CHAPTERS: { id: ChapterId; n: string; name: string; start: number }[] = [
  { id: "ask", n: "01", name: "Ask", start: 0 },
  { id: "build", n: "02", name: "Build", start: 7.2 },
  { id: "render", n: "03", name: "Render", start: 18.4 },
  { id: "play", n: "04", name: "Play", start: 27.6 },
];

/** Length of one pass; the sequence then starts over. */
export const DURATION = 38;

/** The prompt types from TYPE_START to TYPE_END, then is "sent" at SENT. */
export const TYPE_START = 0.5;
export const TYPE_END = 3.4;
export const SENT = 3.8;

export type Entry =
  | { at: number; kind: "you"; text: string }
  | { at: number; kind: "ai"; text: string }
  | { at: number; kind: "tool"; name: string; args?: string; result: string; done: number };

export const LOG: Entry[] = [
  { at: SENT, kind: "you", text: PROMPT },
  { at: 4.3, done: 4.8, kind: "tool", name: "get_started", result: "DotStudio is running" },
  { at: 5.5, done: 6.1, kind: "tool", name: "list_film_templates", result: "commute: a train, a penguin on the end seat" },

  { at: 7.3, done: 8.1, kind: "tool", name: "create_film_scene", args: '"commute"', result: "Draft saved, with bloom, halation and grain" },
  { at: 12.4, done: 14.6, kind: "tool", name: "render_film_stills", result: "3 ray-traced stills: day, golden, night" },
  { at: 15.0, kind: "ai", text: "Here are the stills. Happy with the light?" },
  { at: 16.6, kind: "you", text: "Love it. Animate it, and set it as my screensaver." },

  { at: 18.6, done: 19.1, kind: "tool", name: "render_film_loop", result: "Rendering in the background" },
  { at: 22.0, done: 22.3, kind: "tool", name: "film_job_status", result: "38% · golden, frame 166 of 1,152" },
  { at: 26.7, done: 27.0, kind: "tool", name: "film_job_status", result: "Done · installed as a scene" },

  { at: 27.8, done: 28.2, kind: "tool", name: "create_style", args: '"Morning Commute"', result: "Added to your library" },
  { at: 28.6, done: 29.0, kind: "tool", name: "set_screensaver", result: "Playing now · Undo in DotStudio" },
  { at: 30.0, kind: "ai", text: "Done. It follows the sun: day, golden hour, then night." },
];

/** What the stage shows while building, from when. */
export const BUILD_STEPS: { id: BuildStep; at: number; name: string; detail: string }[] = [
  { id: "layout", at: 7.2, name: "Set", detail: "The Commute template, blocked out" },
  { id: "clay", at: 9.2, name: "Clay", detail: "Camera, carriage and passenger" },
  { id: "materials", at: 10.9, name: "Materials", detail: "CC0 textures" },
  { id: "lit", at: 12.6, name: "Light", detail: "Ray-traced sun and shadows, in Cycles" },
  { id: "graded", at: 14.6, name: "Look", detail: "Bloom, halation, live grain" },
];

/** The loop render: frames per variant (48 s × 24 fps) and the job's span on the clock. */
export const RENDER = {
  start: 19.1,
  end: 26.7,
  framesPerVariant: 1152,
  variants: ["day", "golden", "night"] as Variant[],
  /** Real time the job stands for, in minutes (EEVEE, 2560 × 1600, three variants). */
  minutes: 190,
};
