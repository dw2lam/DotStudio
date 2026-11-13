import { useEffect, useRef, useState } from "react";
import { useReducedMotion } from "framer-motion";

/*
 * The hero backdrop: a slow, full-bleed crossfade through the app's best scenes, every frame
 * rendered by the app itself (tools/gallery). Each clip is 8 s at 24 fps, 1600×1000, with its
 * first frame as a .webp poster, so a scene is on screen from the moment it fades in until it
 * has faded out under the next one (ADVANCE + FADE = 8 s).
 *
 * Phones (portrait screens) get 720×1600 renders of the same scenes instead of a centre crop.
 *
 * Loading: only the first poster is fetched up front (it is the hero's LCP image). Videos and
 * the next poster load while the hero is on screen, one scene ahead (the next one once the
 * current clip is playing, so the two never compete for bandwidth on the first load). Everything pauses when
 * the hero scrolls away or the tab is hidden. Under prefers-reduced-motion no video is loaded:
 * the posters crossfade slowly instead.
 */

/** `loop` is the landscape clip (1600×1000), `tall` the portrait one (720×1600) for phones. */
type Scene = { loop: string; tall: string; name: string };

const SCENES: Scene[] = [
  { loop: "liquid", tall: "hero-liquid-p", name: "Liquid Chrome" },
  { loop: "hero-tidewater", tall: "hero-tidewater-p", name: "Golden Hour" },
  { loop: "hero-blackhole", tall: "hero-blackhole-p", name: "Black Hole" },
  { loop: "hero-universe", tall: "hero-universe-p", name: "Universe" },
];

/** Narrow screens get the portrait renders (a phone would crop a landscape clip to a sliver). */
const TALL_QUERY = "(max-aspect-ratio: 4/5)";

const ADVANCE = 6500; // ms from one scene starting to fade in to the next
const FADE = 1500;
const ADVANCE_REDUCED = 9000;
const FADE_REDUCED = 2400;

const clip = (s: Scene, tall: boolean) => `/media/loops/${tall ? s.tall : s.loop}`;

export const HERO_REEL_DESCRIPTION =
  "Scenes rendered by DotStudio, crossfading in turn: Liquid Chrome, Golden Hour under a live sunset sky, Black Hole and Universe.";

