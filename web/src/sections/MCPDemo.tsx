import { useEffect, useRef, useState, type CSSProperties, type ReactNode } from "react";
import { AnimatePresence, motion, useReducedMotion, type Transition } from "framer-motion";
import { ArrowUp, Pause, Play } from "lucide-react";
import { WordsPullUpMultiStyle } from "../components/animations/WordsPullUpMultiStyle";
import { MCP_MEDIA } from "./mcpMedia";
import {
  BEATS,
  BUILD_STEPS,
  CHAT,
  COMMAND,
  DURATION,
  PROMPT,
  RENDER,
  SENT,
  TOOLS,
  composerAt,
  type BeatId,
  type Message,
} from "./aiSequence";

/*
 * "Now with MCP": a short chat with DotStudio connected over MCP, beside the scene it makes,
 * then three tiny setup steps. The demo (aiSequence.ts) runs ~30 s in four beats: the prompt
 * (the blank cycles through ideas), building and one tweak, a render (only some scenes need
 * one), and the result playing on a Mac display.
 *
 * It only runs while on screen and the tab is visible; it can be paused and the beat dots
 * seek. Media loads a beat ahead. Under prefers-reduced-motion: four still frames instead.
 * QA hook: `?ai=<seconds>` opens it paused at that moment.
 */

const CREAM = "#E1E0CC";
const SPRING: Transition = { type: "spring", duration: 1.0, bounce: 0 };
const DOCS = "https://github.com/dw2lam/DotStudio/tree/main/docs/ai";
const DOWNLOAD = "https://github.com/dw2lam/DotStudio/releases/latest/download/DotStudio.dmg";

const clamp01 = (x: number) => Math.min(1, Math.max(0, x));

function beatAt(t: number): BeatId {
  let id: BeatId = "prompt";
  for (const b of BEATS) if (t >= b.start) id = b.id;
  return id;
}

// --- Clock and visibility -----------------------------------------------------------------

function initialSeek(): number | null {
  if (typeof window === "undefined") return null;
  const v = new URLSearchParams(window.location.search).get("ai");
  const n = v === null ? NaN : Number(v);
  return Number.isFinite(n) ? Math.min(DURATION - 0.01, Math.max(0, n)) : null;
}

/** Seconds into the demo; advances (and wraps) only while `running`. ~20 updates a second. */
function useClock(running: boolean, start: number) {
  const [t, setT] = useState(start);
  const tRef = useRef(start);
  useEffect(() => {
    if (!running) return;
    let raf = 0;
    let last = performance.now();
    let shown = last;
    const tick = (now: number) => {
      const dt = Math.min(0.1, (now - last) / 1000); // a long frame doesn't jump the story
      last = now;
      const next = tRef.current + dt;
      const wrapped = next >= DURATION;
      tRef.current = wrapped ? 0 : next;
      if (wrapped || now - shown >= 50) {
        shown = now;
        setT(tRef.current);
      }
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [running]);
  const seek = (s: number) => {
    tRef.current = s;
    setT(s);
  };
  return [t, seek] as const;
}

function useOnScreen<T extends Element>() {
  const ref = useRef<T>(null);
  const [on, setOn] = useState(false);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    if (!("IntersectionObserver" in window)) {
      setOn(true);
      return;
    }
    const io = new IntersectionObserver(([e]) => setOn(e.isIntersecting), { threshold: 0.15 });
    io.observe(el);
    return () => io.disconnect();
  }, []);
  return [ref, on] as const;
}

function useTabVisible() {
  const [visible, setVisible] = useState(true);
  useEffect(() => {
    const sync = () => setVisible(document.visibilityState !== "hidden");
    sync();
    document.addEventListener("visibilitychange", sync);
    return () => document.removeEventListener("visibilitychange", sync);
  }, []);
  return visible;
}

// --- Section -------------------------------------------------------------------------------

