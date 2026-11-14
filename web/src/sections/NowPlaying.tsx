import { useEffect, useLayoutEffect, useRef, useState, useSyncExternalStore, type CSSProperties } from "react";
import { motion, useInView, useReducedMotion, type Transition } from "framer-motion";
import { Reveal } from "../components/Reveal";
import { SectionHeader } from "../components/SectionHeader";

type LayoutId = "album" | "stage" | "cover" | "corner";

const LAYOUTS: { id: LayoutId; name: string; alt: string }[] = [
  { id: "album", name: "Album", alt: "Full Screen, Album layout: artwork beside the song over living album art" },
  { id: "stage", name: "Stage", alt: "Full Screen, Stage layout: artwork centred above the song" },
  { id: "cover", name: "Cover", alt: "Full Screen, Cover layout: the artwork fills the screen behind the song" },
  { id: "corner", name: "Corner", alt: "A small now-playing card in the corner of the Topography screensaver" },
];

const SONG = { title: "Smoothies in 1991", artist: "Larry June" };
const MEDIA = {
  art: "/media/music/smoothies-art.webp",
  // The app's own renders (tools/gallery, --full art) with this artwork: the living album
  // art behind Album / Stage, and Cover's full-bleed art with its blurred, dimmed corner.
  living: "/media/music/smoothies-living.webp",
  cover: "/media/music/smoothies-cover.webp",
  topography: "/media/scenes/topography.webp",
};

/*
 * One player that rearranges itself. Every element below is the same DOM node in every
 * layout; it is animated (one spring, transforms and sizes only — no layout
 * measuring) from where it is to where the new layout puts it, so a change reads as the
 * artwork, title, artist, bar and times gliding into place. A click mid-move retargets
 * from the current position and speed, so quick clicks never jump. Geometry is the app's own (Shared/Music: MusicGeometry + MusicOverlayLayer)
 * on a 1600 × 1000 design screen, scaled to the frame's measured width, so the frame is a
 * true scaled copy at any width (a phone shows the desktop composition, smaller). Text is
 * set once at the largest size and scaled down, so it never re-wraps or re-lays out mid-move.
 */
const LINE = 1.178; // SF Pro's ascent + descent per point: the app's line box (MusicGeometry.lineBox)

type Box = { left?: number; right?: number; top: number; center?: boolean };
type Text = Box & { size: number; alpha: number };
type Geometry = {
  art: { left: number; top: number; width: number; height: number; radius: number; shadow: number };
  title: Text;
  artist: Text;
  bar: { left: number; top: number; width: number; height: number; track: number };
  elapsed: Text;
  remaining: Text;
  timesShown: boolean;
};

type TextKey = "title" | "artist" | "elapsed" | "remaining";
/** Each line is set at its largest size and scaled down from there. */
const BASE: Record<TextKey, number> = { title: 80, artist: 40, elapsed: 19.5, remaining: 19.5 };

const GEOMETRY: Record<LayoutId, Geometry> = {
  // Artwork 0.48 u left, a 0.64 u column right, the column centred on the art.
  album: {
    art: { left: 260.1, top: 250, width: 480, height: 480, radius: 2.8, shadow: 1 },
    title: { left: 815.1, top: 369.7, size: 64, alpha: 0.98 },
    artist: { left: 815.1, top: 463.1, size: 40, alpha: 0.82 },
    bar: { left: 815.1, top: 564.2, width: 480, height: 6.2, track: 0.2 },
    elapsed: { left: 815.1, top: 587.4, size: 19.5, alpha: 0.64 },
    remaining: { right: 304.9, top: 587.4, size: 19.5, alpha: 0.64 },
    timesShown: true,
  },
  // Spotify TV: 0.42 u artwork centred, the type centred under it.
  stage: {
    art: { left: 590, top: 113.1, width: 420, height: 420, radius: 2.4, shadow: 1 },
    title: { center: true, top: 585.1, size: 58, alpha: 0.98 },
    artist: { center: true, top: 666.4, size: 36, alpha: 0.82 },
    bar: { left: 590, top: 750.8, width: 420, height: 5.8, track: 0.2 },
    elapsed: { left: 590, top: 770.6, size: 15.8, alpha: 0.64 },
    remaining: { right: 590, top: 770.6, size: 15.8, alpha: 0.64 },
    timesShown: true,
  },
  // Full-bleed artwork, type bottom-left over the scrim.
  cover: {
    art: { left: 0, top: 0, width: 1600, height: 1000, radius: 0, shadow: 0 },
    title: { left: 72, top: 677.8, size: 80, alpha: 0.98 },
    artist: { left: 72, top: 788, size: 40, alpha: 0.86 },
    bar: { left: 72, top: 885.2, width: 560, height: 6.2, track: 0.26 },
    elapsed: { left: 72, top: 907.4, size: 17.2, alpha: 0.72 },
    remaining: { right: 968, top: 907.4, size: 17.2, alpha: 0.72 },
    timesShown: true,
  },
  // Corner, Medium, bottom left: 112 pt artwork, title / artist / thin bar beside it. No times
  // here — they shrink under the bar and fade.
  corner: {
    art: { left: 58, top: 830, width: 112, height: 112, radius: 8.5, shadow: 0.8 },
    title: { left: 189, top: 847.1, size: 24.1, alpha: 0.98 },
    artist: { left: 189, top: 880.5, size: 21.3, alpha: 0.82 },
    bar: { left: 189, top: 922.4, width: 195, height: 2.5, track: 0.22 },
    elapsed: { left: 189, top: 929, size: 8, alpha: 0 },
    remaining: { right: 1216, top: 929, size: 8, alpha: 0 },
    timesShown: false,
  },
};

