import { useEffect, useLayoutEffect, useRef, useState, type CSSProperties, type ReactNode } from "react";
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
 * "Now with MCP": one Apple Studio Display, drawn in CSS, that never moves; the whole demo
 * happens on its screen, a simplified Mac desktop. An AI app's chat window sits beside
 * DotStudio's window: the prompt is typed (the blank cycles through ideas), the scene builds
 * in a DotStudio preview and takes one tweak, renders (only some scenes need to), and then
 * the windows fade and it plays full screen as the screensaver. ~31 s, then it starts over
 * (aiSequence.ts).
 *
 * Narrow screens (the display's screen under 720 px) show one window at a time and the chat
 * as large bubbles over it, so the text stays legible. The demo runs only while on screen and
 * the tab is visible; it can be paused, and the beat dots seek. Under prefers-reduced-motion:
 * four still displays instead. QA hook: `?ai=<seconds>` opens it paused at that moment.
 */

const CREAM = "#E1E0CC";
const SPRING: Transition = { type: "spring", duration: 0.9, bounce: 0 };
const DOCS = "https://github.com/dw2lam/DotStudio/tree/main/docs/ai";

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

/** True while the element is narrower than `px`. */
function useNarrow<T extends Element>(px: number) {
  const ref = useRef<T>(null);
  const [narrow, setNarrow] = useState(false);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const ro = new ResizeObserver(([e]) => setNarrow(e.contentRect.width < px));
    ro.observe(el);
    return () => ro.disconnect();
  }, [px]);
  return [ref, narrow] as const;
}

/**
 * From tablets up the whole section fits the window: the stage gets whatever height is left
 * after the section's padding, header, controls and note, but never more than the display
 * needs at full width. The display then sizes itself in the stage (index.css, .fit-display).
 */
function useFitStage() {
  const ref = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const stage = ref.current;
    const section = stage?.closest("section");
    const column = section?.firstElementChild as HTMLElement | null;
    if (!stage || !section || !column) return;
    const fit = () => {
      if (window.innerWidth < 768) {
        stage.style.height = "";
        return;
      }
      const cs = getComputedStyle(section);
      const pad = parseFloat(cs.paddingTop) + parseFloat(cs.paddingBottom);
      const other = column.offsetHeight - stage.offsetHeight;
      const room = window.innerHeight - pad - other;
      const full = (stage.clientWidth * 632) / 1000;
      stage.style.height = `${Math.floor(Math.max(180, Math.min(room - 1, full)))}px`;
    };
    fit();
    window.addEventListener("resize", fit);
    const ro = new ResizeObserver(fit);
    ro.observe(column);
    document.fonts?.ready.then(fit);
    return () => {
      window.removeEventListener("resize", fit);
      ro.disconnect();
    };
  }, []);
  return ref;
}

// --- Section -------------------------------------------------------------------------------

export function MCPDemo() {
  const reduced = useReducedMotion() ?? false;
  return (
    <section
      id="mcp"
      aria-labelledby="mcp-title"
      className="relative bg-black px-4 py-16 sm:py-20 md:flex md:min-h-[100svh] md:flex-col md:justify-center md:py-[clamp(1.25rem,4.5svh,3.5rem)]"
    >
      <div className="mx-auto flex w-full max-w-7xl flex-col">
        <header className="mb-6 flex flex-col gap-3 md:mb-[clamp(0.75rem,3svh,2rem)] md:flex-row md:items-end md:justify-between md:gap-10">
          <h2
            id="mcp-title"
            className="text-4xl font-medium leading-[0.95] tracking-[-0.04em] sm:text-5xl md:text-[clamp(2.5rem,7.5svh,4rem)]"
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
          <p className="max-w-md text-sm leading-relaxed text-gray-400 [text-wrap:balance] md:pb-1 md:text-right md:text-base">
            Any MCP app, on any model, can now make screensavers with DotStudio.
          </p>
        </header>

        {reduced ? <Storyboard /> : <Demo />}
        <Note />
      </div>
    </section>
  );
}

