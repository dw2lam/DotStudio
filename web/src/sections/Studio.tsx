import { Reveal } from "../components/Reveal";
import { SectionHeader } from "../components/SectionHeader";

const CREAM = "#E1E0CC";

const MODES = [
  { name: "Playlist", body: "One style, or a rotation of the ones you pick." },
  { name: "Night", body: "Another look after sunset, at your real sunset." },
  { name: "Wallpaper", body: "Press SYNC and your desktop plays the screensaver's scene, in step." },
];

const DETAILS = [
  { name: "120 fps", body: "Full ProMotion smoothness, when you want it." },
  { name: "In the menu bar", body: "Music, wallpaper and styles without opening a window." },
  { name: "Instant start", body: "The screensaver is up the moment your Mac goes idle." },
];

/** An app render (offscreen, no window chrome), framed as a dark macOS window. */
function Shot({ src, alt, width, height }: { src: string; alt: string; width: number; height: number }) {
  return (
    <div className="overflow-hidden rounded-xl bg-[#1c1c1c] shadow-[0_30px_80px_-20px_rgba(0,0,0,0.9)] ring-1 ring-white/10 sm:rounded-2xl">
      <img src={src} alt={alt} width={width} height={height} loading="lazy" decoding="async" className="block h-auto w-full" />
    </div>
  );
}

export function Studio() {
  return (
    <section id="studio" className="relative overflow-hidden bg-black px-4 py-20 sm:py-28 md:py-32">
      <div className="bg-noise pointer-events-none absolute inset-0 opacity-[0.12]" aria-hidden="true" />

      <div className="relative mx-auto max-w-7xl">
        <SectionHeader eyebrow="App" title="A gallery to play from." aside="An editor to make it yours." />

        {/* The gallery, screensaver and wallpaper synced */}
        <Reveal className="mb-8 sm:mb-12">
          <figure className="relative mx-auto max-w-6xl">
            <div
              aria-hidden="true"
              className="pointer-events-none absolute inset-x-0 -top-16 bottom-0 -z-10 bg-[radial-gradient(60%_55%_at_50%_40%,rgba(222,219,200,0.10),transparent_70%)]"
            />
            <Shot
              src="/media/app/gallery.webp"
              alt="The DotStudio gallery: Screensaver and Wallpaper cards joined by the SYNC key above a grid of scenes"
              width={2400}
              height={1500}
            />
          </figure>
        </Reveal>

        <div className="mx-auto mb-10 grid max-w-5xl grid-cols-1 gap-6 sm:grid-cols-3 sm:gap-8">
          {MODES.map((m, i) => (
            <Reveal key={m.name} index={i} y={12} scaleFrom={1}>
              <div className="border-t border-white/10 pt-4">
                <h3 className="text-sm font-bold sm:text-base" style={{ color: CREAM }}>
                  {m.name}
                </h3>
                <p className="mt-1 text-xs text-gray-400 sm:text-sm">{m.body}</p>
              </div>
            </Reveal>
          ))}
        </div>

        <Reveal y={10} scaleFrom={1} className="mx-auto mb-20 max-w-5xl sm:mb-28">
          <ul className="grid grid-cols-2 gap-x-6 gap-y-4 rounded-2xl bg-white/[0.03] p-5 text-xs sm:p-6 md:grid-cols-3 sm:text-[13px]">
            {DETAILS.map((d) => (
              <li key={d.name}>
                <span className="block text-gray-200">{d.name}</span>
                <span className="mt-1 block leading-snug text-gray-500">{d.body}</span>
              </li>
            ))}
          </ul>
        </Reveal>

        {/* Make your own */}
        <div className="grid grid-cols-1 items-center gap-10 lg:grid-cols-12 lg:gap-12">
          <div className="lg:col-span-4">
            <h3 className="text-2xl font-normal leading-tight sm:text-3xl" style={{ color: CREAM }}>
              Double-click any tile.{" "}
              <span className="font-serif italic text-primary/70">Then make it yours.</span>
            </h3>
            <p className="mt-5 max-w-md text-xs leading-relaxed text-gray-400 sm:text-sm">
              A big live preview beside every dial: angle, speed, colour, frame rate. Stack
              effects on top of a scene, or start from nothing in the welcome guide's{" "}
              <span className="text-primary/80">Create Your Own</span>. Everything stays on your Mac.
            </p>
          </div>
          <Reveal className="lg:col-span-8">
            <Shot
              src="/media/app/editor.webp"
              alt="The DotStudio editor: a live Black Hole preview beside its scene and Bloom layers"
              width={2000}
              height={1028}
            />
          </Reveal>
        </div>
      </div>
    </section>
  );
}
