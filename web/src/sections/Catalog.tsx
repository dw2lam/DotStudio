import { Reveal } from "../components/Reveal";
import { WordsPullUpMultiStyle } from "../components/animations/WordsPullUpMultiStyle";

const CREAM = "#E1E0CC";

type Group = { title: string; effects: string[] };

const GROUPS: Group[] = [
  { title: "Dots & Dither", effects: ["Dithering", "Halftone", "Dots", "Pixelate", "Blockify", "Hex Mosaic", "LED Panel", "Truchet"] },
  { title: "Glyphs", effects: ["ASCII", "Matrix Rain"] },
  { title: "Generative", effects: ["Noise Field", "Voronoi", "Starfield", "Universe", "Black Hole"] },
  { title: "Lines & Edges", effects: ["Contour", "Edge Detection", "Crosshatch", "Wave Lines", "Neon Edges"] },
  { title: "Glitch", effects: ["VHS", "Scanlines", "Grain", "Pixel Sort", "Chromatic Shift", "Glitch Blocks"] },
  { title: "Color", effects: ["Threshold", "Posterize", "Phosphor", "Vignette", "Game Boy", "NES 8-Bit", "Bloom", "Thermal", "Toon"] },
  { title: "Warp & Mirror", effects: ["Kaleidoscope", "Mirror", "Fisheye", "Swirl", "Ripple"] },
];

export function Catalog() {
  return (
    <section id="catalog" className="relative bg-black px-4 py-20 sm:py-28 md:py-32">
      <div className="bg-noise pointer-events-none absolute inset-0 opacity-[0.12]" aria-hidden="true" />

      <div className="relative mx-auto max-w-7xl">
        <header className="mb-10 sm:mb-14">
          <span className="text-[10px] uppercase tracking-[0.25em] text-primary sm:text-xs">
            The full catalog
          </span>
          <div className="mt-4">
            <WordsPullUpMultiStyle
              className="text-2xl font-normal sm:text-3xl md:text-4xl lg:text-5xl"
              segments={[
                { text: "Forty ways to look.", className: "" },
                { text: "Stack as many as you like.", className: "text-gray-500" },
              ]}
            />
          </div>
        </header>

        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {GROUPS.map((g, i) => (
            <Reveal key={g.title} index={i % 3} className="h-full">
              <div className="flex h-full flex-col rounded-2xl bg-[#212121] p-5 sm:p-6">
                <div className="mb-4 flex items-baseline justify-between">
                  <h3 className="text-base font-bold sm:text-lg" style={{ color: CREAM }}>
                    {g.title}
                  </h3>
                  <span className="text-xs text-gray-500">{g.effects.length}</span>
                </div>
                <ul className="flex flex-wrap gap-2">
                  {g.effects.map((e) => (
                    <li
                      key={e}
                      className="rounded-full bg-white/[0.04] px-3 py-1 text-xs text-gray-300 ring-1 ring-white/5 sm:text-sm"
                    >
                      {e}
                    </li>
                  ))}
                </ul>
              </div>
            </Reveal>
          ))}
        </div>
      </div>
    </section>
  );
}
