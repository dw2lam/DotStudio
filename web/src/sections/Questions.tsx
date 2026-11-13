import { useId, useState, type ReactNode } from "react";
import { AnimatePresence, motion, useReducedMotion } from "framer-motion";
import { Plus } from "lucide-react";
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
        DotStudio isn't notarized yet. Click <K>Done</K>, then <K>Open Anyway</K> in{" "}
        <K>System Settings › Privacy &amp; Security</K>. You only do this once.
      </>
    ),
  },
  {
    q: "How do I set the screensaver?",
    a: (
      <>
        In <K>System Settings › Wallpaper › Screen Saver</K>, choose <K>DotStudio</K> under Other. The
        welcome guide walks you through it.
      </>
    ),
  },
  {
    q: "How does the music work?",
    a: (
      <>
        It follows Spotify or Apple Music on your Mac, with no account or sign-in. macOS asks once to
        let DotStudio control them.
      </>
    ),
  },
  {
    q: "Why is my wallpaper still?",
    a: (
      <>
        Low Power Mode and a hot Mac hold a still frame, and it pauses behind windows. On battery it
        plays at 20 fps; change it in <K>Settings › Live Wallpaper</K>.
      </>
    ),
  },
  {
    q: "How does the MCP server work?",
    a: (
      <>
        DotStudio includes an MCP server, so any MCP app can design and set screensavers with you.
        Connect it in <K>Settings › AI</K>. Rendered film scenes need Blender 5.1 or later, which you
        install yourself.
      </>
    ),
  },
  {
    q: "How does it update?",
    a: <>New versions come from GitHub Releases, and the app checks for and installs them itself.</>,
  },
  {
    q: "What does DotStudio send anywhere?",
    a: (
      <>
        Your styles and what you play stay on your Mac. Missing album art is looked up in Spotify's or
        Apple's public catalog, and weather uses your location rounded to about 10 km.
      </>
    ),
  },
];

/** One question: a button that opens its answer with a soft height animation. */
function Row({ q, a, open, onToggle }: { q: string; a: ReactNode; open: boolean; onToggle: () => void }) {
  const id = useId();
  const reduce = useReducedMotion();
  return (
    <li className="border-t border-white/10 last:border-b">
      <h3>
        <button
          type="button"
          id={`${id}-q`}
          aria-expanded={open}
          aria-controls={`${id}-a`}
          onClick={onToggle}
          className="group flex w-full items-center justify-between gap-6 rounded-sm py-5 text-left outline-none focus-visible:ring-1 focus-visible:ring-primary/40 sm:py-6"
        >
          <span
            className={`text-[15px] transition-colors duration-200 sm:text-lg ${
              open ? "" : "text-gray-300 group-hover:text-primary"
            }`}
            style={open ? { color: CREAM } : undefined}
          >
            {q}
          </span>
          <Plus
            aria-hidden="true"
            className={`h-4 w-4 shrink-0 text-gray-500 transition-transform duration-300 group-hover:text-primary ${
              open ? "rotate-45 text-primary" : ""
            }`}
          />
        </button>
      </h3>
      <AnimatePresence initial={false}>
        {open && (
          <motion.div
            id={`${id}-a`}
            role="region"
            aria-labelledby={`${id}-q`}
            initial={{ height: 0, opacity: 0 }}
            animate={{ height: "auto", opacity: 1 }}
            exit={{ height: 0, opacity: 0 }}
            transition={reduce ? { duration: 0 } : { type: "spring", duration: 0.5, bounce: 0 }}
            className="overflow-hidden"
          >
            <p className="max-w-2xl pb-6 pr-10 text-sm leading-relaxed text-gray-400">{a}</p>
          </motion.div>
        )}
      </AnimatePresence>
    </li>
  );
}

export function Questions() {
  const [open, setOpen] = useState<number | null>(null);
  return (
    <section id="faq" className="relative bg-black px-4 py-16 sm:py-20">
      <div className="mx-auto grid max-w-7xl grid-cols-1 gap-x-12 lg:grid-cols-12">
        <SectionHeader eyebrow="FAQ" title="Questions." className="mb-8 lg:col-span-4 lg:mb-0" />
        <ul className="lg:col-span-8">
          {QUESTIONS.map((item, i) => (
            <Row key={item.q} q={item.q} a={item.a} open={open === i} onToggle={() => setOpen(open === i ? null : i)} />
          ))}
        </ul>
      </div>
    </section>
  );
}
