import { Reveal } from "../components/Reveal";
import { WordsPullUpMultiStyle } from "../components/animations/WordsPullUpMultiStyle";

const CREAM = "#E1E0CC";

const STEPS = [
  {
    n: "01",
    title: "Feed it a source",
    body: "Start from a built-in gradient, drop in any image, or point it at a video. The source is shared by every style, so one picture can wear a dozen looks.",
  },
  {
    n: "02",
    title: "Stack & tune effects",
    body: "Add effects to a stack — they apply top to bottom. Dither into halftone into scanlines. Drag the dials, swap the palette, watch it move.",
  },
  {
    n: "03",
    title: "Install it",
    body: "One click copies a real .saver into your Screen Savers folder and opens Wallpaper settings. Pick “DotStudio” once — after that you switch screensavers inside the app.",
  },
];

export function Steps() {
  return (
    <section id="how" className="relative bg-black px-4 py-20 sm:py-28 md:py-32">
      <div className="mx-auto max-w-7xl">
        <header className="mb-10 sm:mb-14">
          <span className="text-[10px] uppercase tracking-[0.25em] text-primary sm:text-xs">
            From canvas to lock screen
          </span>
          <div className="mt-4">
            <WordsPullUpMultiStyle
              className="text-2xl font-normal sm:text-3xl md:text-4xl lg:text-5xl"
              segments={[{ text: "Three steps to a living desktop.", className: "" }]}
            />
          </div>
        </header>

        <div className="grid grid-cols-1 gap-3 md:grid-cols-3">
          {STEPS.map((s, i) => (
            <Reveal key={s.n} index={i} className="h-full">
              <article className="flex h-full flex-col rounded-2xl bg-[#212121] p-6 sm:p-8">
                <span className="font-serif text-4xl italic text-primary/40 sm:text-5xl">{s.n}</span>
                <h3 className="mt-5 text-lg font-bold sm:text-xl" style={{ color: CREAM }}>
                  {s.title}
                </h3>
                <p className="mt-3 text-xs leading-relaxed text-gray-400 sm:text-sm">{s.body}</p>
              </article>
            </Reveal>
          ))}
        </div>
      </div>
    </section>
  );
}