/** One quiet line under the demo. */
function Note() {
  return (
    <p className="mt-3 text-center text-xs leading-relaxed text-gray-600 md:mt-[clamp(0.25rem,1.2svh,0.75rem)]">
      Rendered scenes need Blender. Simpler scenes play live, no rendering needed.{" "}
      <a
        href={DOCS}
        target="_blank"
        rel="noopener noreferrer"
        className="whitespace-nowrap text-gray-500 underline decoration-white/15 underline-offset-4 transition-colors hover:text-primary"
      >
        Setup guide
      </a>
    </p>
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
  const stageRef = useFitStage();

  // Load a beat ahead: the build stills while the prompt types, the loop while rendering.
  const [armed, setArmed] = useState(0);
  const want = t >= 13 || bi >= 2 ? 2 : t >= 1 || bi >= 1 ? 1 : 0;
  useEffect(() => {
    if (onScreen && want > armed) setArmed(want);
  }, [onScreen, want, armed]);

  return (
    <div ref={rootRef} className="flex flex-col">
      <p className="sr-only">
        A demonstration on a Mac: in an AI app with DotStudio connected over MCP, someone asks “{PROMPT}”.
        DotStudio builds the scene, makes the light warmer when asked, renders it, and sets it as the screensaver,
        which then fills the screen.
      </p>
      <div ref={stageRef} className="fit-stage">
        <div className="fit-display">
          <StudioDisplay crop={CROP}>
            <Screen t={t} armed={armed} running={running} />
          </StudioDisplay>
        </div>
      </div>
      <div className="flex items-center justify-center gap-3">
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
  );
}

// --- Apple Studio Display, front on --------------------------------------------------------

/*
 * Drawn in CSS: a 16:9 panel in a thin, uniform black bezel with a hairline of silver
 * aluminium round tight, rounded corners; the stand's single aluminium blade (about a third
 * of the display's width) drops from behind it, curving forward onto a slim foot seen as a
 * sliver, with a soft contact shadow. Boxes are % of a 1000 × 790 frame.
 */
const FRAME_ASPECT = "1000 / 790";
const SHELL = { left: 0.4, top: 0.506, width: 99.2, height: 72.41 };
const SCREEN = { left: 2, top: 2.53, width: 96, height: 68.35 };
const pct = (r: { left: number; top: number; width: number; height: number }) => ({
  left: `${r.left}%`,
  top: `${r.top}%`,
  width: `${r.width}%`,
  height: `${r.height}%`,
});

/** How much of the frame the live demo shows: the display and the top of its stand. */
const CROP = 0.8;

function StudioDisplay({ children, crop = 1 }: { children: ReactNode; crop?: number }) {
  const frame = (
    <div
      aria-hidden="true"
      className="relative w-full"
      style={{ aspectRatio: FRAME_ASPECT, containerType: "inline-size" }}
    >
      {/* Contact shadow on the desk. */}
      <div
        className="absolute rounded-[50%] blur-[4px]"
        style={{
          left: "24%",
          width: "52%",
          top: "94%",
          height: "5%",
          background: "radial-gradient(closest-side, rgba(0,0,0,0.85), rgba(0,0,0,0.4) 55%, transparent)",
        }}
      />
      {/* The blade: in the display's shadow at the top, catching the light where it curves forward. */}
      <div
        className="absolute"
        style={{
          left: "35%",
          width: "30%",
          top: "69%",
          height: "25%",
          clipPath: "polygon(0 0, 100% 0, 100% 72%, 100.6% 100%, -0.6% 100%, 0 72%)",
          background:
            "linear-gradient(180deg, #3a3a39 0%, #6a6a68 18%, #9a9a98 40%, #b4b4b2 66%, #c8c8c6 84%, #d8d8d6 91%, #a2a2a0 100%)",
        }}
      />
      {/* The foot, front on: a sliver of top face, then its front edge. */}
      <div
        className="absolute rounded-[0.15cqw]"
        style={{
          left: "34.6%",
          width: "30.8%",
          top: "93.6%",
          height: "1.5%",
          background: "linear-gradient(180deg, #f2f2f0 0%, #d6d6d4 38%, #8c8c8a 55%, #6c6c6a 100%)",
          boxShadow: "0 1px 1px rgba(0,0,0,0.5)",
        }}
      />
      {/* Aluminium shell with a hairline rim, the black glass, and the panel. */}
      <div
        className="absolute"
        style={{
          ...pct(SHELL),
          borderRadius: "1.15cqw",
          background: "linear-gradient(180deg, #e6e6e4 0%, #c9c9c7 45%, #a9a9a7 100%)",
          boxShadow: "inset 0 1px 0 rgba(255,255,255,0.8), 0 1px 1px rgba(0,0,0,0.6), 0 40px 70px -30px rgba(0,0,0,0.9)",
        }}
      >
        <div
          className="absolute bg-[#040404]"
          style={{ inset: "max(1px, 0.16cqw)", borderRadius: "calc(1.15cqw - max(1px, 0.16cqw))" }}
        />
      </div>
      <div className="absolute overflow-hidden rounded-[0.25cqw] bg-black" style={pct(SCREEN)}>
        {children}
      </div>
    </div>
  );
  if (crop >= 1) return frame;
  return (
    <div className="relative w-full overflow-hidden" style={{ aspectRatio: `1000 / ${790 * crop}` }}>
      {frame}
      {/* The stand and the display's lower edge dissolve into the page. */}
      <div
        className="pointer-events-none absolute inset-x-0 bottom-0 h-[16%]"
        style={{ background: "linear-gradient(to bottom, rgba(0,0,0,0), #000 92%)" }}
      />
    </div>
  );
}

// --- The screen: a simplified Mac desktop --------------------------------------------------

type ScreenProps = { t: number; armed: number; running: boolean; still?: boolean };

function Screen({ t, armed, running, still = false }: ScreenProps) {
  const [ref, narrow] = useNarrow<HTMLDivElement>(720);
  const beat = beatAt(t);
  const enjoy = beat === "enjoy";
  let step: (typeof BUILD_STEPS)[number] | null = null;
  for (const s of BUILD_STEPS) if (t >= s.at) step = s;
  const preview = !!step && !enjoy;
  const rendering = beat === "render";
  const progress = clamp01((t - RENDER.start) / (RENDER.end - RENDER.start));

  const videoRef = useRef<HTMLVideoElement>(null);
  useEffect(() => {
    const v = videoRef.current;
    if (!v) return;
    if (enjoy && running) v.play().catch(() => {});
    else v.pause();
  }, [enjoy, running, armed]);

  const fade = (on: boolean, ms = 700): CSSProperties =>
    still ? { opacity: on ? 1 : 0 } : { opacity: on ? 1 : 0, transition: `opacity ${ms}ms ease` };

  // macOS UI scale: true proportions on a wide screen, enlarged on a narrow one.
  const k = narrow ? 2.2 : 1;
  // Window rects, in % of the screen (narrow screens: one window, larger).
  const appRect = narrow ? { left: 7, top: 9, width: 86 } : { left: 30, top: 9, width: 64 };
  const previewRect = narrow ? { left: 12, top: 11, width: 76 } : { left: 37, top: 15, width: 54 };

  return (
    <div
      ref={ref}
      className="absolute inset-0 overflow-hidden [&_*]:[font-family:inherit]"
      style={{ containerType: "inline-size", fontFamily: MAC_FONT }}
    >
      {/* Desktop picture. */}
      <img
        src={MCP_MEDIA.wallpaper}
        alt=""
        width={1600}
        height={1000}
        loading="lazy"
        decoding="async"
        className="absolute inset-0 h-full w-full object-cover"
        style={{ filter: "brightness(0.72) saturate(1.05)" }}
      />

      {/* Everything on the desktop fades away when the screensaver starts. */}
      <div className="absolute inset-0" style={fade(!enjoy)}>
        <MenuBar k={k} narrow={narrow} />
        {/* DotStudio: hidden title bar, its content runs to the top under the lights. */}
        <Win rect={appRect} k={k} z={1} toolbar={38} bg="#0c0f17" style={fade(!(narrow && preview), 500)}>
          <img
            src={MCP_MEDIA.app}
            alt=""
            width={1280}
            height={800}
            loading="lazy"
            decoding="async"
            className="block w-full"
          />
        </Win>
        <Win
          rect={previewRect}
          k={k}
          z={2}
          style={{
            ...fade(preview, 500),
            transform: preview ? "scale(1)" : "scale(0.96)",
            transition: still ? undefined : "opacity 500ms ease, transform 600ms cubic-bezier(0.16,1,0.3,1)",
          }}
        >
          <div className="relative aspect-[16/10] bg-[#111]">
            {armed >= 1 &&
              BUILD_STEPS.map((s) => <Still key={s.id} src={MCP_MEDIA.build[s.id]} on={step?.id === s.id} still={still} />)}
            {/* Rendering: only for a prerendered scene like this one. */}
            <div className="absolute inset-0 z-[3] flex items-end justify-center pb-[6%]" style={fade(rendering, 400)}>
              <div
                className="rounded-full bg-black/65 text-white/90 backdrop-blur-md"
                style={{
                  padding: narrow ? "6px 12px" : "0.55cqw 1.1cqw",
                  fontSize: narrow ? "clamp(9px, 2.3cqw, 12px)" : "1.05cqw",
                  width: narrow ? "56%" : "34%",
                }}
              >
                <div className="flex items-center justify-between gap-2">
                  <span>{progress >= 1 ? "Rendered" : "Rendering…"}</span>
                  <span className="tabular-nums text-white/60">{Math.round(progress * 100)}%</span>
                </div>
                <div className="mt-[0.4em] h-[2px] overflow-hidden rounded-full bg-white/20">
                  <div className="h-full rounded-full bg-primary" style={{ width: `${progress * 100}%` }} />
                </div>
              </div>
            </div>
          </div>
        </Win>
        {narrow ? <ChatBubbles t={t} still={still} /> : <ChatWindow t={t} still={still} k={k} />}
      </div>

      {/* The screensaver, full screen. */}
      <div className="absolute inset-0 z-10" style={fade(enjoy, 1000)}>
        <img
          src={MCP_MEDIA.final.poster}
          alt=""
          width={MCP_MEDIA.width}
          height={MCP_MEDIA.height}
          loading="lazy"
          decoding="async"
          className="absolute inset-0 h-full w-full object-cover"
        />
        {!still && armed >= 2 && (
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
        )}
        {/* Live grain, as DotStudio adds it at playback. */}
        <div
          className={`noise-overlay pointer-events-none absolute inset-0 mix-blend-overlay ${running && !still ? "grain-live" : ""}`}
          style={{ opacity: 0.4 }}
        />
      </div>
    </div>
  );
}

const MAC_FONT = '-apple-system, BlinkMacSystemFont, "SF Pro Text", "SF Pro", "Helvetica Neue", sans-serif';

/** macOS points on a 1440-pt-wide screen, as container units, times the UI scale k. */
const pt = (n: number, k = 1) => `${(((n * 100) / 1440) * k).toFixed(4)}cqw`;

/** The menu bar as macOS 26 draws it: no bar, just type over the wallpaper. No Apple logo. */
function MenuBar({ k, narrow }: { k: number; narrow: boolean }) {
  const icon = { height: pt(13, k), width: "auto" } as const;
  return (
    <div
      className="absolute inset-x-0 top-0 z-[5] flex items-center text-white"
      style={{
        height: pt(24, k),
        fontSize: pt(13, k),
        gap: pt(20, k),
        padding: `0 ${pt(14, k)}`,
        background: "linear-gradient(to bottom, rgba(0,0,0,0.22), rgba(0,0,0,0))",
        textShadow: "0 0 3px rgba(0,0,0,0.35)",
      }}
    >
      {/* Where the Apple menu would be. */}
      <span style={{ width: pt(14, k) }} />
      <span className="font-bold">DotStudio</span>
      {!narrow && ["File", "Edit", "View", "Window", "Help"].map((m) => <span key={m}>{m}</span>)}
      <span className="ml-auto flex items-center" style={{ gap: pt(16, k) }}>
        {!narrow && (
          <>
            <svg viewBox="0 0 26 13" style={icon} aria-hidden="true">
              <rect x="0.5" y="0.5" width="22" height="12" rx="3.5" fill="none" stroke="currentColor" strokeOpacity="0.55" />
              <rect x="2.5" y="2.5" width="15" height="8" rx="2" fill="currentColor" />
              <path d="M24 4.5v4a2 2 0 0 0 0-4Z" fill="currentColor" fillOpacity="0.55" />
            </svg>
            <svg viewBox="0 0 18 13" style={icon} aria-hidden="true">
              <path
                d="M9 12.2 6.4 9.6a3.7 3.7 0 0 1 5.2 0L9 12.2Zm-4.3-4.3L3 6.2a8.5 8.5 0 0 1 12 0l-1.7 1.7a6.1 6.1 0 0 0-8.6 0ZM1.3 4.5 0 3.2a12.8 12.8 0 0 1 18 0l-1.3 1.3a11 11 0 0 0-15.4 0Z"
                fill="currentColor"
              />
            </svg>
            <svg viewBox="0 0 16 13" style={icon} aria-hidden="true">
              <rect x="0.6" y="0.6" width="14.8" height="5" rx="2.5" fill="none" stroke="currentColor" strokeWidth="1.2" />
              <circle cx="3.6" cy="3.1" r="1.5" fill="currentColor" />
              <rect x="0.6" y="7.4" width="14.8" height="5" rx="2.5" fill="none" stroke="currentColor" strokeWidth="1.2" />
              <circle cx="12.4" cy="9.9" r="1.5" fill="currentColor" />
            </svg>
          </>
        )}
        <span className="tabular-nums">{narrow ? "7:41 PM" : "Thu Nov 12\u20027:41 PM"}</span>
      </span>
    </div>
  );
}

/** Traffic lights: 12 pt, 8 pt apart; grey when the window isn't the active one. */
function Lights({ k, active }: { k: number; active: boolean }) {
  const colours: [string, string][] = active
    ? [
        ["#ff5f57", "#e0443e"],
        ["#febc2e", "#dea123"],
        ["#28c840", "#1aab29"],
      ]
    : [
        ["#4d4d4f", "#3e3e40"],
        ["#4d4d4f", "#3e3e40"],
        ["#4d4d4f", "#3e3e40"],
      ];
  return (
    <span className="flex" style={{ gap: pt(8, k) }}>
      {colours.map(([fill, rim], i) => (
        <span
          key={i}
          className="rounded-full"
          style={{ width: pt(12, k), height: pt(12, k), background: fill, boxShadow: `inset 0 0 0 0.5px ${rim}` }}
        />
      ))}
    </span>
  );
}

/**
 * A macOS 26 window: big continuous corners, a hairline light inner border, a soft wide
 * shadow, and the traffic lights inset at the top left, centred in the toolbar band (or
 * floating over full-height content when there's no band). Height follows the content.
 */
function Win({
  rect,
  k,
  z,
  active = false,
  toolbar = 0,
  bg = "#1d1d1f",
  style,
  children,
}: {
  rect: { left: number; top: number; width: number };
  k: number;
  z: number;
  active?: boolean;
  toolbar?: number;
  bg?: string;
  style?: CSSProperties;
  children: ReactNode;
}) {
  return (
    <div
      className="absolute overflow-hidden"
      style={{
        left: `${rect.left}%`,
        top: `${rect.top}%`,
        width: `${rect.width}%`,
        zIndex: z,
        borderRadius: pt(24, k),
        background: bg,
        boxShadow: `0 ${pt(3, k)} ${pt(10, k)} rgba(0,0,0,0.3), 0 ${pt(18, k)} ${pt(60, k)} rgba(0,0,0,0.5)`,
        ...style,
      }}
    >
      {toolbar > 0 && <div style={{ height: pt(toolbar, k) }} />}
      {children}
      <span
        className="pointer-events-none absolute"
        style={{ left: pt(18, k), top: toolbar > 0 ? pt((toolbar - 12) / 2, k) : pt(16, k) }}
      >
        <Lights k={k} active={active} />
      </span>
      <span
        className="pointer-events-none absolute inset-0"
        style={{ borderRadius: "inherit", boxShadow: "inset 0 0 0 1px rgba(255,255,255,0.13)" }}
      />
    </div>
  );
}

/** One still that fades in over whatever is up, then holds with a slow push-in. */
function Still({ src, on, still = false }: { src: string; on: boolean; still?: boolean }) {
  const style: CSSProperties = still
    ? { opacity: on ? 1 : 0 }
    : on
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
      loading="lazy"
      decoding="async"
      className="absolute inset-0 h-full w-full object-cover"
      style={style}
    />
  );
}

