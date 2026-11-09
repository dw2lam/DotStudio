import { useState } from "react";
import { Reveal } from "../components/Reveal";
import { SectionHeader } from "../components/SectionHeader";

const LAYOUTS = [
  { id: "album", name: "Album", alt: "Full Screen, Album layout: artwork beside the song over living album art" },
  { id: "stage", name: "Stage", alt: "Full Screen, Stage layout: artwork centred above the song" },
  { id: "cover", name: "Cover", alt: "Full Screen, Cover layout: the artwork fills the screen behind the song" },
  { id: "corner", name: "Corner", alt: "A small now-playing card in the corner of the Topography screensaver" },
];

const src = (id: string) => `/media/music/${id}.webp`;

function prefetch(id: string) {
  const img = new Image();
  img.src = src(id);
}

export function NowPlaying() {
  const [active, setActive] = useState("album");
  // Same pattern as Looks: only what the visitor asks for is ever downloaded.
  const [seen, setSeen] = useState<string[]>(["album"]);

  const pick = (id: string) => {
    setActive(id);
    setSeen((s) => (s.includes(id) ? s : [...s, id]));
  };

  return (
    <section id="music" className="relative bg-black px-4 py-20 sm:py-28 md:py-32">
      <div className="mx-auto max-w-7xl">
        <SectionHeader eyebrow="New in 1.4" title="What's playing," aside="over any screensaver.">
          <p className="mt-6 max-w-2xl text-xs leading-relaxed text-primary/70 sm:text-sm md:text-base">
            Spotify or Apple Music, in a corner or across the whole screen, with the album art
            slowly alive behind the song.
          </p>
        </SectionHeader>

        <Reveal className="mx-auto max-w-5xl">
          <figure>
            <div className="relative aspect-[16/10] overflow-hidden rounded-2xl bg-[#0c0c0c]">
              {seen.map((id) => (
                <img
                  key={id}
                  src={src(id)}
                  alt={LAYOUTS.find((l) => l.id === id)?.alt}
                  width={1600}
                  height={1000}
                  loading={id === "album" ? "lazy" : "eager"}
                  decoding="async"
                  className={`absolute inset-0 h-full w-full object-cover transition-opacity duration-500 ${
                    id === active ? "opacity-100" : "opacity-0"
                  }`}
                />
              ))}
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
                      onPointerEnter={() => prefetch(l.id)}
                      onFocus={() => prefetch(l.id)}
                      className={`rounded-full px-3.5 py-1.5 text-xs transition-colors duration-200 sm:text-sm ${
                        on ? "bg-primary text-black" : "bg-white/[0.05] text-gray-300 hover:bg-white/[0.09]"
                      }`}
                    >
                      {l.name}
                    </button>
                  );
                })}
              </div>
              <figcaption className="text-[11px] text-gray-600">Demo track and artwork.</figcaption>
            </div>
          </figure>
        </Reveal>
      </div>
    </section>
  );
}
