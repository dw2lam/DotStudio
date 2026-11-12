import type { ReactNode } from "react";
import { Reveal } from "../components/Reveal";
import { SectionHeader } from "../components/SectionHeader";

const CREAM = "#E1E0CC";
const DOCS = "https://github.com/dw2lam/DotStudio/tree/main/docs/ai";
const COMMAND = 'claude mcp add dotstudio -- "/Applications/DotStudio.app/Contents/MacOS/dotstudio-mcp"';

/** A setting or a place in the app, set a shade brighter than the text around it. */
function K({ children }: { children: ReactNode }) {
  return <b className="font-normal text-gray-200">{children}</b>;
}

const FLOW = [
  {
    name: "It builds the style",
    body: "From DotStudio's scenes and looks, guided by its style guide, or a Metal shader scene of its own.",
  },
  {
    name: "It shows you first",
    body: "Previews as images, and a check of the GPU cost, before anything plays.",
  },
  {
    name: "It sets it, if you like",
    body: "As your screensaver or live wallpaper. Each change shows a small notice in the app.",
  },
];

export function MakeWithAI() {
  return (
    <section id="ai" className="relative bg-black px-4 py-20 sm:py-28 md:py-32">
      <div className="mx-auto max-w-7xl">
        <SectionHeader eyebrow="With AI" title="Make your own" aside="by describing it.">
          <p className="mt-5 max-w-xl text-xs leading-relaxed text-gray-400 sm:text-sm">
            DotStudio comes with an MCP server, so Claude, Cursor, VS Code, Codex CLI or any MCP client
            can design screensavers with you. Describe a mood; it does the rest.
          </p>
        </SectionHeader>

        <Reveal className="mx-auto max-w-5xl">
          <div className="rounded-2xl bg-[#161616] p-6 sm:p-8">
            <span className="text-xs text-gray-500">You say</span>
            <p className="mt-2 font-serif text-2xl italic leading-snug text-primary sm:text-3xl md:text-4xl">
              “Calm ocean at dusk, big clock, warm palette.”
            </p>

            <ol className="mt-8 grid grid-cols-1 gap-6 sm:mt-10 sm:grid-cols-3 sm:gap-8">
              {FLOW.map((f) => (
                <li key={f.name} className="border-t border-white/10 pt-4">
                  <h3 className="text-sm font-bold sm:text-base" style={{ color: CREAM }}>
                    {f.name}
                  </h3>
                  <p className="mt-1 text-xs leading-relaxed text-gray-400 sm:text-sm">{f.body}</p>
                </li>
              ))}
            </ol>
          </div>
        </Reveal>

        <Reveal y={10} scaleFrom={1} className="mx-auto mt-8 max-w-5xl sm:mt-10">
          <div className="grid grid-cols-1 gap-x-8 gap-y-5 border-t border-white/10 pt-6 text-xs leading-relaxed text-gray-500 sm:text-sm md:grid-cols-2">
            <div className="min-w-0">
              <p>
                <span className="text-gray-300">Set up in a click.</span> In{" "}
                <K>Settings → AI</K>, choose <K>Add to Claude Desktop</K>, or add it to Claude Code:
              </p>
              <code className="mt-3 block break-all rounded-lg bg-white/[0.05] px-3 py-2.5 font-mono text-[11px] text-gray-300 sm:text-xs">
                {COMMAND}
              </code>
            </div>
            <p>
              <span className="text-gray-300">You stay in charge.</span> Drop brand or style guides
              into the app's guides folder to steer it, and one setting stops the AI from changing
              what plays.{" "}
              <a
                href={DOCS}
                target="_blank"
                rel="noopener noreferrer"
                className="text-gray-300 underline decoration-white/20 underline-offset-4 transition-colors hover:text-primary"
              >
                Setup guide
              </a>
            </p>
          </div>
        </Reveal>
      </div>
    </section>
  );
}