// --- Chat ----------------------------------------------------------------------------------

/** "/mcp DotStudio" set apart from the rest of a message. */
function WithCommand({ text }: { text: string }) {
  if (!text.startsWith("/")) return <>{text}</>;
  return (
    <>
      <span className="font-mono text-[0.92em] text-primary">{text.slice(0, COMMAND.length)}</span>
      {text.slice(COMMAND.length)}
    </>
  );
}

function Typed({ t }: { t: number }) {
  const typed = composerAt(t);
  return (
    <>
      {typed ? <WithCommand text={typed} /> : <span className="text-white/35">Ask anything</span>}
      {t < SENT && typed && <span className="caret-blink ml-px inline-block h-[1em] w-px translate-y-[0.15em] bg-primary" />}
    </>
  );
}

function Bubble({ m }: { m: Message }) {
  if (m.from === "you") {
    return (
      <div className="flex justify-end">
        <p className="max-w-[88%] rounded-[1em] rounded-br-[0.35em] bg-white/[0.1] px-[0.85em] py-[0.5em] leading-snug text-white/95">
          <WithCommand text={m.text} />
        </p>
      </div>
    );
  }
  return (
    <div className="max-w-[94%] leading-snug text-white/85">
      <p>{m.text}</p>
      {m.tools && <p className="mt-[0.3em] truncate font-mono text-[0.78em] text-white/40">{TOOLS.join("  ·  ")}</p>}
    </div>
  );
}

