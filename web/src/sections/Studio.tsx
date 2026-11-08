import { Reveal } from "../components/Reveal";
import { SectionHeader } from "../components/SectionHeader";

const CREAM = "#E1E0CC";

const MODES = [
  { name: "One Style", body: "One screensaver, always." },
  { name: "Rotate", body: "Shuffle through the styles you pick." },
  { name: "Day & Night", body: "One look by day, another after sunset." },
];

/** A native window capture (shadow included, transparent margin), shown at its natural ratio. */
function Grab({ src, alt, width, height, className = "" }: { src: string; alt: string; width: number; height: number; className?: string }) {
  return (
    <img
      src={src}
      alt={alt}
      width={width}
      height={height}
      loading="lazy"
      decoding="async"
      className={`h-auto w-full ${className}`}
    />
  );
}

export function Studio() {
  return (
    <section id="studio" className="relative overflow-hidden bg-black px-4 py-20 sm:py-28 md:py-32">
      <div className="bg-noise pointer-events-none absolute inset-0 opacity-[0.12]" aria-hidden="true" />

      <div className="relative mx-auto max-w-7xl">
        <SectionHeader eyebrow="The app" title="A gallery to play from." aside="An editor to make it yours." />

        {/* The library window */}
        <Reveal className="mb-6 sm:mb-10">
          <figure className="relative mx-auto max-w-6xl">
            <div
              aria-hidden="true"
              className="pointer-events-none absolute inset-x-0 -top-16 bottom-0 -z-10 bg-[radial-gradient(60%_55%_at_50%_40%,rgba(222,219,200,0.10),transparent_70%)]"
            />
            <Grab
              src="/media/app/library.webp"
              alt="The DotStudio library: a Playback bar (One Style, Rotate, Day & Night) above a grid of scene tiles"
              width={2400}
              height={1528}
            />
          </figure>
        </Reveal>

        <div className="mx-auto mb-20 grid max-w-5xl grid-cols-1 gap-6 sm:mb-28 sm:grid-cols-3 sm:gap-8">
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

        {/* Make your own */}
        <div className="grid grid-cols-1 items-center gap-10 lg:grid-cols-12 lg:gap-12">
          <div className="lg:col-span-4">
            <h3 className="text-2xl font-normal leading-tight sm:text-3xl" style={{ color: CREAM }}>
              Double-click any tile.{" "}
              <span className="font-serif italic text-primary/70">Then make it yours.</span>
            </h3>
            <p className="mt-5 max-w-md text-xs leading-relaxed text-gray-400 sm:text-sm">
              The editor puts a big live preview beside every dial: speed, size, gloss, colour.
              Stack effects on top of a scene, or start from nothing. The welcome guide even
              opens on <span className="text-primary/80">Create Your Own</span>, so your first
              screensaver can be one you built.
            </p>
          </div>
          <Reveal className="lg:col-span-8">
            <Grab
              src="/media/app/editor.webp"
              alt="The DotStudio editor: a live Lava Lamp preview beside its Speed, Blobs, Size, Gloss and colour controls"
              width={2400}
              height={1528}
            />
          </Reveal>
        </div>

        <div className="mt-10 grid grid-cols-1 items-center gap-10 lg:mt-4 lg:grid-cols-12 lg:gap-12">
          <Reveal className="lg:order-1 lg:col-span-8">
            <Grab
              src="/media/app/create.webp"
              alt="The welcome sheet's Create Your Own tab: pick an effect, name it, preview it on your canvas"
              width={2400}
              height={1528}
            />
          </Reveal>
          <div className="lg:order-2 lg:col-span-4">
            <p className="max-w-md text-xs leading-relaxed text-gray-400 sm:text-sm">
              <span className="block text-base font-bold sm:text-lg" style={{ color: CREAM }}>
                Presets, or your own.
              </span>
              <span className="mt-3 block">
                Choose an effect, name it, watch it on your canvas, and it joins your library.
                Everything is saved locally, ready to tweak later.
              </span>
            </p>
          </div>
        </div>
      </div>
    </section>
  );
}
