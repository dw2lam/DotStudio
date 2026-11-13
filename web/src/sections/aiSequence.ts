import type { BuildStep } from "./mcpMedia";

/*
 * The MCP demo's script: a short chat with DotStudio connected over MCP, ~30 s, in four
 * beats. Times are seconds from the start of the loop.
 */

export const COMMAND = "/mcp DotStudio";
export const LEAD = " — create me a ";

/** The blank cycles through a few ideas, then settles on the last one. */
export const IDEAS = ["calm ocean at dusk", "pixel cat on an LED panel", "sunny train ride with a sleepy penguin"];

export const PROMPT = COMMAND + LEAD + IDEAS[IDEAS.length - 1];

export type BeatId = "prompt" | "build" | "render" | "enjoy";

export const BEATS: { id: BeatId; name: string; start: number }[] = [
  { id: "prompt", name: "Prompt", start: 0 },
  { id: "build", name: "Build", start: 7.4 },
  { id: "render", name: "Render", start: 15.0 },
  { id: "enjoy", name: "Enjoy", start: 20.8 },
];

export const DURATION = 30;

/** When the prompt is sent. */
export const SENT = 7.4;

/**
 * The composer's text at `t`: the lead types out, then each idea types in, holds and (all
 * but the last) backspaces away.
 */
export function composerAt(t: number): string {
  if (t >= SENT) return "";
  const head = COMMAND + LEAD;
  const LEAD_END = 1.6;
  if (t < 0.4) return "";
  if (t < LEAD_END) return head.slice(0, Math.round(((t - 0.4) / (LEAD_END - 0.4)) * head.length));
  // Each idea: type (0.04 s a letter), hold, delete (0.015 s a letter).
  let at = LEAD_END + 0.1;
  for (let i = 0; i < IDEAS.length; i++) {
    const idea = IDEAS[i];
    const typed = at + idea.length * 0.04;
    if (t < typed) return head + idea.slice(0, Math.max(0, Math.round((t - at) / 0.04)));
    const last = i === IDEAS.length - 1;
    const held = typed + (last ? 99 : 0.5);
    if (t < held) return head + idea;
    const gone = held + idea.length * 0.015;
    if (t < gone) return head + idea.slice(0, idea.length - Math.round((t - held) / 0.015));
    at = gone + 0.15;
  }
  return head;
}

export type Message = { at: number; from: "you" | "ai"; text: string; tools?: boolean };

export const CHAT: Message[] = [
  { at: SENT, from: "you", text: PROMPT },
  { at: 8.0, from: "ai", text: "On it.", tools: true },
  { at: 10.9, from: "ai", text: "Here's a first look." },
  { at: 12.1, from: "you", text: "Make the light warmer." },
  { at: 13.8, from: "ai", text: "Done." },
  { at: 15.2, from: "ai", text: "This one's prerendered, so it's rendering now. Most scenes play live." },
  { at: 21.2, from: "ai", text: "Set as your screensaver. Enjoy." },
];

/** The tools that do the work, shown once as a single line of chips (the MCP server's real names). */
export const TOOLS = ["create_film_scene", "render_film_stills", "set_screensaver"];

/** What the stage shows while building, from when. */
export const BUILD_STEPS: { id: BuildStep; at: number }[] = [
  { id: "layout", at: 8.0 },
  { id: "clay", at: 9.3 },
  { id: "lit", at: 10.6 },
  { id: "warm", at: 13.5 },
];

/** The render, for scenes that need one. */
export const RENDER = { start: 15.4, end: 20.4 };
