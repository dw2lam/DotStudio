import { useState } from "react";
import { Reveal } from "../components/Reveal";
import { SectionHeader } from "../components/SectionHeader";

const LOOKS = [
  { id: "source", name: "Original" },
  { id: "film", name: "Film" },
  { id: "riso-duotone", name: "Riso Duotone" },
  { id: "cyanotype", name: "Cyanotype" },
  { id: "atkinson", name: "Atkinson" },
  { id: "amber-crt", name: "Amber CRT" },
];

const src = (id: string) => `/media/looks/${id}.webp`;

/** Warm the browser cache so switching looks is instant once the visitor reaches for it. */
function prefetch(id: string) {
  const img = new Image();
  img.src = src(id);
}

export function Looks() {
  const [active, setActive] = useState("riso-duotone");
  // Every look the visitor has asked for stays mounted, so switching back cross-fades
  // instead of reloading; the rest are never downloaded.
  const [seen, setSeen] = useState<string[]>(["riso-duotone"]);

  const pick = (id: string) => {
    setActive(id);
    setSeen((s) => (s.includes(id) ? s : [...s, id]));
  };

  return (
    <section id="looks" className="relative bg-black section-pad">
      <div className="mx-auto max-w-7xl">
        <SectionHeader eyebrow="Looks" title="Restyle your own photos" aside="and video." />

        <Reveal className="mx-auto max-w-5xl">
          <figure>
            <div className="relative aspect-[16/10] overflow-hidden rounded-2xl bg-[#0c0c0c]">
              {seen.map((id) => (
                <img
                  key={id}
                  src={src(id)}
                  alt={`Wadi Rum desert photo in the ${LOOKS.find((l) => l.id === id)?.name} look`}
                  width={1280}
                  height={800}
                  loading={id === "riso-duotone" ? "lazy" : "eager"}
                  decoding="async"
                  className={`absolute inset-0 h-full w-full object-cover transition-opacity duration-500 ${
                    id === active ? "opacity-100" : "opacity-0"
                  }`}
                />
              ))}
            </div>
            <div className="mt-4 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
              <div role="group" aria-label="Choose a look" className="-mx-1 flex flex-wrap gap-1.5">
                {LOOKS.map((l) => {
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
            </div>
          </figure>
        </Reveal>

      </div>
    </section>
  );
}
