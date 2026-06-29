import { ArrowRight } from "lucide-react";
import { Reveal } from "../components/Reveal";

const CREAM = "#E1E0CC";
const LATEST = "https://github.com/dw2lam/dotstudio/releases/latest";

export function Download() {
  return (
    <section id="download" className="relative bg-black px-4 py-20 sm:py-28 md:py-32">
      <Reveal className="mx-auto max-w-3xl">
        <div className="relative overflow-hidden rounded-[2rem] bg-[#101010] px-6 py-16 text-center sm:px-12 sm:py-20">
          <div className="bg-noise pointer-events-none absolute inset-0 opacity-[0.1]" aria-hidden="true" />
          <div className="relative">
            <img src="/icon.png" alt="DotStudio icon" className="mx-auto h-16 w-16 rounded-2xl sm:h-20 sm:w-20" />
            <h2 className="mt-7 text-3xl font-medium tracking-tight sm:text-4xl md:text-5xl" style={{ color: CREAM }}>
              Get DotStudio
            </h2>
            <p className="mx-auto mt-4 max-w-md text-xs text-gray-400 sm:text-sm md:text-base">
              Download the latest build, drop it in Applications, and start making custom Mac
              screensavers from anything — a gradient, a photo, a clip.
            </p>

            <a
              href={LATEST}
              target="_blank"
              rel="noopener noreferrer"
              className="group mx-auto mt-8 inline-flex w-fit items-center gap-2 rounded-full bg-primary py-1.5 pl-6 pr-1.5 font-medium text-black transition-all duration-300 hover:gap-3 sm:text-base"
            >
              Download for macOS
              <span className="flex h-9 w-9 items-center justify-center rounded-full bg-black transition-transform duration-300 group-hover:scale-110 sm:h-10 sm:w-10">
                <ArrowRight className="h-4 w-4" style={{ color: CREAM }} />
              </span>
            </a>

            <div className="mt-6 flex items-center justify-center gap-3 text-xs text-gray-500">
              <span>Latest release · macOS 14+</span>
              <span aria-hidden="true">·</span>
              <a
                href="https://github.com/dw2lam/dotstudio/releases"
                target="_blank"
                rel="noopener noreferrer"
                className="transition-colors hover:text-primary"
              >
                All releases
              </a>
            </div>
            <p className="mx-auto mt-6 max-w-sm text-[11px] leading-relaxed text-gray-600">
              Unsigned for now: if macOS blocks the first launch, right-click{" "}
              <b className="text-gray-400">DotStudio.app → Open</b>.
            </p>
          </div>
        </div>
      </Reveal>
    </section>
  );
}