/** Wide screens: the AI app's window, beside DotStudio's. */
function ChatWindow({ t, still, k }: { t: number; still: boolean; k: number }) {
  const shown = CHAT.filter((m) => m.at <= t);
  return (
    <div
      className="absolute z-[3] flex flex-col overflow-hidden bg-[#1e1e20]/95 backdrop-blur-xl"
      style={{
        left: "4%",
        top: "14%",
        width: "30%",
        height: "71%",
        borderRadius: pt(24, k),
        fontSize: pt(17, k),
        boxShadow: `0 ${pt(3, k)} ${pt(10, k)} rgba(0,0,0,0.3), 0 ${pt(18, k)} ${pt(60, k)} rgba(0,0,0,0.55)`,
      }}
    >
      <div className="flex shrink-0 items-center" style={{ height: pt(38, k), paddingLeft: pt(18, k) }}>
        <Lights k={k} active />
      </div>
      <span
        className="pointer-events-none absolute inset-0 z-10"
        style={{ borderRadius: "inherit", boxShadow: "inset 0 0 0 1px rgba(255,255,255,0.13)" }}
      />
      <div
        className="relative min-h-0 flex-1"
        style={{
          maskImage: "linear-gradient(to bottom, transparent 0, #000 20%)",
          WebkitMaskImage: "linear-gradient(to bottom, transparent 0, #000 20%)",
        }}
      >
        <div className="absolute inset-x-0 bottom-0 flex flex-col gap-[0.75em] px-[1em] pb-[0.9em]">
          <AnimatePresence initial={false}>
            {shown.map((m) => (
              <motion.div
                key={m.at}
                layout={still ? false : "position"}
                initial={still ? false : { opacity: 0, y: 8 }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0, transition: { duration: 0.3 } }}
                transition={SPRING}
              >
                <Bubble m={m} />
              </motion.div>
            ))}
          </AnimatePresence>
        </div>
      </div>
      <div className="mx-[0.8em] mb-[0.8em] flex shrink-0 items-end gap-[0.6em] border-t border-white/10 pt-[0.7em] text-white/90">
        <p className="min-w-0 flex-1 leading-snug">
          <Typed t={t} />
        </p>
        <ArrowUp className={`h-[1.1em] w-[1.1em] shrink-0 ${composerAt(t) ? "text-primary" : "text-white/25"}`} />
      </div>
    </div>
  );
}

