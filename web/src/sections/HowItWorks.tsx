import { useState, type ReactNode } from "react";
import { Reveal } from "../components/Reveal";
import { SectionHeader } from "../components/SectionHeader";

const CREAM = "#E1E0CC";
const DOCS = "https://github.com/dw2lam/DotStudio/tree/main/docs/ai";
const SERVER = "/Applications/DotStudio.app/Contents/MacOS/dotstudio-mcp";
const CLAUDE_CODE = `claude mcp add dotstudio -- "${SERVER}"`;

/** A setting or a place in the app, set a shade brighter than the text around it. */
function K({ children }: { children: ReactNode }) {
  return <b className="font-normal text-gray-200">{children}</b>;
}

function Code({ children }: { children: string }) {
  return (
    <code className="mt-3 block break-all rounded-lg bg-black/40 px-3 py-2.5 font-mono text-[11px] leading-relaxed text-gray-300 sm:text-xs">
      {children}
    </code>
  );
}

type ClientId = "desktop" | "code" | "other";

const CLIENTS: { id: ClientId; name: string; body: ReactNode }[] = [
  {
    id: "desktop",
    name: "Claude Desktop",
    body: (
      <>
        In DotStudio, open <K>Settings → AI</K> and choose <K>Add to Claude Desktop</K>. Then quit
        and reopen Claude.
      </>
    ),
  },
  {
    id: "code",
    name: "Claude Code",
    body: (
      <>
        Run this once, or use <K>Settings → AI → Copy Command</K>:
        <Code>{CLAUDE_CODE}</Code>
      </>
    ),
  },
  {
    id: "other",
    name: "Other apps",
    body: (
      <>
        Cursor, VS Code, Codex CLI or any MCP client: <K>Settings → AI → Copy JSON</K>, or run
        this command over stdio:
        <Code>{SERVER}</Code>
      </>
    ),
  },
];

function Connect() {
  const [client, setClient] = useState<ClientId>("desktop");
  const active = CLIENTS.find((c) => c.id === client)!;
  return (
    <>
      <div role="group" aria-label="Your AI app" className="-mx-0.5 mt-4 flex flex-wrap gap-1.5">
        {CLIENTS.map((c) => {
          const on = c.id === client;
          return (
            <button
              key={c.id}
              type="button"
              aria-pressed={on}
              onClick={() => setClient(c.id)}
              className={`rounded-full px-3 py-1 text-xs transition-colors duration-200 ${
                on ? "bg-primary text-black" : "bg-white/[0.06] text-gray-300 hover:bg-white/[0.1]"
              }`}
            >
              {c.name}
            </button>
          );
        })}
      </div>
      <p className="mt-4 text-xs leading-relaxed text-gray-400 sm:text-sm">{active.body}</p>
    </>
  );
}

const STEPS: { n: string; title: string; body: ReactNode }[] = [
  {
    n: "01",
    title: "Get DotStudio",
    body: (
      <>
        Download it and move it to <K>Applications</K> first: your AI app remembers where
        DotStudio's MCP server lives, inside the app.
      </>
    ),
  },
  { n: "02", title: "Connect your AI app", body: <Connect /> },
  {
    n: "03",
    title: "Ask for one",
    body: (
      <>
        Brief it like a designer:{" "}
        <span className="font-serif text-[1.05em] italic text-primary/80">
          “A calm ocean at dusk, and I want to see the time big.”
        </span>{" "}
        It reads DotStudio's guides, builds the style and shows you previews before anything plays.
      </>
    ),
  },
];

/** Setup for the MCP server the hero shows off: three steps, plus what to expect. */
export function HowItWorks() {
  return (
    <section id="how-it-works" className="relative scroll-mt-4 bg-black px-4 py-20 sm:py-28 md:py-32">
      <div className="mx-auto max-w-7xl">
        <SectionHeader eyebrow="MCP" title="How it works:" aside="three steps, then just ask.">
          <p className="mt-5 max-w-xl text-xs leading-relaxed text-gray-400 sm:text-sm">
            DotStudio comes with an MCP server, so Claude or any MCP app can design screensavers
            with you. Everything runs on your Mac.
          </p>
        </SectionHeader>

        <div className="grid grid-cols-1 gap-3 md:grid-cols-3">
          {STEPS.map((s, i) => (
            <Reveal key={s.n} index={i} className="h-full">
              <article className="flex h-full flex-col rounded-2xl bg-[#212121] p-6 sm:p-8">
                <span className="font-serif text-4xl italic text-primary/40 sm:text-5xl">{s.n}</span>
                <h3 className="mt-5 text-lg font-bold sm:text-xl" style={{ color: CREAM }}>
                  {s.title}
                </h3>
                <div className="mt-3 text-xs leading-relaxed text-gray-400 sm:text-sm">{s.body}</div>
              </article>
            </Reveal>
          ))}
        </div>

        <Reveal y={10} scaleFrom={1} className="mt-8 sm:mt-10">
          <div className="grid grid-cols-1 gap-x-8 gap-y-5 border-t border-white/10 pt-6 text-xs leading-relaxed text-gray-500 sm:text-sm md:grid-cols-2">
            <p>
              <span className="text-gray-300">Photoreal film scenes</span> like the one above need
              Blender 5.1 or later, which you install yourself from blender.org. You approve stills
              first; the loop then renders in the background, which takes hours and a few hundred MB.
            </p>
            <p>
              <span className="text-gray-300">You stay in charge.</span> It changes what plays only
              when you ask, and each change shows a notice in DotStudio with Undo; one switch in{" "}
              <K>Settings → AI</K> stops it altogether. Drop brand or style guides into the app's
              guides folder to steer it.{" "}
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