export function MCPDemo() {
  const reduced = useReducedMotion() ?? false;
  return (
    <section id="mcp" aria-labelledby="mcp-title" className="relative scroll-mt-4 bg-black px-4 py-20 sm:py-28 md:py-32">
      <div className="mx-auto max-w-7xl">
        <header className="mb-8 sm:mb-12">
          <h2
            id="mcp-title"
            className="text-4xl font-medium leading-[0.95] tracking-[-0.04em] sm:text-5xl md:text-6xl"
            style={{ color: CREAM }}
          >
            <WordsPullUpMultiStyle
              className="!justify-start"
              segments={[
                { text: "Now with" },
                { text: "MCP.", className: "font-serif font-normal italic tracking-[-0.02em] text-primary/75" },
              ]}
            />
          </h2>
          <p className="mt-4 max-w-xl text-sm leading-relaxed text-gray-400 md:text-base">
            Any MCP app, on any model, can now make screensavers with DotStudio.
          </p>
        </header>

        {reduced ? <Storyboard /> : <Demo />}
        <Setup />
      </div>
    </section>
  );
}

/** Three tiny steps, inline. */
function Setup() {
  const k = "text-gray-300";
  return (
    <ol className="mt-10 grid grid-cols-1 gap-x-8 gap-y-4 border-t border-white/10 pt-6 text-xs leading-relaxed text-gray-500 sm:mt-12 sm:text-sm md:grid-cols-3">
      <li>
        <span className="mr-2 font-serif italic text-primary/40">01</span>
        <a href={DOWNLOAD} target="_blank" rel="noopener noreferrer" className={`${k} transition-colors hover:text-primary`}>
          Get DotStudio
        </a>
        , in Applications.
      </li>
      <li>
        <span className="mr-2 font-serif italic text-primary/40">02</span>
        <span className={k}>Connect your AI app</span> in Settings › AI: one click for Claude Desktop, or copy the
        command or JSON for any MCP app.
      </li>
      <li>
        <span className="mr-2 font-serif italic text-primary/40">03</span>
        <span className={k}>Ask.</span> Film scenes need Blender 5.1+.{" "}
        <a
          href={DOCS}
          target="_blank"
          rel="noopener noreferrer"
          className="whitespace-nowrap underline decoration-white/20 underline-offset-4 transition-colors hover:text-primary"
        >
          Setup guide
        </a>
      </li>
    </ol>
  );
}

// --- The demo ------------------------------------------------------------------------------

function Demo() {
  const seekFrom = useRef(initialSeek()).current;
  const [rootRef, onScreen] = useOnScreen<HTMLDivElement>();
  const tabVisible = useTabVisible();
  const [paused, setPaused] = useState(seekFrom !== null);
  const running = onScreen && tabVisible && !paused;
  const [t, seek] = useClock(running, seekFrom ?? 0);
  const beat = beatAt(t);
  const bi = BEATS.findIndex((b) => b.id === beat);

  // Load a beat ahead: the build stills while the prompt types, the loop while rendering.
  const [armed, setArmed] = useState(0);
  const want = t >= 13 || bi >= 2 ? 2 : t >= 1 || bi >= 1 ? 1 : 0;
  useEffect(() => {
    if (onScreen && want > armed) setArmed(want);
  }, [onScreen, want, armed]);

  return (
    <div ref={rootRef} className="grid grid-cols-1 gap-4 lg:grid-cols-12 lg:gap-6">
      <p className="sr-only">
        A demonstration: in an AI app with DotStudio connected over MCP, someone asks “{PROMPT}”. DotStudio builds
        the scene, the light is made warmer on request, the scene renders, and it is set as the Mac's screensaver.
      </p>
      <Chat t={t} className="lg:col-span-4" />
      <div className="min-w-0 lg:col-span-8">
        <Stage t={t} beat={beat} armed={armed} running={running} />
        <div className="mt-4 flex items-center justify-between">
          <div role="group" aria-label="Steps" className="flex items-center gap-1">
            {BEATS.map((b) => {
              const on = b.id === beat;
              return (
                <button
                  key={b.id}
                  type="button"
                  aria-label={b.name}
                  aria-current={on ? "step" : undefined}
                  onClick={() => seek(b.start + 0.01)}
                  className="group flex h-8 items-center px-1"
                >
                  <span
                    className={`block h-1.5 rounded-full transition-all duration-500 ${
                      on ? "w-6 bg-primary/80" : "w-1.5 bg-white/20 group-hover:bg-white/40"
                    }`}
                  />
                </button>
              );
            })}
          </div>
          <button
            type="button"
            onClick={() => setPaused((p) => !p)}
            aria-label={paused ? "Play the demonstration" : "Pause the demonstration"}
            className="flex h-8 w-8 items-center justify-center rounded-full bg-white/[0.06] text-gray-400 transition-colors hover:bg-white/[0.1] hover:text-primary"
          >
            {paused ? <Play className="h-3.5 w-3.5" /> : <Pause className="h-3.5 w-3.5" />}
          </button>
        </div>
      </div>
    </div>
  );
}

