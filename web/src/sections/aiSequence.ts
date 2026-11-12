import type { BuildStep, Variant } from "./mcpMedia";

/*
 * The AI hero's script: one session with DotStudio's MCP server, condensed to ~38 s.
 * Tool names, arguments and the shape of each answer are the server's own (MCP/Tools.swift,
 * MCP/ToolsCustom.swift, Guides/engines/film.md): film_status → list_film_templates →
 * create_film_scene → render_film_stills (the user approves) → render_film_loop →
 * film_job_status → create_style → set_screensaver (only because the user asked).
 * Results are shortened for the page. Times are seconds from the start of the loop.
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
  { at: 4.2, done: 4.6, kind: "tool", name: "get_started", result: "DotStudio is running; guides to read first" },
  { at: 4.8, done: 5.2, kind: "tool", name: "read_guide", args: '"engines/film"', result: "The film flow, budgets and loop rules" },
  { at: 5.4, done: 5.9, kind: "tool", name: "film_status", result: "Blender 5.1 · film engine pulled · Apple GPU" },
  { at: 6.1, done: 6.6, kind: "tool", name: "list_film_templates", result: "commute: a train interior, a penguin on the end seat" },

  { at: 7.3, done: 8.1, kind: "tool", name: "create_film_scene", args: '"commute"', result: "Saved draft film-4c1e9a07 · bloom 0.25, halation 0.15, grain 0.2" },
  { at: 12.4, done: 14.6, kind: "tool", name: "render_film_stills", args: "day, golden, night", result: "3 stills, ray-traced in Cycles" },
  { at: 15.0, kind: "ai", text: "Here are the stills. Happy with the light before I animate it?" },
  { at: 16.6, kind: "you", text: "Love it. Animate it, and set it as my screensaver." },

  { at: 18.6, done: 19.1, kind: "tool", name: "render_film_loop", args: "day, golden, night", result: "Started loop-8d2f61b3 in the background" },
  { at: 21.2, done: 21.5, kind: "tool", name: "film_job_status", result: "running, 28% — day, frame 954 of 1,152, about 137 min left" },
  { at: 23.6, done: 23.9, kind: "tool", name: "film_job_status", result: "running, 59% — golden, frame 894 of 1,152, about 78 min left" },
  { at: 26.7, done: 27.0, kind: "tool", name: "film_job_status", result: "done · installed film-4c1e9a07-b7d2" },

  { at: 27.8, done: 28.2, kind: "tool", name: "create_style", args: '"Morning Commute"', result: "Created “Morning Commute”" },
  { at: 28.6, done: 29.0, kind: "tool", name: "set_screensaver", args: '"Morning Commute"', result: "Your screensaver now plays it · Undo in DotStudio" },
  { at: 30.0, kind: "ai", text: "Done. It follows the sun: the day, golden and night loops play in turn as your day goes." },
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
