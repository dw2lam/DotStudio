import { EffectCanvas, type EffectMode } from "../components/EffectCanvas";
import { Reveal } from "../components/Reveal";
import { WordsPullUpMultiStyle } from "../components/animations/WordsPullUpMultiStyle";

const CREAM = "#E1E0CC";

const TILES: { mode: EffectMode; name: string; sub: string; cell: number }[] = [
  { mode: "ascii", name: "ASCII", sub: "luminance → glyphs", cell: 12 },
  { mode: "matrix", name: "Matrix Rain", sub: "falling kana · trails", cell: 12 },
  { mode: "halftone", name: "Halftone", sub: "dot grid · screen", cell: 14 },
];

export function LiveStrip() {
  return (
    <section id="live" className="relative bg-black px-4 py-20 sm:py-28 md:py-32">
      <div className="mx-auto max-w-7xl">
        <header className="mb-8 sm:mb-12">
          <span className="text-[10px] uppercase tracking-[0.25em] text-primary sm:text-xs">
            Live, on this page
          </span>
          <div className="mt-4">
            <WordsPullUpMultiStyle
              className="text-2xl font-normal sm:text-3xl md:text-4xl lg:text-5xl"
              segments={[
                { text: "Running right now.", className: "" },
                { text: "No video — real canvas.", className: "text-gray-500" },
              ]}
            />
          </div>
        </header>

        <div className="grid grid-cols-1 gap-3 md:grid-cols-3">
          {TILES.map((t, i) => (
            <Reveal key={t.mode} index={i} className="h-full">
              <figure className="relative aspect-[4/3] overflow-hidden rounded-2xl bg-[#0c0c0c]">
                <EffectCanvas mode={t.mode} cell={t.cell} className="absolute inset-0 h-full w-full object-cover" />
                <div className="pointer-events-none absolute inset-0 bg-gradient-to-t from-black/70 via-transparent to-black/20" />
                <span className="absolute right-3 top-3 rounded-full bg-black/60 px-2 py-0.5 text-[10px] tracking-wide text-primary/80 backdrop-blur-sm">
                  live · 60fps
                </span>
                <figcaption className="absolute bottom-0 left-0 right-0 p-4">
                  <span className="block text-base font-bold sm:text-lg" style={{ color: CREAM }}>
                    {t.name}
                  </span>
                  <span className="block text-[10px] text-gray-400 sm:text-xs">{t.sub}</span>
                </figcaption>
              </figure>
            </Reveal>
          ))}
        </div>
      </div>
    </section>
  );
}