// --- Chat ----------------------------------------------------------------------------------

/** "/mcp DotStudio" set apart from the rest of a message. */
function WithCommand({ text }: { text: string }) {
  if (!text.startsWith("/")) return <>{text}</>;
  const head = text.slice(0, COMMAND.length);
  return (
    <>
      <span className="font-mono text-[0.92em] text-primary">{head}</span>
      {text.slice(COMMAND.length)}
    </>
  );
}

function Chat({ t, className = "" }: { t: number; className?: string }) {
  const shown = CHAT.filter((m) => m.at <= t);
  const typed = composerAt(t);
  const typing = t < SENT;
  return (
    <div
      aria-hidden="true"
      className={`flex h-[300px] flex-col overflow-hidden rounded-2xl bg-[#141414] ring-1 ring-white/[0.06] sm:h-[320px] lg:h-auto ${className}`}
    >
      <div className="flex items-center justify-between border-b border-white/[0.06] px-4 py-3 text-xs">
        <span className="text-gray-400">Your AI app</span>
        <span className="flex items-center gap-1.5 text-gray-500">
          <span className="h-1.5 w-1.5 rounded-full bg-[#7fbf8a]" />
          DotStudio
        </span>
      </div>

      <div
        className="relative min-h-0 flex-1"
        style={{
          maskImage: "linear-gradient(to bottom, transparent 0, #000 22%)",
          WebkitMaskImage: "linear-gradient(to bottom, transparent 0, #000 22%)",
        }}
      >
        <div className="absolute inset-x-0 bottom-0 flex flex-col gap-2.5 px-4 pb-3">
          <AnimatePresence initial={false}>
            {shown.map((m) => (
              <motion.div
                key={m.at}
                layout="position"
                initial={{ opacity: 0, y: 10 }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0, transition: { duration: 0.3 } }}
                transition={SPRING}
                className={m.from === "you" ? "flex justify-end" : ""}
              >
                <Bubble m={m} />
              </motion.div>
            ))}
          </AnimatePresence>
        </div>
      </div>

      <div className="px-3 pb-3">
        <div className="flex min-h-[44px] items-end gap-2 rounded-xl bg-black/40 py-2 pl-3 pr-2 ring-1 ring-white/[0.06]">
          <p className="min-w-0 flex-1 py-1 text-[13px] leading-snug text-gray-200">
            {typed ? <WithCommand text={typed} /> : <span className="text-gray-600">Ask anything</span>}
            {typing && typed && <span className="caret-blink ml-px inline-block h-[1em] w-px translate-y-[0.15em] bg-primary" />}
          </p>
          <span
            className={`flex h-7 w-7 shrink-0 items-center justify-center rounded-full transition-colors duration-300 ${
              typed ? "bg-primary text-black" : "bg-white/[0.06] text-gray-600"
            }`}
          >
            <ArrowUp className="h-3.5 w-3.5" />
          </span>
        </div>
      </div>
    </div>
  );
}

function Bubble({ m }: { m: Message }) {
  if (m.from === "you") {
    return (
      <p className="max-w-[88%] rounded-2xl rounded-br-md bg-white/[0.08] px-3.5 py-2 text-[13px] leading-snug text-gray-100">
        <WithCommand text={m.text} />
      </p>
    );
  }
  return (
    <div className="max-w-[92%] text-[13px] leading-snug text-gray-300">
      <p>{m.text}</p>
      {m.tools && (
        <p
          className="mt-1.5 flex gap-1 overflow-hidden whitespace-nowrap"
          style={{ maskImage: "linear-gradient(to right, #000 85%, transparent)", WebkitMaskImage: "linear-gradient(to right, #000 85%, transparent)" }}
        >
          {TOOLS.map((tool) => (
            <span key={tool} className="rounded-md bg-white/[0.05] px-1.5 py-0.5 font-mono text-[10px] text-gray-500">
              {tool}
            </span>
          ))}
        </p>
      )}
    </div>
  );
}

// --- Stage ---------------------------------------------------------------------------------

