import { useEffect, useRef, useState, type CSSProperties, type ReactNode } from "react";
import { AnimatePresence, motion, useReducedMotion, type Transition } from "framer-motion";
import { Check, Pause, Play } from "lucide-react";
import { WordsPullUpMultiStyle } from "../components/animations/WordsPullUpMultiStyle";
import { MCP_MEDIA, VARIANTS } from "./mcpMedia";
import {
  BUILD_STEPS,
  CHAPTERS,
  DURATION,
  LOG,
  PROMPT,
  RENDER,
  SENT,
  TYPE_END,
  TYPE_START,
  type ChapterId,
  type Entry,
} from "./aiSequence";

/*
 * The section after the hero (the hero's NEW pill links here): DotStudio's MCP server, shown working. One ~38 s pass of a real
 * session (aiSequence.ts): the prompt is typed, the AI's tool calls arrive in the log, the
 * stage shows Blender building the scene (layout → clay → materials → light → look), the
 * loop rendering, and the finished loop playing on a Mac display.
 *
 * The clock only runs while the sequence is on screen and the tab is visible; it can be paused,
 * and the chapter tabs seek. Media loads a chapter ahead. Under prefers-reduced-motion there
 * is no clock at all: a static storyboard of the four chapters stands in.
 *
 * QA hook: `?ai=<seconds>` opens the sequence paused at that moment.
 */

const CREAM = "#E1E0CC";
const EASE = [0.16, 1, 0.3, 1] as const;
/** The soft, critically damped spring the Now Playing demo uses. */
const SPRING: Transition = { type: "spring", duration: 1.0, bounce: 0 };

const clamp01 = (x: number) => Math.min(1, Math.max(0, x));
const num = (n: number) => n.toLocaleString("en-US");

function chapterAt(t: number): ChapterId {
  let id: ChapterId = "ask";
  for (const c of CHAPTERS) if (t >= c.start) id = c.id;
  return id;
}

/** The loop render's progress at `t`, as film_job_status would report it. */
function renderAt(t: number) {
  const p = clamp01((t - RENDER.start) / (RENDER.end - RENDER.start));
  const total = RENDER.framesPerVariant * RENDER.variants.length;
  const frame = Math.min(total - 1, Math.floor(p * total));
  const vi = Math.floor(frame / RENDER.framesPerVariant);
  return {
    p,
    variant: RENDER.variants[vi],
    vi,
    frame: Math.max(1, frame - vi * RENDER.framesPerVariant),
    minutes: Math.round((1 - p) * RENDER.minutes),
  };
}

// --- The clock ---------------------------------------------------------------------------

function initialSeek(): number | null {
  if (typeof window === "undefined") return null;
  const v = new URLSearchParams(window.location.search).get("ai");
  const n = v === null ? NaN : Number(v);
  return Number.isFinite(n) ? Math.min(DURATION - 0.01, Math.max(0, n)) : null;
}