const FONT: CSSProperties = {
  fontFamily: '-apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", "Segoe UI", Roboto, sans-serif',
  lineHeight: LINE,
  whiteSpace: "nowrap",
  color: "#fff",
};

// --- The playhead: a tiny store so only the clock text and the fill re-render each second,
// never the layout-animated elements (a re-render of those makes framer measure them).
const DURATION = 215;
let elapsed = 104;
const listeners = new Set<() => void>();
const playhead = {
  subscribe(fn: () => void) {
    listeners.add(fn);
    return () => listeners.delete(fn);
  },
  get: () => elapsed,
  tick() {
    elapsed = elapsed >= DURATION ? 0 : elapsed + 1;
    listeners.forEach((fn) => fn());
  },
};
const usePlayhead = () => useSyncExternalStore(playhead.subscribe, playhead.get, playhead.get);
const clock = (s: number) => `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;

function Elapsed() {
  return <>{clock(usePlayhead())}</>;
}
function Remaining() {
  return <>{"−" + clock(DURATION - usePlayhead())}</>;
}
function Fill() {
  const t = usePlayhead();
  return (
    <div
      className="absolute inset-y-0 left-0 rounded-[inherit] bg-white/90"
      style={{ width: `${(t / DURATION) * 100}%`, transition: t === 0 ? "none" : "width 1s linear" }}
    />
  );
}

function prefetch(src: string) {
  const img = new Image();
  img.src = src;
}

export function NowPlaying() {
  const [active, setActive] = useState<LayoutId>("album");
  // Only what the visitor asks for is downloaded: the art and the living background up
  // front (lazily), Cover's backdrop and Topography when their layout is hovered or picked.
  const [want, setWant] = useState({ cover: false, topography: false });
  const [loaded, setLoaded] = useState({ cover: false, topography: false });
  const reduce = useReducedMotion();
  const frameRef = useRef<HTMLDivElement>(null);
  // The frame's width in px (design px × scale), and the text's natural widths at BASE size.
  const [width, setWidth] = useState(0);
  const [instant, setInstant] = useState(true); // first placement and resizes don't animate
  const [widths, setWidths] = useState<Record<TextKey, number>>({ title: 0, artist: 0, elapsed: 0, remaining: 0 });
  const textRefs = useRef<Partial<Record<TextKey, HTMLDivElement | null>>>({});
  const scale = width / 1600;

  useLayoutEffect(() => {
    const el = frameRef.current;
    if (!el) return;
    const ro = new ResizeObserver(([e]) => {
      setInstant(true);
      setWidth(e.contentRect.width);
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  useLayoutEffect(() => {
    // Untransformed widths (offsetWidth ignores transforms); fonts may load late, so re-measure then too.
    const measure = () =>
      setWidths((old) => {
        const next = { ...old };
        (Object.keys(next) as TextKey[]).forEach((k) => (next[k] = textRefs.current[k]?.offsetWidth ?? 0));
        return next;
      });
    measure();
    document.fonts?.ready.then(measure);
  }, [width]);
  useEffect(() => {
    if (!instant || width === 0) return;
    const id = requestAnimationFrame(() => setInstant(false));
    return () => cancelAnimationFrame(id);
  }, [instant, width]);
  const inView = useInView(frameRef, { margin: "100px" });

  useEffect(() => {
    if (!inView || reduce) return;
    const id = window.setInterval(playhead.tick, 1000);
    return () => window.clearInterval(id);
  }, [inView, reduce]);

  const need = (id: LayoutId) => {
    if (id === "cover" && !want.cover) setWant((w) => ({ ...w, cover: true }));
    if (id === "corner" && !want.topography) setWant((w) => ({ ...w, topography: true }));
  };
  const warm = (id: LayoutId) => {
    if (id === "cover") prefetch(MEDIA.cover);
    if (id === "corner") prefetch(MEDIA.topography);
  };
  const pick = (id: LayoutId) => {
    need(id);
    setActive(id);
  };

  const g = GEOMETRY[active];
  // One soft, critically damped spring for every moving part: no overshoot, eases in and
  // out, and keeps its velocity when retargeted mid-move.
  const move: Transition = reduce || instant ? { duration: 0 } : { type: "spring", duration: 1.0, bounce: 0 };
  const fade = (d: number, delay = 0): Transition =>
    reduce ? { duration: 0.25 } : { duration: d, delay, ease: [0.4, 0, 0.2, 1] };
  const px = (design: number) => design * scale;
  const textAt = (k: TextKey) => {
    const t = g[k];
    const sc = t.size / BASE[k];
    const w = widths[k] * sc;
    const x = t.center ? (width - w) / 2 : t.right !== undefined ? width - px(t.right) - w : px(t.left ?? 0);
    return { x, y: px(t.top), scale: sc };
  };
  const artRadius = (g.art.radius / 100) * px(g.art.width);
  const artImg =
    active === "cover"
      ? { x: px(-64), y: px(-384), width: px(1728), height: px(1728) }
      : { x: 0, y: 0, width: px(g.art.width), height: px(g.art.height) };
  const shadow = (k: number, w: number) =>
    `0px ${px(w * 0.035 * k)}px ${px(w * 0.2 * k)}px rgba(0,0,0,${0.3 * k}), 0px ${px(w * 0.008)}px ${px(w * 0.03)}px rgba(0,0,0,${0.22 * k})`;

  const showTopo = active === "corner" && loaded.topography;
  const showCover = active === "cover" && loaded.cover;
  const label = LAYOUTS.find((l) => l.id === active)!.alt;

  return (
    <section id="music" className="relative bg-black section-pad">
      <div className="mx-auto max-w-7xl">
        <SectionHeader eyebrow="Music" title="What's playing," aside="over any screensaver.">
          <p className="mt-6 max-w-2xl text-xs leading-relaxed text-primary/70 sm:text-sm md:text-base">
            Spotify or Apple Music, in a corner or full screen.
          </p>
        </SectionHeader>

        <Reveal className="mx-auto max-w-5xl">
          <figure>
            <div
              ref={frameRef}
              role="img"
              aria-label={`${label}. Now playing: ${SONG.title} by ${SONG.artist}.`}
              className="relative aspect-[16/10] overflow-hidden rounded-2xl bg-[#0c0c0c]"
              style={{ containerType: "inline-size" }}
            >
              <div aria-hidden className="absolute inset-0">
                {/* Living album art (Album, Stage; and under Cover's art). */}
                <motion.div
                  className="absolute inset-0"
                  initial={false}
                  animate={{ opacity: showTopo ? 0 : 1 }}
                  transition={fade(0.6)}
                >
                  <img
                    src={MEDIA.living}
                    alt=""
                    width={800}
                    height={500}
                    loading="lazy"
                    decoding="async"
                    className={`np-drift absolute inset-0 h-full w-full object-cover ${reduce ? "" : "np-drift-on"}`}
                  />
                </motion.div>

                {/* Topography, the screensaver the Corner card sits on. */}
                {want.topography && (
                  <motion.img
                    src={MEDIA.topography}
                    alt=""
                    width={1600}
                    height={1000}
                    decoding="async"
                    onLoad={() => setLoaded((l) => ({ ...l, topography: true }))}
                    className="absolute inset-0 h-full w-full object-cover"
                    initial={{ opacity: 0 }}
                    animate={{ opacity: showTopo ? 1 : 0 }}
                    transition={fade(0.6)}
                  />
                )}

                {/* The artwork: one box that slides and resizes, from a square beside the song to
                    the whole screen to a corner thumbnail. The image inside keeps its square and is
                    cropped by the box, never stretched. In Cover it sits exactly where the app's
                    render has it (1.08× the width, a touch above centre), so the rendered backdrop
                    fades in over it without a shift. */}
                <motion.div
                  className="absolute left-0 top-0"
                  initial={false}
                  animate={{ x: px(g.art.left), y: px(g.art.top), width: px(g.art.width), height: px(g.art.height) }}
                  transition={move}
                  style={{ opacity: width ? 1 : 0 }}
                >
                  <motion.div
                    className="absolute inset-0"
                    initial={false}
                    animate={{ borderRadius: artRadius, boxShadow: shadow(g.art.shadow, g.art.width) }}
                    transition={move}
                  />
                  <motion.div
                    className="absolute inset-0 overflow-hidden"
                    initial={false}
                    animate={{ borderRadius: artRadius }}
                    transition={move}
                    style={{ transform: "translateZ(0)" }}
                  >
                    <motion.img
                      src={MEDIA.art}
                      alt=""
                      width={640}
                      height={640}
                      loading="lazy"
                      decoding="async"
                      className="absolute left-0 top-0 max-w-none"
                      initial={false}
                      animate={artImg}
                      transition={move}
                    />
                  </motion.div>
                </motion.div>

                {/* Cover's backdrop as the app renders it: the same full-bleed art with its corner
                    blurred and dimmed for the type. It settles in once the art has filled the
                    frame, and eases out as the art starts to shrink away. */}
                {want.cover && (
                  <motion.img
                    src={MEDIA.cover}
                    alt=""
                    width={1280}
                    height={800}
                    decoding="async"
                    onLoad={() => setLoaded((l) => ({ ...l, cover: true }))}
                    className="absolute inset-0 h-full w-full object-cover"
                    initial={{ opacity: 0 }}
                    animate={{ opacity: showCover ? 1 : 0 }}
                    transition={showCover ? fade(0.6, reduce ? 0 : 0.6) : fade(0.3)}
                  />
                )}

                {/* Corner's feathered scrim (MusicOverlayLayer.addScrim), so the type reads on any scene. */}
                <motion.div
                  className="absolute inset-0"
                  initial={false}
                  animate={{ opacity: active === "corner" ? 1 : 0 }}
                  transition={fade(0.7)}
                  style={{
                    background: `radial-gradient(${px(580)}px ${px(288)}px at ${px(162)}px ${px(906)}px, rgba(0,0,0,.56) 0%, rgba(0,0,0,.49) 22.7%, rgba(0,0,0,.34) 45.5%, rgba(0,0,0,.18) 68%, rgba(0,0,0,.076) 91%, rgba(0,0,0,0) 100%)`,
                  }}
                />

                {/* The type. Each line is one element that glides and rescales into place. */}
                {(["title", "artist"] as const).map((k) => (
                  <motion.div
                    key={k}
                    ref={(el) => (textRefs.current[k] = el)}
                    className={`absolute left-0 top-0 ${k === "title" ? "font-medium" : "font-normal"}`}
                    initial={false}
                    animate={{ ...textAt(k), color: `rgba(255,255,255,${g[k].alpha})` }}
                    transition={move}
                    style={{
                      ...FONT,
                      fontSize: px(BASE[k]),
                      letterSpacing: k === "title" ? "-0.01em" : "-0.002em",
                      originX: 0,
                      originY: 0,
                      opacity: width && widths[k] ? 1 : 0,
                    }}
                  >
                    {SONG[k]}
                  </motion.div>
                ))}

                <motion.div
                  className="absolute left-0 top-0 overflow-hidden rounded-full"
                  initial={false}
                  animate={{
                    x: px(g.bar.left),
                    y: px(g.bar.top),
                    width: px(g.bar.width),
                    height: px(g.bar.height),
                    backgroundColor: `rgba(255,255,255,${g.bar.track})`,
                  }}
                  transition={move}
                  style={{ opacity: width ? 1 : 0 }}
                >
                  <Fill />
                </motion.div>

                {(["elapsed", "remaining"] as const).map((k) => (
                  <motion.div
                    key={k}
                    ref={(el) => (textRefs.current[k] = el)}
                    className="absolute left-0 top-0 font-normal"
                    initial={false}
                    animate={{ ...textAt(k), opacity: width && widths[k] ? g[k].alpha : 0 }}
                    transition={{
                      ...move,
                      opacity: instant ? { duration: 0 } : fade(g.timesShown ? 0.5 : 0.3, g.timesShown && !reduce ? 0.45 : 0),
                    }}
                    style={{
                      ...FONT,
                      fontSize: px(BASE[k]),
                      fontVariantNumeric: "tabular-nums",
                      originX: 0,
                      originY: 0,
                    }}
                  >
                    {k === "elapsed" ? <Elapsed /> : <Remaining />}
                  </motion.div>
                ))}
              </div>
            </div>
            <div className="mt-4 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
              <div role="group" aria-label="Choose a layout" className="-mx-1 flex flex-wrap gap-1.5">
                {LAYOUTS.map((l) => {
                  const on = l.id === active;
                  return (
                    <button
                      key={l.id}
                      type="button"
                      aria-pressed={on}
                      onClick={() => pick(l.id)}
                      onPointerEnter={() => warm(l.id)}
                      onFocus={() => warm(l.id)}
                      className={`rounded-full px-3.5 py-1.5 text-xs transition-colors duration-200 sm:text-sm ${
                        on ? "bg-primary text-black" : "bg-white/[0.05] text-gray-300 hover:bg-white/[0.09]"
                      }`}
                    >
                      {l.name}
                    </button>
                  );
                })}
              </div>
              <figcaption className="text-[11px] text-gray-600">
                &ldquo;{SONG.title}&rdquo; by {SONG.artist}.
              </figcaption>
            </div>
          </figure>
        </Reveal>
      </div>
    </section>
  );
}
