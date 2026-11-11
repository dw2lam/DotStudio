import { useEffect, useRef, useState } from "react";
import { motion, AnimatePresence, useInView, useReducedMotion } from "framer-motion";
import { Reveal } from "../components/Reveal";
import { SectionHeader } from "../components/SectionHeader";

/*
 * Live sky: Golden Hour rendered by the app (tools/gallery, Follow the Sun, San Francisco,
 * 24 Nov 2026 — a near-full moon) at four times of day under six weathers. The visitor
 * picks a time and a weather; until they do, the day plays through on its own.
 */

const TIMES = [
  { id: "morning", name: "Morning", clock: "8:30 AM" },
  { id: "midday", name: "Midday", clock: "12:30 PM" },
  { id: "sunset", name: "Sunset", clock: "4:50 PM" },
  { id: "night", name: "Night", clock: "9:30 PM" },
] as const;

const WEATHERS = [
  { id: "clear", name: "Clear" },
  { id: "cloudy", name: "Cloudy" },
  { id: "rain", name: "Rain" },
  { id: "storm", name: "Storm" },
  { id: "fog", name: "Fog" },
  { id: "snow", name: "Snow" },
] as const;

type TimeId = (typeof TIMES)[number]["id"];
type WeatherId = (typeof WEATHERS)[number]["id"];

const src = (w: WeatherId, t: TimeId) => `/media/livesky/${w}-${t}.webp`;
const prefetch = (url: string) => {
  const img = new Image();
  img.src = url;
};

function Chips<T extends string>({
  label,
  items,
  value,
  onPick,
  onWarm,
}: {
  label: string;
  items: readonly { id: T; name: string }[];
  value: T;
  onPick: (id: T) => void;
  onWarm: (id: T) => void;
}) {
  return (
    <div className="flex flex-wrap items-center gap-1.5">
      <span className="w-full text-[10px] sm:mr-1 sm:w-20 uppercase tracking-[0.2em] text-gray-500 sm:text-[11px]">{label}</span>
      <div role="group" aria-label={label} className="flex flex-wrap gap-1.5">
        {items.map((it) => {
          const on = it.id === value;
          return (
            <button
              key={it.id}
              type="button"
              aria-pressed={on}
              onClick={() => onPick(it.id)}
              onPointerEnter={() => onWarm(it.id)}
              onFocus={() => onWarm(it.id)}
              className={`rounded-full px-3.5 py-1.5 text-xs transition-colors duration-200 sm:text-sm ${
                on ? "bg-primary text-black" : "bg-white/[0.05] text-gray-300 hover:bg-white/[0.09]"
              }`}
            >
              {it.name}
            </button>
          );
        })}
      </div>
    </div>
  );
}

export function LiveSky() {
  const [time, setTime] = useState<TimeId>("sunset");
  const [weather, setWeather] = useState<WeatherId>("clear");
  const [touched, setTouched] = useState(false);
  // Only frames the visitor has reached are ever downloaded; they stay mounted so going
  // back is instant and every change is a crossfade.
  const [seen, setSeen] = useState<string[]>([src("clear", "sunset")]);
  const reduce = useReducedMotion();
  const frameRef = useRef<HTMLDivElement>(null);
  const inView = useInView(frameRef, { margin: "-20% 0px" });

  const show = (w: WeatherId, t: TimeId) => {
    const url = src(w, t);
    setSeen((s) => (s.includes(url) ? s : [...s, url]));
    setWeather(w);
    setTime(t);
  };

  // Until the visitor picks something, the day plays through: morning, midday, sunset, night.
  useEffect(() => {
    if (touched || reduce || !inView) return;
    const id = window.setTimeout(() => {
      const i = TIMES.findIndex((t) => t.id === time);
      const next = TIMES[(i + 1) % TIMES.length].id;
      prefetch(src(weather, TIMES[(i + 2) % TIMES.length].id));
      show(weather, next);
    }, 3800);
    return () => window.clearTimeout(id);
  }, [touched, reduce, inView, time, weather]);

  const active = src(weather, time);
  const t = TIMES.find((x) => x.id === time)!;
  const w = WEATHERS.find((x) => x.id === weather)!;

  return (
    <section id="sky" className="relative bg-black px-4 py-20 sm:py-28 md:py-32">
      <div className="mx-auto max-w-7xl">
        <SectionHeader eyebrow="Live Sky" title="Your sky, live.">
          <p className="mt-6 max-w-2xl text-xs leading-relaxed text-primary/70 sm:text-sm md:text-base">
            Turn on Follow the Sun and Golden Hour tracks the real sun, moon and weather where you are.
          </p>
        </SectionHeader>

        <Reveal className="mx-auto max-w-5xl">
          <figure>
            <div
              ref={frameRef}
              className="relative aspect-[16/10] overflow-hidden rounded-2xl bg-[#0c0c0c]"
            >
              {seen.map((url) => (
                <img
                  key={url}
                  src={url}
                  alt={url === active ? `Golden Hour at ${t.name.toLowerCase()}, ${w.name.toLowerCase()}` : ""}
                  width={1600}
                  height={1000}
                  loading={url === seen[0] ? "lazy" : "eager"}
                  decoding="async"
                  className={`absolute inset-0 h-full w-full object-cover transition-opacity ease-in-out ${
                    reduce ? "duration-200" : "duration-[1200ms]"
                  } ${url === active ? "opacity-100" : "opacity-0"}`}
                />
              ))}

              {/* What the scene is following right now, the way a widget would say it. */}
              <div className="absolute left-3 top-3 flex items-center gap-2 rounded-full bg-black/35 px-3 py-1.5 text-[10px] text-white/90 backdrop-blur-md sm:left-4 sm:top-4 sm:text-xs">
                <span className="relative flex h-1.5 w-1.5">
                  <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-emerald-400/60 motion-reduce:animate-none" />
                  <span className="relative inline-flex h-1.5 w-1.5 rounded-full bg-emerald-400" />
                </span>
                <span>San Francisco</span>
                <span className="text-white/40">·</span>
                <AnimatePresence mode="popLayout" initial={false}>
                  <motion.span
                    key={t.clock + w.name}
                    initial={{ opacity: 0, y: 4 }}
                    animate={{ opacity: 1, y: 0 }}
                    exit={{ opacity: 0, y: -4 }}
                    transition={{ duration: reduce ? 0 : 0.35 }}
                    className="tabular-nums"
                  >
                    {t.clock} · {w.name}
                  </motion.span>
                </AnimatePresence>
              </div>
            </div>

            <div className="mt-4 flex flex-col gap-2.5">
              <Chips
                label="Time"
                items={TIMES}
                value={time}
                onPick={(id) => {
                  setTouched(true);
                  show(weather, id);
                }}
                onWarm={(id) => prefetch(src(weather, id))}
              />
              <Chips
                label="Weather"
                items={WEATHERS}
                value={weather}
                onPick={(id) => {
                  setTouched(true);
                  show(id, time);
                }}
                onWarm={(id) => prefetch(src(id, time))}
              />
            </div>
            <figcaption className="sr-only">
              Golden Hour, rendered by DotStudio for San Francisco at four times of day and in six kinds of weather.
            </figcaption>
          </figure>

          <p className="mt-6 text-[11px] text-gray-600 sm:text-xs">
            Your location is rounded to about 10 km. Weather by Open-Meteo.
          </p>
        </Reveal>
      </div>
    </section>
  );
}