/** Narrow screens: the input, then the last two messages, as large bubbles over the windows. */
function ChatBubbles({ t, still }: { t: number; still: boolean }) {
  const shown = CHAT.filter((m) => m.at <= t).slice(-2);
  return (
    <div
      className="absolute inset-x-[4%] bottom-[5%] z-[4] flex flex-col gap-[0.5em]"
      style={{ fontSize: "clamp(10px, 2.6cqw, 13px)" }}
    >
      {t < SENT ? (
        <div className="flex items-end gap-[0.6em] rounded-[1em] bg-[#1c1c1c]/95 px-[0.9em] py-[0.65em] text-white/90 shadow-[0_8px_24px_rgba(0,0,0,0.5)] ring-1 ring-white/10 backdrop-blur-xl">
          <p className="min-w-0 flex-1 leading-snug">
            <Typed t={t} />
          </p>
          <ArrowUp className={`h-[1.1em] w-[1.1em] shrink-0 ${composerAt(t) ? "text-primary" : "text-white/25"}`} />
        </div>
      ) : (
        <AnimatePresence initial={false} mode="popLayout">
          {shown.map((m) => (
            <motion.div
              key={m.at}
              layout={still ? false : "position"}
              initial={still ? false : { opacity: 0, y: 8 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, transition: { duration: 0.25 } }}
              transition={SPRING}
              className={m.from === "you" ? "flex justify-end" : "flex justify-start"}
            >
              <div
                className={`max-w-[92%] rounded-[1em] px-[0.9em] py-[0.55em] leading-snug shadow-[0_8px_24px_rgba(0,0,0,0.45)] ring-1 ring-white/10 backdrop-blur-xl ${
                  m.from === "you" ? "rounded-br-[0.35em] bg-[#2a2a2a]/95 text-white/95" : "rounded-bl-[0.35em] bg-[#161616]/95 text-white/85"
                }`}
              >
                {m.from === "you" ? <WithCommand text={m.text} /> : m.text}
                {m.tools && (
                  <span className="mt-[0.3em] block truncate font-mono text-[0.78em] text-white/40">{TOOLS.join("  ·  ")}</span>
                )}
              </div>
            </motion.div>
          ))}
        </AnimatePresence>
      )}
    </div>
  );
}

// --- Reduced motion: four still displays ---------------------------------------------------

const BOARD: { t: number; caption: string }[] = [
  { t: 7.0, caption: "Ask in any MCP app." },
  { t: 12.6, caption: "It builds the scene with you." },
  { t: 17.6, caption: "It renders, if needed." },
  { t: 25, caption: "Then it's your screensaver." },
];

function Storyboard() {
  return (
    <ol className="grid grid-cols-1 gap-x-4 gap-y-8 sm:grid-cols-2 md:my-auto md:grid-cols-4">
      {BOARD.map((b, i) => (
        <li key={b.caption}>
          <StudioDisplay>
            <Screen t={b.t} armed={2} running={false} still />
          </StudioDisplay>
          <p className="mt-1 text-xs leading-snug text-gray-400 sm:text-sm">
            <span className="mr-1.5 font-serif italic text-primary/40">{String(i + 1).padStart(2, "0")}</span>
            {b.caption}
          </p>
        </li>
      ))}
    </ol>
  );
}
