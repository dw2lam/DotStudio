import { Reveal } from "../components/Reveal";
import { LoopVideo } from "../components/LoopVideo";
import { CycleStills } from "../components/CycleStills";
import { SectionHeader } from "../components/SectionHeader";

const CREAM = "#E1E0CC";

type Tile = {
  name: string;
  blurb: string;
  /** A render loop under /media/loops, a still under /media/scenes, or stills to cycle through. */
  loop?: string;
  still?: string;
  cycle?: { src: string; alt: string }[];
  span: string;
  aspect: string;
};

// The owner's favourites, one appearance each across the page. Clocks, the other
// water scenes and the classic genres live in Packs.
const TILES: Tile[] = [
  {
    name: "Liquid Chrome",
    blurb: "Molten, iridescent metal that never settles.",
    loop: "liquid",
    span: "md:col-span-8 md:row-span-2",
    aspect: "aspect-[16/10] md:aspect-auto md:h-full",
  },
  {
    name: "Zen Garden",
    blurb: "A little rake cart re-rakes the gravel, pattern after pattern.",
    still: "zen-garden",
    span: "md:col-span-4",
    aspect: "aspect-[16/10]",
  },
  {
    name: "Tidewater",
    blurb: "Your sky, live: the real sun, moon and weather, snow included.",
    cycle: [
      { src: "/media/scenes/tidewater-dusk.webp", alt: "Tidewater at dusk, a crescent moon over the sea" },
      { src: "/media/scenes/tidewater-night.webp", alt: "Tidewater at night, moonlight on the water" },
      { src: "/media/scenes/tidewater-morning.webp", alt: "Tidewater in the morning, low sun through broken cloud" },
      { src: "/media/scenes/tidewater-snow.webp", alt: "Tidewater in falling snow" },
    ],
    span: "md:col-span-4",
    aspect: "aspect-[16/10]",
  },
  {
    name: "Topography",
    blurb: "Contour lines drifting like a living map.",
    still: "topography",
    span: "md:col-span-6",
    aspect: "aspect-[16/10]",
  },
  {
    name: "Universe",
    blurb: "The solar system tonight, on a slowly orbiting camera.",
    still: "universe",
    span: "md:col-span-6",
    aspect: "aspect-[16/10]",
  },
];

export function Showcase() {
  return (
    <section id="scenes" className="relative bg-black px-4 py-20 sm:py-28 md:py-32">
      <div className="mx-auto max-w-7xl">
        <SectionHeader eyebrow="The best of the library" title="Screensavers that paint themselves." aside="Every frame here is rendered by the app.">
          <p className="mt-6 max-w-2xl text-xs leading-relaxed text-primary/70 sm:text-sm md:text-base">
            Scenes are generative pieces drawn live on your Mac's GPU: no video files, nothing
            to set up. Pick one, or let the library rotate through your favourites.
          </p>
        </SectionHeader>

        <div className="grid grid-cols-1 gap-3 md:grid-cols-12">
          {TILES.map((t, i) => (
            <Reveal key={t.name} index={i % 3} className={`h-full ${t.span}`}>
              <figure className={`group relative h-full overflow-hidden rounded-2xl bg-[#0c0c0c] ${t.aspect}`}>
                {t.loop ? (
                  <LoopVideo
                    name={t.loop}
                    alt={`${t.name}, rendered live by DotStudio`}
                    className="absolute inset-0 h-full w-full object-cover"
                  />
                ) : t.cycle ? (
                  <CycleStills frames={t.cycle} className="absolute inset-0 h-full w-full" />
                ) : (
                  <img
                    src={`/media/scenes/${t.still}.webp`}
                    alt={`${t.name}, a DotStudio scene`}
                    loading="lazy"
                    decoding="async"
                    width={1600}
                    height={1000}
                    className="absolute inset-0 h-full w-full object-cover transition-transform duration-700 group-hover:scale-[1.03]"
                  />
                )}
                <div className="pointer-events-none absolute inset-0 bg-gradient-to-t from-black/75 via-black/0 to-transparent" />
                <figcaption className="absolute bottom-0 left-0 right-0 p-4 sm:p-5">
                  <span className="block text-base font-bold sm:text-lg" style={{ color: CREAM }}>
                    {t.name}
                  </span>
                  <span className="mt-0.5 block text-[11px] text-gray-300/80 sm:text-xs">{t.blurb}</span>
                </figcaption>
              </figure>
            </Reveal>
          ))}
        </div>
      </div>
    </section>
  );
}
