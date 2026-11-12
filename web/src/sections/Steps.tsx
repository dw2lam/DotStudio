import { Reveal } from "../components/Reveal";
import { SectionHeader } from "../components/SectionHeader";

const CREAM = "#E1E0CC";

const STEPS = [
  {
    n: "01",
    title: "Drag it in",
    body: (
      <>
        Download the DMG and drag <b className="font-normal text-gray-200">DotStudio</b> into
        Applications.
      </>
    ),
  },
  {
    n: "02",
    title: "Open it once",
    body: (
      <>
        It isn't notarized yet, so macOS stops the first launch: click{" "}
        <b className="font-normal text-gray-200">Done</b>, then in{" "}
        <b className="font-normal text-gray-200">System Settings → Privacy &amp; Security</b> click{" "}
        <b className="font-normal text-gray-200">Open Anyway</b>, then confirm with{" "}
        <b className="font-normal text-gray-200">Open</b>.
      </>
    ),
  },
  {
    n: "03",
    title: "Follow the welcome guide",
    body: (
      <>
        It installs the screensaver for you, then shows you where to choose it in{" "}
        <b className="font-normal text-gray-200">Wallpaper → Screen Saver</b>. After that, you switch
        styles inside the app.
      </>
    ),
  },
];

export function Steps() {
  return (
    <section id="install" className="relative bg-black px-4 py-20 sm:py-28 md:py-32">
      <div className="mx-auto max-w-7xl">
        <SectionHeader eyebrow="Install" title="Three steps," aside="once." />

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

        <Reveal y={10} scaleFrom={1} className="mt-8 sm:mt-10">
          <div className="grid grid-cols-1 gap-x-8 gap-y-4 border-t border-white/10 pt-6 text-xs text-gray-500 sm:grid-cols-2 sm:text-sm">
            <p>
              <span className="text-gray-300">Updates itself.</span> New versions arrive from GitHub
              Releases; the app checks and installs them for you.
            </p>
            <p>
              <span className="text-gray-300">Your library stays yours.</span> Styles are saved on
              your Mac in{" "}
              <span className="text-gray-400">~/Library/Application Support/DotStudio</span>.
            </p>
          </div>
        </Reveal>
      </div>
    </section>
  );
}