function Stage({ t, beat, armed, running }: { t: number; beat: BeatId; armed: number; running: boolean }) {
  const enjoy = beat === "enjoy";
  let step: (typeof BUILD_STEPS)[number] | null = null;
  for (const s of BUILD_STEPS) if (t >= s.at) step = s;
  const rendering = beat === "render";
  const progress = clamp01((t - RENDER.start) / (RENDER.end - RENDER.start));

  const videoRef = useRef<HTMLVideoElement>(null);
  useEffect(() => {
    const v = videoRef.current;
    if (!v) return;
    if (enjoy && running) v.play().catch(() => {});
    else v.pause();
  }, [enjoy, running, armed]);

  return (
    <div className="relative aspect-[16/10] w-full">
      {/* The screen: fills the stage while building, then settles into a Mac display. */}
      <motion.div
        className="absolute inset-0 overflow-hidden bg-[#0f0f0e]"
        initial={false}
        animate={
          enjoy
            ? {
                scale: 0.8,
                y: "-7.5%",
                borderRadius: 10,
                boxShadow: "0 0 0 9px #050505, 0 0 0 10px rgba(255,255,255,0.13), 0 40px 90px -30px rgba(0,0,0,0.95)",
              }
            : {
                scale: 1,
                y: "0%",
                borderRadius: 16,
                boxShadow: "0 0 0 0px #050505, 0 0 0 1px rgba(255,255,255,0.06), 0 30px 80px -30px rgba(0,0,0,0.9)",
              }
        }
        transition={SPRING}
      >
        {/* Before anything is built: just the app, waiting. */}
        <div
          aria-hidden="true"
          className="absolute inset-0 z-[3] flex items-center justify-center bg-[radial-gradient(50%_50%_at_50%_50%,rgba(222,219,200,0.06),transparent_70%)] transition-opacity duration-700"
          style={{ opacity: step ? 0 : 1 }}
        >
          <img src="/icon.png" alt="" width={56} height={56} className="h-12 w-12 rounded-xl opacity-60 sm:h-14 sm:w-14" />
        </div>

        {armed >= 1 &&
          BUILD_STEPS.map((s) => (
            <Still key={s.id} src={MCP_MEDIA.build[s.id]} on={!enjoy && step?.id === s.id} />
          ))}

        {armed >= 2 && (
          <div
            className="absolute inset-0 transition-opacity duration-1000 ease-out"
            style={{ opacity: enjoy ? 1 : 0, zIndex: enjoy ? 3 : 1 }}
          >
            <img
              src={MCP_MEDIA.final.poster}
              alt=""
              width={MCP_MEDIA.width}
              height={MCP_MEDIA.height}
              decoding="async"
              className="absolute inset-0 h-full w-full object-cover"
            />
            <video
              ref={videoRef}
              className="absolute inset-0 h-full w-full object-cover"
              poster={MCP_MEDIA.final.poster}
              muted
              loop
              playsInline
              preload="auto"
              disablePictureInPicture
              aria-hidden="true"
              tabIndex={-1}
            >
              <source src={MCP_MEDIA.final.webm} type={`video/webm; codecs="vp9"`} />
              <source src={MCP_MEDIA.final.mp4} type="video/mp4" />
            </video>
          </div>
        )}

        {/* Live grain, as DotStudio adds it at playback. */}
        <div
          aria-hidden="true"
          className={`noise-overlay pointer-events-none absolute inset-0 z-[4] mix-blend-overlay transition-opacity duration-700 ${
            running ? "grain-live" : ""
          }`}
          style={{ opacity: enjoy ? 0.4 : 0 }}
        />

        {/* Rendering: the picture dims, one small bar. */}
        <div
          aria-hidden="true"
          className="absolute inset-0 z-[5] flex items-center justify-center bg-black/45 transition-opacity duration-500"
          style={{ opacity: rendering ? 1 : 0 }}
        >
          <div className="w-[38%] min-w-[150px] text-center">
            <p className="text-xs text-white/85 sm:text-sm">{progress >= 1 ? "Rendered" : "Rendering…"}</p>
            <div className="mt-2.5 h-[3px] overflow-hidden rounded-full bg-white/20">
              <div className="h-full rounded-full bg-primary" style={{ width: `${progress * 100}%` }} />
            </div>
          </div>
        </div>
      </motion.div>

      <Stand on={enjoy} />
    </div>
  );
}

