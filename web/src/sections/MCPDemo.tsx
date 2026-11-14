import { useEffect, useId, useLayoutEffect, useRef, useState, type CSSProperties, type ReactNode } from "react";
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

/** The element's width in px (0 until measured). */
function useWidth<T extends Element>() {
  const ref = useRef<T>(null);
  const [width, setWidth] = useState(0);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const ro = new ResizeObserver(([e]) => setWidth(e.contentRect.width));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  return [ref, width] as const;
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
      className="section-pad mcp-fit relative bg-black"
    >
      <div className="mx-auto flex w-full max-w-7xl flex-col">
        <header className="mb-[var(--head-gap)] flex flex-col gap-4 md:mb-[clamp(0.75rem,3svh,2rem)] md:flex-row md:items-end md:justify-between md:gap-10">
          <div className="flex shrink-0 flex-col gap-3 md:gap-[clamp(0.5rem,1.5svh,1rem)]">
            <span className="text-[10px] uppercase tracking-[0.25em] text-primary sm:text-xs">
              New in 1.5 <span aria-hidden="true">·</span> Beta
            </span>
            <h2
              id="mcp-title"
              className="whitespace-nowrap pr-[0.12em] text-4xl font-medium leading-[0.95] tracking-[-0.04em] sm:text-5xl md:text-[clamp(2.5rem,7.5svh,4rem)]"
              style={{ color: CREAM }}
            >
              <WordsPullUpMultiStyle
                className="!flex-nowrap !justify-start"
                segments={[
                  { text: "Now with" },
                  { text: "MCP.", className: "font-serif font-normal italic tracking-[-0.02em] text-primary/75" },
                ]}
              />
            </h2>
          </div>
          <p className="max-w-md text-sm leading-relaxed text-gray-400 [text-wrap:balance] md:min-w-0 md:pb-1 md:text-right md:text-base">
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
  const [ref, width] = useWidth<HTMLDivElement>();
  const narrow = width > 0 && width < 720;
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
  // (13 pt type never drops under 10 px on a narrow screen.)
  const k = narrow ? Math.max(1, (10 * 1440) / (13 * width)) : 1;
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
        {/* DotStudio: the app's own capture, title bar and (inactive) lights included. */}
        <Win rect={appRect} k={k} z={1} lights={false} style={fade(!(narrow && preview), 500)}>
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
          toolbar={44}
          title="Preview"
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
            <div
              className={`absolute inset-0 z-[3] flex justify-center ${narrow ? "items-start pt-[5%]" : "items-end pb-[6%]"}`}
              style={fade(rendering, 400)}
            >
              <div
                style={{
                  ...glass(k),
                  borderRadius: pt(14, k),
                  padding: `${pt(10, k)} ${pt(14, k)}`,
                  fontSize: narrow ? "clamp(9px, 2.3cqw, 12px)" : pt(13, k),
                  width: narrow ? "56%" : "36%",
                }}
              >
                <div className="flex items-center justify-between" style={{ gap: pt(8, k) }}>
                  <span className="font-semibold">{progress >= 1 ? "Rendered" : "Rendering…"}</span>
                  <span className="tabular-nums" style={{ color: "rgba(236,236,238,0.6)" }}>
                    {Math.round(progress * 100)}%
                  </span>
                </div>
                <div className="overflow-hidden rounded-full" style={{ marginTop: pt(8, k), height: pt(4, k), background: "rgba(255,255,255,0.14)" }}>
                  <div className="h-full rounded-full bg-[#0a84ff]" style={{ width: `${progress * 100}%` }} />
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

/*
 * The look follows DavidOS (davidlam.online/about), the owner's macOS 26 desktop: a 30 pt
 * menu bar of plain white type on the wallpaper, and glass windows (a dark tint + 135° sheen,
 * 40 pt backdrop blur, 1 px light border, a soft drop shadow and a faint inner rim) with
 * 20 pt corners and 12 pt traffic lights 7 pt apart, 16 pt in. Re-implemented here at screen
 * scale; nothing of that site's content is used.
 */
const glass = (k: number): CSSProperties => ({
  background:
    "linear-gradient(135deg, rgba(64,63,65,0.6) 0%, rgba(28,28,30,0.4) 100%), rgba(43,42,42,0.72)",
  backdropFilter: `blur(${pt(40, k)})`,
  WebkitBackdropFilter: `blur(${pt(40, k)})`,
  border: "1px solid rgba(255,255,255,0.16)",
  boxShadow: `0 ${pt(8, k)} ${pt(32, k)} rgba(0,0,0,0.5), inset 0 0 0 1px rgba(255,255,255,0.08)`,
  color: "#ececee",
});

/**
 * DotStudio's mark as a one-colour menu-bar glyph: the app icon's chrome drop drawn as a
 * solid sphere with its swirl and highlight cut out (from App/Assets.xcassets/AppIcon).
 */
function DotMark({ size }: { size: string }) {
  const id = useId().replace(/:/g, "");
  return (
    <svg viewBox="0 0 16 16" style={{ width: size, height: size, display: "block" }} aria-hidden="true">
      <defs>
        <mask id={`dsm${id}`}>
          <rect width="16" height="16" fill="#fff" />
          <path
            d="M1.6 10.6C4.1 10.2 5.1 6.9 8.2 6.6c2.3-.2 3.1 1.7 5.9 1.1"
            fill="none"
            stroke="#000"
            strokeWidth="1.5"
            strokeLinecap="round"
          />
          <circle cx="5.6" cy="4.6" r="1.35" fill="#000" />
        </mask>
      </defs>
      <circle cx="8" cy="8" r="7.25" fill="currentColor" mask={`url(#dsm${id})`} />
    </svg>
  );
}

/** The menu bar as macOS 26 draws it: no bar at all, white type on the wallpaper. No Apple logo. */
function MenuBar({ k, narrow }: { k: number; narrow: boolean }) {
  const item: CSSProperties = { padding: `${pt(4, k)} ${pt(10, k)}` };
  return (
    <div
      className="absolute inset-x-0 top-0 z-[5] flex items-center justify-between text-white"
      style={{ height: pt(30, k), fontSize: pt(13, k), padding: `0 ${pt(12, k)} 0 ${pt(8, k)}`, lineHeight: 1 }}
    >
      <div className="flex items-center" style={{ gap: pt(1, k) }}>
        {/* The app's mark where the Apple menu would be (DavidOS's 13 × 15 pt slot). */}
        <span className="flex items-center" style={item}>
          <DotMark size={pt(14, k)} />
        </span>
        <span className="font-bold" style={item}>
          DotStudio
        </span>
        {!narrow &&
          ["File", "Edit", "View", "Window", "Help"].map((m) => (
            <span key={m} style={item}>
              {m}
            </span>
          ))}
      </div>
      <div className="flex items-center" style={{ gap: pt(4, k) }}>
        {!narrow && (
          <>
            <span style={{ padding: `${pt(4, k)} ${pt(5, k)}` }}>
              <svg viewBox="0 0 28 13" style={{ width: pt(24, k), height: pt(12, k), display: "block" }} aria-hidden="true">
                <rect x="0.9" y="0.9" width="22.7" height="11.2" rx="3.2" fill="none" stroke="currentColor" strokeOpacity="0.5" strokeWidth="1.8" />
                <rect x="2.4" y="2.4" width="15.5" height="8.2" rx="1.8" fill="currentColor" />
                <path d="M25.6 4.3v4.4c1.3-.3 2.1-1.2 2.1-2.2s-.8-1.9-2.1-2.2z" fill="currentColor" fillOpacity="0.5" />
              </svg>
            </span>
            <span style={{ padding: `${pt(4, k)} ${pt(5, k)}` }}>
              <svg
                viewBox="0 0 24 18"
                fill="none"
                stroke="currentColor"
                strokeWidth="2.47"
                strokeLinecap="round"
                style={{ width: pt(18, k), height: pt(13.5, k), display: "block" }}
                aria-hidden="true"
              >
                <path d="M1.28 7A14 14 0 0 1 22.72 7" />
                <path d="M5.03 10.15A9.1 9.1 0 0 1 18.97 10.15" />
                <path d="M8.78 13.3A4.2 4.2 0 0 1 15.22 13.3" />
                <circle cx="12" cy="16" r="1.3" fill="currentColor" stroke="none" />
              </svg>
            </span>
            <span style={{ padding: `${pt(4, k)} ${pt(6, k)}` }}>
              <svg
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2.96"
                strokeLinecap="round"
                style={{ width: pt(15, k), height: pt(15, k), display: "block" }}
                aria-hidden="true"
              >
                <circle cx="10.5" cy="10.5" r="7" />
                <path d="M15.6 15.6 19.6 19.6" />
              </svg>
            </span>
          </>
        )}
        <span className="whitespace-nowrap tabular-nums" style={{ padding: `${pt(4, k)} ${pt(2, k)} ${pt(4, k)} ${pt(6, k)}` }}>
          {narrow ? "7:41 PM" : "Thu Nov 12\u20027:41 PM"}
        </span>
      </div>
    </div>
  );
}

/** Traffic lights: 12 pt, 7 pt apart; grey when the window isn't the active one. */
function Lights({ k, active }: { k: number; active: boolean }) {
  const fills = active ? ["#FF5F57", "#FEBC2E", "#28C840"] : ["#58585c", "#58585c", "#58585c"];
  return (
    <span className="flex" style={{ gap: pt(7, k) }}>
      {fills.map((fill, i) => (
        <span
          key={i}
          className="rounded-full"
          style={{
            width: pt(12, k),
            height: pt(12, k),
            background: fill,
            boxShadow: "inset 0 0 0 0.5px rgba(0,0,0,0.18), 0 1px 2px rgba(0,0,0,0.12)",
          }}
        />
      ))}
    </span>
  );
}

/**
 * A DavidOS window: glass, 20 pt corners, a 44 pt toolbar with the lights centred in it and a
 * hairline under it (or, with no toolbar, the lights 16 pt in over the content; or no lights
 * when the content is a capture that carries its own). Height follows the content.
 */
function Win({
  rect,
  k,
  z,
  active = false,
  toolbar = 0,
  lights = true,
  title,
  style,
  children,
}: {
  rect: { left: number; top: number; width: number };
  k: number;
  z: number;
  active?: boolean;
  toolbar?: number;
  lights?: boolean;
  title?: string;
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
        borderRadius: pt(20, k),
        ...glass(k),
        ...style,
      }}
    >
      {toolbar > 0 && (
        <div
          className="flex items-center font-semibold"
          style={{
            height: pt(toolbar, k),
            paddingLeft: pt(72, k),
            fontSize: pt(13, k),
            borderBottom: "1px solid rgba(255,255,255,0.1)",
          }}
        >
          {title}
        </div>
      )}
      {children}
      {lights && (
        <span
          className="pointer-events-none absolute"
          style={{ left: pt(16, k), top: toolbar > 0 ? pt((toolbar - 12) / 2, k) : pt(16, k) }}
        >
          <Lights k={k} active={active} />
        </span>
      )}
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
        <p className="max-w-[88%] rounded-[1.1em] bg-white/[0.12] px-[0.85em] py-[0.5em] leading-snug text-white">
          <WithCommand text={m.text} />
        </p>
      </div>
    );
  }
  return (
    <div className="max-w-[94%] leading-snug text-[#ececee]">
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
      className="absolute z-[3] flex flex-col overflow-hidden"
      style={{
        left: "4%",
        top: "14%",
        width: "30%",
        height: "71%",
        borderRadius: pt(20, k),
        fontSize: pt(16, k),
        ...glass(k),
      }}
    >
      <div
        className="flex shrink-0 items-center"
        style={{ height: pt(44, k), paddingLeft: pt(16, k), borderBottom: "1px solid rgba(255,255,255,0.1)" }}
      >
        <Lights k={k} active />
      </div>
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
      <div
        className="mx-[0.75em] mb-[0.75em] flex shrink-0 items-end gap-[0.6em] rounded-[1.1em] px-[0.85em] py-[0.55em] text-white"
        style={{ background: "rgba(255,255,255,0.08)", boxShadow: "inset 0 0 0 1px rgba(255,255,255,0.1)" }}
      >
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
        <div className="flex items-end gap-[0.6em] rounded-[1.1em] px-[0.9em] py-[0.65em]" style={glass(2.2)}>
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
              <div className="max-w-[92%] rounded-[1.1em] px-[0.9em] py-[0.55em] leading-snug" style={glass(2.2)}>
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
