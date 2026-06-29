import { Reveal } from "../components/Reveal";
import { WordsPullUpMultiStyle } from "../components/animations/WordsPullUpMultiStyle";
import { AnimatedParagraph } from "../components/animations/AnimatedParagraph";

const CREAM = "#E1E0CC";

type Print = { name: string; sub: string; file: string };

const PRINTS: Print[] = [
  { name: "Black Hole", sub: "lensing · accretion disk", file: "Black-Hole.png" },
  { name: "Universe", sub: "live earth · planets · your location", file: "Universe.png" },
  { name: "Starfield", sub: "warp · flying through stars", file: "Starfield.png" },
  { name: "NES 8-Bit", sub: "64-colour palette · scanlines", file: "Super-NES.png" },
  { name: "Green Phosphor", sub: "dither · mono · scanlines", file: "Green-Phosphor.png" },
  { name: "Matrix Rain", sub: "matrix · reveal source", file: "Matrix-Rain.png" },
  { name: "Thermal Cam", sub: "noise field · thermal", file: "Thermal-Cam.png" },
  { name: "Neon Wire", sub: "noise field · neon edges", file: "Neon-Wire.png" },
  { name: "Kaleidoscope", sub: "noise field · 8 segments", file: "Kaleidoscope.png" },
  { name: "Data Glitch", sub: "glitch · chroma · scanlines", file: "Data-Glitch.png" },
  { name: "ASCII", sub: "cell 12 · source color", file: "ASCII.png" },
  { name: "Halftone", sub: "cell 9 · screen angle", file: "Halftone.png" },
  { name: "VHS", sub: "tracking · scanlines", file: "VHS.png" },
  { name: "Game Boy", sub: "4-tone · ordered dither", file: "Game-Boy.png" },
  { name: "Hex Grid", sub: "hex mosaic · posterize", file: "Hex-Grid.png" },
  { name: "Voronoi", sub: "density 30 · posterize", file: "Voronoi.png" },
];

export function Collection() {
  return (
    <section id="collection" className="relative overflow-hidden bg-black px-4 py-20 sm:py-28 md:py-32">
      <div className="mx-auto max-w-7xl">
        <header className="mb-8 sm:mb-12">
          <span className="text-[10px] uppercase tracking-[0.25em] text-primary sm:text-xs">
            The print room
          </span>
          <div className="mt-4">
            <WordsPullUpMultiStyle
              className="text-2xl font-normal sm:text-3xl md:text-4xl lg:text-5xl"
              segments={[
                { text: "Prints from the app.", className: "" },
                { text: "Every frame is a real export.", className: "text-gray-500" },
              ]}
            />
          </div>
          <AnimatedParagraph
            className="mt-6 max-w-2xl text-xs leading-relaxed sm:text-sm md:text-base"
            style={{ color: "#DEDBC8" }}
            text="This is the whole app: pick a source, stack effects, tune the dials. Every tile further down is a screensaver it ships with — drop in your own gradient, image or clip and the same look paints over it, live at sixty frames a second."
          />
        </header>

        {/* The app itself — a real screenshot on macOS */}
        <Reveal className="mb-14 sm:mb-20">
          <figure className="relative mx-auto max-w-6xl">
            <div
              aria-hidden="true"
              className="pointer-events-none absolute inset-x-0 -top-16 bottom-0 -z-10 bg-[radial-gradient(65%_55%_at_50%_35%,rgba(222,219,200,0.10),transparent_70%)]"
            />
            <picture>
              <source srcSet="/app-preview.webp" type="image/webp" />
              <img
                src="/app-preview.png"
                alt="DotStudio running on macOS — source picker, effect stack with NES 8-Bit dials, and a live preview"
                loading="lazy"
                className="w-full rounded-xl shadow-[0_30px_120px_-30px_rgba(0,0,0,0.9)]"
              />
            </picture>
            <figcaption className="mt-5 text-center text-xs text-gray-500 sm:text-sm">
              The studio itself — source, effect stack, dials. Tune it live, then{" "}
              <span className="text-primary/80">Use as Screensaver</span>.
            </figcaption>
          </figure>
        </Reveal>

        <div className="grid grid-cols-2 gap-2 sm:grid-cols-3 sm:gap-3 lg:grid-cols-4">
          {PRINTS.map((p, i) => (
            <Reveal key={p.file} index={i % 4} className="h-full">
              <figure className="group relative overflow-hidden rounded-xl bg-[#111]">
                <img
                  src={`/gallery/${p.file}`}
                  alt={`${p.name} preset`}
                  loading="lazy"
                  className="aspect-[4/3] w-full object-cover transition-transform duration-500 group-hover:scale-105"
                />
                <div className="pointer-events-none absolute inset-0 bg-gradient-to-t from-black/85 via-black/10 to-transparent" />
                <figcaption className="absolute bottom-0 left-0 right-0 p-3 sm:p-4">
                  <span className="block text-sm font-bold sm:text-base" style={{ color: CREAM }}>
                    {p.name}
                  </span>
                  <span className="block text-[10px] text-gray-400 sm:text-xs">{p.sub}</span>
                </figcaption>
              </figure>
            </Reveal>
          ))}
        </div>
      </div>
    </section>
  );
}