/** Seconds into the sequence; advances (and wraps) only while `running`. ~20 updates a second. */
function useClock(running: boolean, start: number) {
  const [t, setT] = useState(start);
  const tRef = useRef(start);
  useEffect(() => {
    if (!running) return;
    let raf = 0;
    let last = performance.now();
    let shown = last;
    const tick = (now: number) => {
      // A long frame (a background tab, a jank) doesn't jump the story ahead.
      const dt = Math.min(0.1, (now - last) / 1000);
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
    <section id="ai" aria-labelledby="ai-title" className="relative scroll-mt-4 bg-black px-4 py-20 sm:py-28 md:py-32">
      <div className="mx-auto max-w-7xl">
        <header className="mb-8 flex flex-col gap-4 sm:mb-12 lg:flex-row lg:items-end lg:justify-between lg:gap-10">
          <h2
            id="ai-title"
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
          <p className="max-w-md text-sm leading-relaxed text-gray-400 md:text-base lg:pb-1 lg:text-right">
            Claude, or any MCP app, can build, render and set screensavers in DotStudio.{" "}
            <a
              href="#how-it-works"
              className="whitespace-nowrap text-primary/85 underline decoration-white/20 underline-offset-4 transition-colors hover:text-primary"
            >
              How it works
            </a>
          </p>
        </header>

        <div className="grid grid-cols-1 gap-x-10 gap-y-6 lg:grid-cols-12">
          {reduced ? (
            <div className="lg:col-span-12">
              <Storyboard />
            </div>
          ) : (
            <Sequence />
          )}
        </div>
      </div>
    </section>
  );
}

// --- The animated sequence -----------------------------------------------------------------

function Sequence() {
  const seekFrom = useRef(initialSeek()).current;
  const [rootRef, onScreen] = useOnScreen<HTMLDivElement>();
  const tabVisible = useTabVisible();
  const [paused, setPaused] = useState(seekFrom !== null);
  const [t, seek] = useClock(onScreen && tabVisible && !paused, seekFrom ?? 0);
  const chapter = chapterAt(t);
  const ci = CHAPTERS.findIndex((c) => c.id === chapter);

  // Load a chapter ahead: the build stills while the prompt types, the loop before Play.
  const [armed, setArmed] = useState(0);
  const want = t >= 17 || ci >= 3 ? 3 : t >= 7 || ci >= 2 ? 2 : t >= 1.2 || ci >= 1 ? 1 : 0;
  useEffect(() => {
    if (onScreen && want > armed) setArmed(want);
  }, [onScreen, want, armed]);

  const running = onScreen && tabVisible && !paused;
  return (
    <>
      <div ref={rootRef} className="min-w-0 lg:col-span-8">
        <p className="sr-only">
          A demonstration, in four chapters. Ask: “{PROMPT}” The AI calls DotStudio's tools get_started, read_guide,
          film_status and list_film_templates. Build: create_film_scene starts from the Commute template; Blender
          builds the set, then clay, materials, ray-traced light and the film look; render_film_stills shows three
          stills, and the user approves. Render: render_film_loop renders a seamless loop for day, golden hour and
          night in the background, checked with film_job_status. Play: create_style and set_screensaver, and the
          loop plays as the Mac's screensaver.
        </p>
        <Stage t={t} chapter={chapter} armed={armed} running={running} />
        <Chapters t={t} chapter={chapter} paused={paused} onSeek={seek} onToggle={() => setPaused((p) => !p)} />
      </div>
      <Log t={t} className="lg:col-span-4" />
    </>
  );
}

// --- Stage ---------------------------------------------------------------------------------

function Stage({ t, chapter, armed, running }: { t: number; chapter: ChapterId; armed: number; running: boolean }) {
  const play = chapter === "play";
  const r = renderAt(t);

  let step = BUILD_STEPS[0];
  for (const s of BUILD_STEPS) if (t >= s.at) step = s;

  // Which picture is up.
  const showing =
    chapter === "build"
      ? `build:${step.id}`
      : chapter === "render"
        ? t < RENDER.start + 0.8
          ? "noisy"
          : `frame:${r.variant}`
        : play
          ? "final"
          : "none";

  const videoRef = useRef<HTMLVideoElement>(null);
  useEffect(() => {
    const v = videoRef.current;
    if (!v) return;
    if (play && running) v.play().catch(() => {});
    else v.pause();
  }, [play, running, armed]);

  return (
    <div className="relative aspect-[16/10] w-full" style={{ containerType: "inline-size" }}>
      {/* The screen: fills the stage while building, then settles into a Mac display. */}
      <motion.div
        className="absolute inset-0 overflow-hidden bg-[#0f0f0e]"
        initial={false}
        animate={
          play
            ? {
                scale: 0.8,
                y: "-7.5%",
                borderRadius: 10,
                boxShadow:
                  "0 0 0 9px #050505, 0 0 0 10px rgba(255,255,255,0.13), 0 40px 90px -30px rgba(0,0,0,0.95)",
              }
            : {
                scale: 1,
                y: "0%",
                borderRadius: 14,
                boxShadow: "0 0 0 0px #050505, 0 0 0 1px rgba(255,255,255,0.06), 0 30px 80px -30px rgba(0,0,0,0.9)",
              }
        }
        transition={SPRING}
      >
        <AskLayer t={t} on={chapter === "ask"} />

        {armed >= 1 &&
          BUILD_STEPS.map((s) => (
            <Still key={s.id} src={MCP_MEDIA.build[s.id]} on={showing === `build:${s.id}`} />
          ))}
        {armed >= 2 && (
          <>
            <Still src={MCP_MEDIA.render.noisy} on={showing === "noisy"} still />
            {VARIANTS.map((v) => (
              <Still key={v} src={MCP_MEDIA.render.frames[v]} on={showing === `frame:${v}`} still />
            ))}
          </>
        )}
        {armed >= 3 && (
          <div
            className="absolute inset-0 transition-opacity duration-1000 ease-out"
            style={{ opacity: play ? 1 : 0, zIndex: play ? 3 : 1 }}
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

        {/* Live film grain: DotStudio adds it at playback, so it's live here too. */}
        <div
          aria-hidden="true"
          className={`noise-overlay pointer-events-none absolute inset-0 z-[4] mix-blend-overlay transition-opacity duration-700 ${
            running ? "grain-live" : ""
          }`}
          style={{ opacity: play || (chapter === "build" && step.id === "graded") ? 0.42 : 0 }}
        />

        {/* Blender's chapters get a quiet scrim and their captions. */}
        <div
          aria-hidden="true"
          className="pointer-events-none absolute inset-0 z-[5] bg-gradient-to-t from-black/70 via-black/0 to-black/25 transition-opacity duration-700"
          style={{ opacity: chapter === "build" || chapter === "render" ? 1 : 0 }}
        />
        <Corner on={chapter === "build" || chapter === "render"}>
          Blender 5.1 · {chapter === "render" ? "EEVEE" : step.id === "lit" || step.id === "graded" ? "Cycles" : "Viewport"}
        </Corner>
        <StepCaption chapter={chapter} step={step} />
        <RenderReadout on={chapter === "render"} r={r} />
      </motion.div>

      {/* The display's stand, rising in under the screen. */}
      <motion.div
        aria-hidden="true"
        className="absolute left-1/2 top-[83%] h-[12.5%] w-[15%] -translate-x-1/2"
        initial={false}
        animate={{ opacity: play ? 1 : 0, y: play ? 0 : 12 }}
        transition={play ? { ...SPRING, delay: 0.25 } : { duration: 0.3 }}
      >
        <div className="mx-auto h-[86%] w-full rounded-b-[3px] bg-gradient-to-b from-[#1c1c1c] via-[#2a2a29] to-[#232322]" />
        <div className="mx-[-55%] h-[14%] rounded-[3px] bg-gradient-to-b from-[#3a3a38] to-[#1d1d1c] shadow-[0_8px_20px_rgba(0,0,0,0.6)]" />
      </motion.div>

      {/* What's playing, beside the stand. */}
      <motion.div
        className="absolute bottom-[1.5%] left-[10%] hidden max-w-[32%] sm:block"
        initial={false}
        animate={{ opacity: play && t >= 29.2 ? 1 : 0, y: play && t >= 29.2 ? 0 : 6 }}
        transition={{ duration: 0.6, ease: EASE }}
      >
        <p className="truncate text-[11px] leading-tight sm:text-sm" style={{ color: CREAM }}>
          Morning Commute
        </p>
        <p className="truncate text-[10px] leading-tight text-gray-500 sm:text-xs">Your screensaver now</p>
      </motion.div>
    </div>
  );
}

/** One full-frame still that fades in over whatever is up, then holds with a slow push-in. */
function Still({ src, on, still = false }: { src: string; on: boolean; still?: boolean }) {
  const style: CSSProperties = on
    ? {
        opacity: 1,
        zIndex: 2,
        transform: still ? "scale(1)" : "scale(1.04)",
        transition: "opacity 900ms cubic-bezier(0.4,0,0.2,1), transform 9s cubic-bezier(0.2,0,0.4,1)",
      }
    : {
        opacity: 0,
        zIndex: 1,
        transform: "scale(1)",
        // Stay up under the next picture while it fades in, then go.
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

function AskLayer({ t, on }: { t: number; on: boolean }) {
  const n = Math.round(clamp01((t - TYPE_START) / (TYPE_END - TYPE_START)) * PROMPT.length);
  const typing = t < SENT;
  const tool = [...LOG].reverse().find((e): e is Extract<Entry, { kind: "tool" }> => e.kind === "tool" && e.at <= t);
  return (
    <div
      aria-hidden="true"
      className="absolute inset-0 z-[3] flex flex-col justify-between p-[5.5cqw] transition-opacity duration-700"
      style={{ opacity: on ? 1 : 0, pointerEvents: on ? "auto" : "none" }}
    >
      <div
        className="pointer-events-none absolute inset-0 -z-10 bg-[radial-gradient(70%_60%_at_30%_35%,rgba(222,219,200,0.06),transparent_70%)]"
      />
      <div>
        <p
          className="font-serif italic leading-[1.12] text-primary"
          style={{ fontSize: "max(17px, 4.3cqw)" }}
        >
          <span className="font-serif">{PROMPT.slice(0, n)}</span>
          <span
            className={`ml-[0.06em] inline-block h-[0.95em] w-[2px] translate-y-[0.14em] bg-primary/80 ${
              typing ? "caret-blink" : "opacity-0"
            }`}
          />
          {/* Reserve the whole prompt's space, so nothing moves as it types. */}
          <span className="invisible font-serif">{PROMPT.slice(n)}</span>
        </p>
      </div>
      <div className="h-[max(16px,2.2cqw)] text-[max(10px,1.45cqw)] text-gray-500">
        <AnimatePresence mode="wait">
          {tool && (
            <motion.span
              key={tool.name}
              initial={{ opacity: 0, y: 4 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: -4 }}
              transition={{ duration: 0.3 }}
              className="inline-flex items-center gap-2"
            >
              <Dot done={t >= tool.done} />
              <span>
                DotStudio · <span className="font-mono text-gray-300">{tool.name}</span>
              </span>
            </motion.span>
          )}
        </AnimatePresence>
      </div>
    </div>
  );
}

function Corner({ on, children }: { on: boolean; children: ReactNode }) {
  return (
    <div
      aria-hidden="true"
      className="absolute left-[2.4cqw] top-[2.2cqw] z-[6] flex items-center gap-1.5 text-[max(9px,1.2cqw)] tracking-wide text-white/70 transition-opacity duration-500"
      style={{ opacity: on ? 1 : 0 }}
    >
      <span className="h-1.5 w-1.5 rounded-full bg-[#e8a33c] shadow-[0_0_8px_#e8a33c]" />
      {children}
    </div>
  );
}

function StepCaption({ chapter, step }: { chapter: ChapterId; step: (typeof BUILD_STEPS)[number] }) {
  const on = chapter === "build";
  return (
    <div aria-hidden="true" className="absolute bottom-[2.6cqw] left-[2.6cqw] right-[2.6cqw] z-[6]">
      <AnimatePresence mode="wait">
        {on && (
          <motion.div
            key={step.id}
            initial={{ opacity: 0, y: 8 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0, y: -4 }}
            transition={{ duration: 0.45, ease: EASE }}
            className="flex items-baseline gap-2 text-[max(11px,1.55cqw)]"
          >
            <span className="font-serif italic text-primary/60">
              {String(BUILD_STEPS.findIndex((s) => s.id === step.id) + 1).padStart(2, "0")}
            </span>
            <span style={{ color: CREAM }}>{step.name}</span>
            <span className="truncate text-white/55">{step.detail}</span>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}

function RenderReadout({ on, r }: { on: boolean; r: ReturnType<typeof renderAt> }) {
  return (
    <div
      aria-hidden="true"
      className="absolute inset-x-[2.6cqw] bottom-[2.4cqw] z-[6] transition-opacity duration-500"
      style={{ opacity: on ? 1 : 0 }}
    >
      <div className="flex items-end justify-between gap-3 text-[max(10px,1.45cqw)] leading-tight">
        <div className="min-w-0">
          <div className="hidden items-center gap-[1.4cqw] text-white/55 sm:flex">
            {RENDER.variants.map((v, i) => (
              <span key={v} className={`inline-flex items-center gap-1 ${i === r.vi ? "text-white" : ""}`}>
                {i < r.vi || r.p >= 1 ? (
                  <Check className="h-[1.1em] w-[1.1em] text-primary" />
                ) : (
                  <span
                    className={`inline-block h-[0.5em] w-[0.5em] rounded-full ${i === r.vi ? "bg-primary" : "border border-white/40"}`}
                  />
                )}
                {v === "golden" ? "Golden" : v === "day" ? "Day" : "Night"}
              </span>
            ))}
          </div>
          <div className="mt-[0.6cqw] tabular-nums" style={{ color: CREAM }}>
            <span className="sm:hidden">{r.variant === "golden" ? "Golden" : r.variant === "day" ? "Day" : "Night"} · </span>
            Frame {num(r.frame)} <span className="text-white/50">of {num(RENDER.framesPerVariant)}</span>
          </div>
        </div>
        <div className="shrink-0 text-right tabular-nums text-white/60">
          <div className="hidden sm:block">Sped up</div>
          <div className="mt-[0.6cqw]">{r.p >= 1 ? "Done" : `about ${r.minutes} min left`}</div>
        </div>
      </div>
      <div className="mt-[1.2cqw] h-[2px] overflow-hidden rounded-full bg-white/15">
        <div className="h-full rounded-full bg-primary" style={{ width: `${r.p * 100}%` }} />
      </div>
    </div>
  );
}

// --- Chapters ------------------------------------------------------------------------------

function Chapters({
  t,
  chapter,
  paused,
  onSeek,
  onToggle,
}: {
  t: number;
  chapter: ChapterId;
  paused: boolean;
  onSeek: (s: number) => void;
  onToggle: () => void;
}) {
  return (
    <div className="mt-4 flex items-start gap-3 sm:mt-5 sm:gap-4">
      <div role="group" aria-label="Chapters" className="grid flex-1 grid-cols-4 gap-2 sm:gap-3">
        {CHAPTERS.map((c, i) => {
          const end = CHAPTERS[i + 1]?.start ?? DURATION;
          const fill = clamp01((t - c.start) / (end - c.start));
          const on = c.id === chapter;
          return (
            <button
              key={c.id}
              type="button"
              aria-current={on ? "step" : undefined}
              onClick={() => onSeek(c.start + 0.01)}
              className="group text-left"
            >
              <span className="block h-[2px] overflow-hidden rounded-full bg-white/10">
                <span className="block h-full rounded-full bg-primary/80" style={{ width: `${fill * 100}%` }} />
              </span>
              <span className="mt-2 flex items-baseline gap-1.5 text-xs sm:text-sm">
                <span className="hidden font-serif italic text-primary/40 sm:inline">{c.n}</span>
                <span
                  className={`transition-colors duration-300 ${on ? "text-primary" : "text-gray-500 group-hover:text-gray-300"}`}
                >
                  {c.name}
                </span>
              </span>
            </button>
          );
        })}
      </div>
      <button
        type="button"
        onClick={onToggle}
        aria-label={paused ? "Play the demonstration" : "Pause the demonstration"}
        className="-mt-1.5 flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-white/[0.06] text-gray-300 transition-colors hover:bg-white/[0.1] hover:text-primary"
      >
        {paused ? <Play className="h-3.5 w-3.5" /> : <Pause className="h-3.5 w-3.5" />}
      </button>
    </div>
  );
}

// --- Log -----------------------------------------------------------------------------------

function Dot({ done }: { done: boolean }) {
  return done ? (
    <span className="flex h-3.5 w-3.5 shrink-0 items-center justify-center rounded-full bg-primary/15">
      <Check className="h-2.5 w-2.5 text-primary" strokeWidth={3} />
    </span>
  ) : (
    <span className="h-3.5 w-3.5 shrink-0 animate-spin rounded-full border-[1.5px] border-white/15 border-t-primary" />
  );
}

function Log({ t, className = "" }: { t: number; className?: string }) {
  const shown = LOG.filter((e) => e.at <= t);
  return (
    <div aria-hidden="true" className={className}>
      <div
        className="relative h-[176px] overflow-hidden sm:h-[196px] lg:h-full lg:min-h-[300px]"
        style={{
          maskImage: "linear-gradient(to bottom, transparent 0, #000 34%)",
          WebkitMaskImage: "linear-gradient(to bottom, transparent 0, #000 34%)",
        }}
      >
        <div className="absolute inset-x-0 bottom-0 flex flex-col gap-3">
          <AnimatePresence initial={false}>
            {shown.map((e) => (
              <motion.div
                key={`${e.kind}-${e.at}`}
                layout="position"
                initial={{ opacity: 0, y: 10 }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0, transition: { duration: 0.4 } }}
                transition={SPRING}
              >
                <LogLine e={e} t={t} />
              </motion.div>
            ))}
          </AnimatePresence>
        </div>
      </div>
    </div>
  );
}

function LogLine({ e, t }: { e: Entry; t: number }) {
  if (e.kind === "you") {
    return (
      <p className="line-clamp-2 rounded-xl bg-white/[0.05] px-3.5 py-2.5 font-serif text-[15px] italic leading-snug text-primary/90">
        {e.text}
      </p>
    );
  }
  if (e.kind === "ai") {
    return <p className="px-0.5 text-[13px] leading-snug text-gray-300">{e.text}</p>;
  }
  const done = t >= e.done;
  return (
    <div className="flex items-start gap-2.5 px-0.5">
      <span className="mt-[2px]">
        <Dot done={done} />
      </span>
      <div className="min-w-0 flex-1">
        <div className="truncate font-mono text-[12px] leading-snug text-gray-200">
          {e.name}
          {e.args && <span className="text-gray-500">({e.args})</span>}
        </div>
        <div className="truncate text-[12px] leading-snug text-gray-500">{done ? e.result : "…"}</div>
      </div>
    </div>
  );
}

// --- Reduced motion: the same story as four still frames -----------------------------------

const BOARD: { n: string; name: string; body: string; tools: string[] }[] = [
  {
    n: "01",
    name: "Ask",
    body: "Describe the screensaver you want, in your own words.",
    tools: ["get_started", "list_film_templates"],
  },
  {
    n: "02",
    name: "Build",
    body: "Blender builds the scene: clay, materials, ray-traced light, then the film look. You approve the stills.",
    tools: ["create_film_scene", "render_film_stills"],
  },
  {
    n: "03",
    name: "Render",
    body: "A seamless loop for day, golden hour and night renders in the background.",
    tools: ["render_film_loop", "film_job_status"],
  },
  {
    n: "04",
    name: "Play",
    body: "It's added to your library and, because you asked, set as your screensaver.",
    tools: ["create_style", "set_screensaver"],
  },
];

function Storyboard() {
  const r = renderAt(23.6);
  const frames: ReactNode[] = [
    <div key="ask" className="absolute inset-0 flex flex-col justify-center bg-[#0f0f0e] p-[6cqw]">
      <p className="font-serif italic leading-[1.15] text-primary" style={{ fontSize: "max(14px, 5.6cqw)" }}>
        “{PROMPT}”
      </p>
    </div>,
    <div key="build" className="absolute inset-0">
      {(["clay", "materials", "graded"] as const).map((id, i) => (
        <img
          key={id}
          src={MCP_MEDIA.build[id]}
          alt=""
          width={MCP_MEDIA.width}
          height={MCP_MEDIA.height}
          loading="lazy"
          decoding="async"
          className="absolute inset-0 h-full w-full object-cover"
          style={{ clipPath: `inset(0 ${(2 - i) * 33.333}% 0 ${i * 33.333}%)` }}
        />
      ))}
      <div className="absolute inset-y-0 left-1/3 w-px bg-black/60" />
      <div className="absolute inset-y-0 left-2/3 w-px bg-black/60" />
    </div>,
    <div key="render" className="absolute inset-0">
      <img
        src={MCP_MEDIA.render.frames.golden}
        alt=""
        width={MCP_MEDIA.width}
        height={MCP_MEDIA.height}
        loading="lazy"
        decoding="async"
        className="absolute inset-0 h-full w-full object-cover"
      />
      <div className="absolute inset-0 bg-gradient-to-t from-black/75 via-black/0 to-transparent" />
      <RenderReadout on r={r} />
    </div>,
    <div key="play" className="absolute inset-0 bg-[#0b0b0a]">
      <div className="absolute left-[10%] top-[3%] h-[80%] w-[80%] overflow-hidden rounded-[8px] shadow-[0_0_0_7px_#050505,0_0_0_8px_rgba(255,255,255,0.13)]">
        <img
          src={MCP_MEDIA.final.poster}
          alt=""
          width={MCP_MEDIA.width}
          height={MCP_MEDIA.height}
          loading="lazy"
          decoding="async"
          className="h-full w-full object-cover"
        />
      </div>
      <div className="absolute left-1/2 top-[84%] h-[12.5%] w-[15%] -translate-x-1/2">
        <div className="h-[86%] w-full rounded-b-[3px] bg-gradient-to-b from-[#1c1c1c] via-[#2a2a29] to-[#232322]" />
        <div className="mx-[-55%] h-[14%] rounded-[3px] bg-gradient-to-b from-[#3a3a38] to-[#1d1d1c]" />
      </div>
    </div>,
  ];
  return (
    <div>
      <ol className="grid grid-cols-1 gap-x-4 gap-y-7 sm:grid-cols-2">
        {BOARD.map((b, i) => (
          <li key={b.n}>
            <div
              className="relative aspect-[16/10] overflow-hidden rounded-xl ring-1 ring-white/[0.06]"
              style={{ containerType: "inline-size" }}
              aria-hidden="true"
            >
              {frames[i]}
            </div>
            <h3 className="mt-3 flex items-baseline gap-2 text-sm sm:text-base" style={{ color: CREAM }}>
              <span className="font-serif italic text-primary/40">{b.n}</span>
              {b.name}
            </h3>
            <p className="mt-1 text-xs leading-relaxed text-gray-400 sm:text-sm">{b.body}</p>
            <p className="mt-2 flex flex-wrap gap-1.5">
              {b.tools.map((tool) => (
                <span key={tool} className="rounded-md bg-white/[0.05] px-2 py-0.5 font-mono text-[11px] text-gray-400">
                  {tool}
                </span>
              ))}
            </p>
          </li>
        ))}
      </ol>
    </div>
  );
}
