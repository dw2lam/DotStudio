import type { ReactNode } from "react";
import { Reveal } from "../components/Reveal";
import { LoopVideo } from "../components/LoopVideo";
import { SectionHeader } from "../components/SectionHeader";

const CREAM = "#E1E0CC";

function Still({ name, alt, wide = false }: { name: string; alt: string; wide?: boolean }) {
  return (
    <img
      src={`/media/scenes/${name}.webp`}
      alt={alt}
      loading="lazy"
      decoding="async"
      width={1600}
      height={wide ? 500 : 1000}
      className="h-full w-full object-cover"
    />
  );
}

type Pack = { name: string; line: string; scenes: string[]; media: ReactNode };

const PACKS: Pack[] = [
  {
    name: "Clocks",
    line: "The time, set beautifully, and always right.",
    scenes: ["Glass & Plaster Clock", "3D Flip Clock", "Word Clock", "Window Light"],
    media: (
      <div className="grid h-full grid-cols-2 grid-rows-2 gap-1.5">
        <div className="col-span-2 min-h-0 overflow-hidden rounded-lg">
          <Still wide name="flip-clock" alt="Flip Clock: split-flap digits that really fall" />
        </div>
        <div className="min-h-0 overflow-hidden rounded-lg">
          <Still name="glass-clock" alt="Glass Clock: the time set huge in glass type" />
        </div>
        <div className="min-h-0 overflow-hidden rounded-lg">
          <Still name="window-light" alt="Window Light: sun through a window drifting across a wall" />
        </div>
      </div>
    ),
  },
  {
    name: "Flowing",
    line: "Slow, warm motion to stare into.",
    scenes: ["Lava Lamp", "Currents", "Fireflies"],
    media: (
      <div className="h-full overflow-hidden rounded-lg">
        <LoopVideo name="lava" alt="Lava Lamp, rendered live by DotStudio" className="h-full w-full object-cover" />
      </div>
    ),
  },
  {
    name: "Nature",
    line: "Real skies and water, tuned to tonight.",
    scenes: ["Golden Hour", "Night Sky", "First Snow", "Aurora"],
    media: (
      <div className="h-full overflow-hidden rounded-lg">
        <Still name="night-sky" alt="Night Sky: the Milky Way over a ridge, with tonight's moon phase" />
      </div>
    ),
  },
  {
    name: "Retro",
    line: "Classic screensaver genres, re-rendered.",
    scenes: ["Neon Horizon", "Pipeworks", "Light Tunnel", "Light Ribbons"],
    media: (
      <div className="h-full overflow-hidden rounded-lg">
        <Still name="pipeworks" alt="Pipeworks: glossy ray-traced pipes growing through a dark room" />
      </div>
    ),
  },
];

const NOTES: Record<string, string> = {
  "Night Sky": "with the real moon phase",
  Aurora: "rebuilt",
};

export function Packs() {
  return (
    <section id="packs" className="relative bg-black px-4 py-20 sm:py-28 md:py-32">
      <div className="mx-auto max-w-7xl">
        <SectionHeader eyebrow="New scene packs" title="Four new packs." aside="All in the default library." />

        <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
          {PACKS.map((p, i) => (
            <Reveal key={p.name} index={i % 2} className="h-full">
              <article className="flex h-full flex-col rounded-2xl bg-[#161616] p-2.5 sm:p-3">
                <div className="aspect-[16/10] overflow-hidden">{p.media}</div>
                <div className="flex flex-1 flex-col px-2.5 pb-2.5 pt-4 sm:px-3 sm:pb-3">
                  <div className="flex items-baseline justify-between gap-4">
                    <h3 className="text-lg font-bold sm:text-xl" style={{ color: CREAM }}>
                      {p.name}
                    </h3>
                    <span className="text-xs text-gray-500">{p.scenes.length} scenes</span>
                  </div>
                  <p className="mt-1 text-xs text-gray-400 sm:text-sm">{p.line}</p>
                  <ul className="mt-4 flex flex-wrap gap-x-4 gap-y-1 text-xs text-gray-500 sm:text-[13px]">
                    {p.scenes.map((s) => (
                      <li key={s}>
                        <span className="text-gray-300">{s}</span>
                        {NOTES[s] && <span className="text-gray-500">, {NOTES[s]}</span>}
                      </li>
                    ))}
                  </ul>
                </div>
              </article>
            </Reveal>
          ))}
        </div>
      </div>
    </section>
  );
}