function Stand({ on, still = false }: { on: boolean; still?: boolean }) {
  return (
    <motion.div
      aria-hidden="true"
      className="absolute left-1/2 top-[83%] h-[12.5%] w-[15%] -translate-x-1/2"
      initial={false}
      animate={{ opacity: on ? 1 : 0, y: on ? 0 : 12 }}
      transition={still ? { duration: 0 } : on ? { ...SPRING, delay: 0.25 } : { duration: 0.3 }}
    >
      <div className="mx-auto h-[86%] w-full rounded-b-[3px] bg-gradient-to-b from-[#1c1c1c] via-[#2a2a29] to-[#232322]" />
      <div className="mx-[-55%] h-[14%] rounded-[3px] bg-gradient-to-b from-[#3a3a38] to-[#1d1d1c] shadow-[0_8px_20px_rgba(0,0,0,0.6)]" />
    </motion.div>
  );
}

/** One full-frame still that fades in over whatever is up, then holds with a slow push-in. */
function Still({ src, on }: { src: string; on: boolean }) {
  const style: CSSProperties = on
    ? {
        opacity: 1,
        zIndex: 2,
        transform: "scale(1.04)",
        transition: "opacity 900ms cubic-bezier(0.4,0,0.2,1), transform 9s cubic-bezier(0.2,0,0.4,1)",
      }
    : {
        opacity: 0,
        zIndex: 1,
        transform: "scale(1)",
        transition: "opacity 400ms ease 900ms, transform 0s linear 1300ms",
      };
  return (
    <img
      src={src}
      alt=""
      width={MCP_MEDIA.width}
      height={MCP_MEDIA.height}
      decoding="async"
      className="absolute inset-0 h-full w-full object-cover"
      style={style}
    />
  );
}

// --- Reduced motion: four still frames -----------------------------------------------------

function Frame({ children }: { children: ReactNode }) {
  return (
    <div className="relative aspect-[16/10] overflow-hidden rounded-xl bg-[#0f0f0e] ring-1 ring-white/[0.06]" aria-hidden="true">
      {children}
    </div>
  );
}

function Img({ src }: { src: string }) {
  return (
    <img
      src={src}
      alt=""
      width={MCP_MEDIA.width}
      height={MCP_MEDIA.height}
      loading="lazy"
      decoding="async"
      className="absolute inset-0 h-full w-full object-cover"
    />
  );
}

function Storyboard() {
  const frames: { caption: string; frame: ReactNode }[] = [
    {
      caption: "Ask in any MCP app.",
      frame: (
        <div className="absolute inset-0 flex items-center p-[7%]">
          <p className="rounded-2xl rounded-br-md bg-white/[0.08] px-3 py-2 text-[11px] leading-snug text-gray-100 sm:text-xs">
            <WithCommand text={PROMPT} />
          </p>
        </div>
      ),
    },
    { caption: "It builds the scene with you.", frame: <Img src={MCP_MEDIA.build.lit} /> },
    {
      caption: "It renders, if needed.",
      frame: (
        <>
          <Img src={MCP_MEDIA.build.warm} />
          <div className="absolute inset-0 flex items-center justify-center bg-black/45">
            <div className="w-[45%]">
              <p className="text-center text-[11px] text-white/85">Rendering…</p>
              <div className="mt-2 h-[3px] overflow-hidden rounded-full bg-white/20">
                <div className="h-full w-3/5 rounded-full bg-primary" />
              </div>
            </div>
          </div>
        </>
      ),
    },
    {
      caption: "Then it's your screensaver.",
      frame: (
        <>
          <div className="absolute left-[10%] top-[3%] h-[80%] w-[80%] overflow-hidden rounded-[6px] shadow-[0_0_0_5px_#050505,0_0_0_6px_rgba(255,255,255,0.13)]">
            <Img src={MCP_MEDIA.final.poster} />
          </div>
          <Stand on still />
        </>
      ),
    },
  ];
  return (
    <ol className="grid grid-cols-2 gap-x-3 gap-y-5 sm:gap-x-4 lg:grid-cols-4">
      {frames.map((f, i) => (
        <li key={f.caption}>
          <Frame>{f.frame}</Frame>
          <p className="mt-2.5 text-xs leading-snug text-gray-400 sm:text-sm">
            <span className="mr-1.5 font-serif italic text-primary/40">{String(i + 1).padStart(2, "0")}</span>
            {f.caption}
          </p>
        </li>
      ))}
    </ol>
  );
}