export function HeroReel() {
  const reduced = useReducedMotion() ?? false;
  const rootRef = useRef<HTMLDivElement>(null);
  const videos = useRef<(HTMLVideoElement | null)[]>([]);
  const [active, setActive] = useState(0);
  const [prev, setPrev] = useState<number | null>(null);
  const [armed, setArmed] = useState<ReadonlySet<number>>(() => new Set([0]));
  const [inView, setInView] = useState(false);
  const [tabVisible, setTabVisible] = useState(true);
  const [ready, setReady] = useState<ReadonlySet<number>>(() => new Set());
  const [tall, setTall] = useState(() => typeof window !== "undefined" && window.matchMedia(TALL_QUERY).matches);
  const running = inView && tabVisible;
  const fade = reduced ? FADE_REDUCED : FADE;

  // On screen? Visible tab?
  useEffect(() => {
    const el = rootRef.current;
    if (!el) return;
    if (!("IntersectionObserver" in window)) {
      setInView(true);
      return;
    }
    const io = new IntersectionObserver(([e]) => setInView(e.isIntersecting), { threshold: 0.01 });
    io.observe(el);
    return () => io.disconnect();
  }, []);
  useEffect(() => {
    const sync = () => setTabVisible(document.visibilityState !== "hidden");
    sync();
    document.addEventListener("visibilitychange", sync);
    return () => document.removeEventListener("visibilitychange", sync);
  }, []);

  // Portrait or landscape renders; a rotation swaps every clip (and they must play again
  // before they cover their posters).
  useEffect(() => {
    const mq = window.matchMedia(TALL_QUERY);
    const sync = () => {
      setTall(mq.matches);
      setReady(new Set());
    };
    mq.addEventListener("change", sync);
    return () => mq.removeEventListener("change", sync);
  }, []);

  // Load the current scene while the hero is being watched, and the next one as soon as the
  // current clip plays (or after a moment regardless, e.g. when autoplay is refused).
  useEffect(() => {
    if (!running) return;
    const arm = (...ids: number[]) =>
      setArmed((a) => (ids.every((i) => a.has(i)) ? a : new Set([...a, ...ids])));
    const next = (active + 1) % SCENES.length;
    arm(active);
    if (reduced || ready.has(active)) {
      arm(next);
      return;
    }
    const id = window.setTimeout(() => arm(next), 2500);
    return () => window.clearTimeout(id);
  }, [running, active, ready, reduced]);

  // Advance on a timer while running. A pause (hero off screen, tab hidden) keeps the time
  // the scene has already had, so on return it finishes its slot rather than outlasting its clip.
  const spent = useRef({ scene: 0, ms: 0 });
  useEffect(() => {
    if (!running) return;
    if (spent.current.scene !== active) spent.current = { scene: active, ms: 0 };
    const startedAt = performance.now();
    const left = Math.max(0, (reduced ? ADVANCE_REDUCED : ADVANCE) - spent.current.ms);
    const id = window.setTimeout(() => {
      setPrev(active);
      setActive((active + 1) % SCENES.length);
    }, left);
    return () => {
      window.clearTimeout(id);
      if (spent.current.scene === active) spent.current.ms += performance.now() - startedAt;
    };
  }, [running, active, reduced]);

  // Once the outgoing scene has faded out under the new one, drop it and rewind its clip.
  useEffect(() => {
    if (prev === null) return;
    const id = window.setTimeout(() => {
      const v = videos.current[prev];
      if (v) {
        v.pause();
        try {
          v.currentTime = 0;
        } catch {
          /* not seekable yet */
        }
      }
      setPrev(null);
    }, fade + 100);
    return () => window.clearTimeout(id);
  }, [prev, fade]);

  // Play the current clip (from where it is: it was rewound when it last went out), pause the
  // rest; everything stops while the hero is off screen or the tab is hidden.
  useEffect(() => {
    videos.current.forEach((v, i) => {
      if (!v) return;
      if (running && !reduced && (i === active || i === prev)) {
        v.play().catch(() => {});
      } else {
        v.pause();
      }
    });
  }, [running, reduced, active, prev, armed, tall]);

  return (
    <>
      {/* isolate: the layers' z-indices stay inside the backdrop, under the scrims and copy. */}
      <div ref={rootRef} role="img" aria-label={HERO_REEL_DESCRIPTION} className="absolute inset-0 isolate bg-black">
        {SCENES.map((s, i) => {
          if (!armed.has(i)) return null;
          const on = i === active;
          const under = i === prev;
          return (
            <div
              key={s.loop}
              className="absolute inset-0 transition-opacity ease-in-out"
              style={{ opacity: on || under ? 1 : 0, zIndex: on ? 2 : under ? 1 : 0, transitionDuration: `${fade}ms` }}
            >
              <img
                src={`${clip(s, tall)}.webp`}
                alt=""
                width={tall ? 720 : 1600}
                height={tall ? 1600 : 1000}
                decoding={i === 0 ? "sync" : "async"}
                {...{ fetchpriority: i === 0 ? "high" : "low" }}
                className="absolute inset-0 h-full w-full object-cover"
              />
              {!reduced && (
                <video
                  key={tall ? "tall" : "wide"}
                  ref={(el) => {
                    videos.current[i] = el;
                  }}
                  className={`absolute inset-0 h-full w-full object-cover transition-opacity duration-300 ${
                    ready.has(i) ? "opacity-100" : "opacity-0"
                  }`}
                  muted
                  playsInline
                  preload="auto"
                  disablePictureInPicture
                  aria-hidden="true"
                  tabIndex={-1}
                  onPlaying={() => setReady((r) => (r.has(i) ? r : new Set([...r, i])))}
                >
                  <source src={`${clip(s, tall)}.webm`} type={`video/webm; codecs="vp9"`} />
                  <source src={`${clip(s, tall)}.mp4`} type="video/mp4" />
                </video>
              )}
            </div>
          );
        })}
      </div>

    </>
  );
}
