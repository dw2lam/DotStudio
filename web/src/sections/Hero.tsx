import { motion } from "framer-motion";
import { ArrowRight } from "lucide-react";
import { Navbar } from "../components/Navbar";
import { EffectCanvas } from "../components/EffectCanvas";
import { WordsPullUp } from "../components/animations/WordsPullUp";

const CREAM = "#E1E0CC";
const EASE = [0.16, 1, 0.3, 1] as const;
const DOWNLOAD = "https://github.com/dw2lam/dotstudio/releases/latest";

export function Hero() {
  return (
    <section className="h-screen p-4 md:p-6">
      <div className="relative h-full w-full overflow-hidden rounded-2xl md:rounded-[2rem]">
        {/* Live effect backdrop — DotStudio's own ASCII look, in place of stock video. */}
        <EffectCanvas mode="ascii" cell={14} className="absolute inset-0 h-full w-full object-cover" />

        {/* Film-grain + cinematic vignette over the canvas. */}
        <div className="noise-overlay pointer-events-none absolute inset-0 opacity-[0.7] mix-blend-overlay" />
        {/* Uniform scrim to dim the busy ASCII backdrop a touch. */}
        <div className="pointer-events-none absolute inset-0 bg-black/35" />
        <div className="pointer-events-none absolute inset-0 bg-gradient-to-b from-black/30 via-transparent to-black/70" />

        <Navbar />

        {/* Bottom-aligned content */}
        <div className="absolute bottom-0 left-0 right-0 p-5 sm:p-7 md:p-10">
          <div className="grid grid-cols-1 items-end gap-6 md:grid-cols-12 md:gap-8">
            {/* Giant wordmark */}
            <div className="md:col-span-8">
              <h1
                className="font-medium leading-[0.85] tracking-[-0.07em] text-[16vw] sm:text-[15vw] md:text-[14vw] lg:text-[13vw] xl:text-[12vw]"
                style={{ color: CREAM, textShadow: "0 2px 32px rgba(0,0,0,0.55), 0 1px 4px rgba(0,0,0,0.45)" }}
              >
                <WordsPullUp text="DotStudio" />
              </h1>
            </div>

            {/* Right column: description + CTA */}
            <div className="flex flex-col gap-5 md:col-span-4 md:pb-3">
              <motion.p
                initial={{ y: 20, opacity: 0 }}
                animate={{ y: 0, opacity: 1 }}
                transition={{ duration: 0.8, delay: 0.5, ease: EASE }}
                className="max-w-md text-xs leading-[1.2] text-primary/70 sm:text-sm md:text-base [text-shadow:0_1px_14px_rgba(0,0,0,0.9)]"
              >
                Turn any gradient, image or video into a{" "}
                <span style={{ color: CREAM }}>custom Mac screensaver</span> — run it through dither,
                ASCII, halftone, VHS and 40+ live effects, then install it straight to your desktop.
                Native, local, free.
              </motion.p>

              <motion.a
                href={DOWNLOAD}
                target="_blank"
                rel="noopener noreferrer"
                initial={{ y: 20, opacity: 0 }}
                animate={{ y: 0, opacity: 1 }}
                transition={{ duration: 0.8, delay: 0.7, ease: EASE }}
                className="group inline-flex w-fit items-center gap-2 rounded-full bg-primary py-1.5 pl-5 pr-1.5 font-medium text-black shadow-lg shadow-black/30 transition-all duration-300 hover:gap-3 text-sm sm:text-base"
              >
                Get DotStudio
                <span className="flex h-9 w-9 items-center justify-center rounded-full bg-black transition-transform duration-300 group-hover:scale-110 sm:h-10 sm:w-10">
                  <ArrowRight className="h-4 w-4" style={{ color: CREAM }} />
                </span>
              </motion.a>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}
