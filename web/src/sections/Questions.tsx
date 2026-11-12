import type { ReactNode } from "react";
import { Reveal } from "../components/Reveal";
import { SectionHeader } from "../components/SectionHeader";

const CREAM = "#E1E0CC";

/** A setting or a place in macOS, set a shade brighter than the answer around it. */
function K({ children }: { children: ReactNode }) {
  return <b className="font-normal text-gray-200">{children}</b>;
}

const QUESTIONS: { q: string; a: ReactNode }[] = [
  {
    q: "macOS says it can't verify the developer.",
    a: (
      <>
        DotStudio isn't notarized yet. Click <K>Done</K>, then in{" "}
        <K>System Settings → Privacy &amp; Security</K> click <K>Open Anyway</K>, then confirm with{" "}
        <K>Open</K>. You do this once;
        on macOS 15 and later, right-click → Open no longer skips it.
      </>
    ),
  },
  {
    q: "How do I choose the screensaver?",
    a: (
      <>
        <K>System Settings → Wallpaper → Screen Saver…</K>, then <K>DotStudio</K> under Other. The
        welcome guide shows each click. After that, you pick styles in the app.
      </>
    ),
  },
  {
    q: "Why does Guide Me ask for Accessibility?",
    a: (
      <>
        So it can see where the buttons are in System Settings and point at the next one as you
        click. It only reads System Settings, and only while the guide is open. Say no and the guide
        shows the same steps as pictures; change it any time in{" "}
        <K>Privacy &amp; Security → Accessibility</K>.
      </>
    ),
  },
  {
    q: "How does Spotify connect?",
    a: (
      <>
        Through the Spotify and Music apps on your Mac: no account, no sign-in. The first time a song
        plays, macOS asks to let DotStudio control the app, which turns on play, pause and skip.
        Change it in <K>Privacy &amp; Security → Automation</K>.
      </>
    ),
  },
  {
    q: "What does DotStudio send anywhere?",
    a: (
      <>
        Your styles and what you play stay on your Mac. A missing album cover is looked up in
        Spotify's or Apple's public catalog by the song's ID, or its artist and album. Weather uses
        your location rounded to about 10 km.
      </>
    ),
  },
  {
    q: "Why is my wallpaper still?",
    a: (
      <>
        Low Power Mode and a hot Mac hold a still frame, and it pauses while windows cover the
        desktop. On battery it plays at 20 fps; pick Full or Still in <K>Settings → Live Wallpaper</K>.
      </>
    ),
  },
  {
    q: "Does it need to stay open?",
    a: (
      <>
        In the menu bar, yes: the wallpaper and the music on your screensaver need DotStudio running.
        Closing its window keeps it there; <K>Open DotStudio at login</K> brings it back after a restart.
      </>
    ),
  },
];

export function Questions() {
  return (
    <section id="faq" className="relative bg-black px-4 pb-4 pt-4 sm:pb-8 sm:pt-8">
      <div className="mx-auto max-w-7xl">
        <SectionHeader eyebrow="FAQ" title="Questions." />

        <div className="grid grid-cols-1 gap-x-12 md:grid-cols-2">
          {QUESTIONS.map((item, i) => (
            <Reveal key={item.q} index={i % 2} y={10} scaleFrom={1}>
              <div className="border-t border-white/10 py-6 sm:py-7">
                <h3 className="text-base font-bold sm:text-lg" style={{ color: CREAM }}>
                  {item.q}
                </h3>
                <p className="mt-2 text-xs leading-relaxed text-gray-400 sm:text-sm">{item.a}</p>
              </div>
            </Reveal>
          ))}
        </div>
      </div>
    </section>
  );
}
