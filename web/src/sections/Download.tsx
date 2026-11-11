import { useEffect, useState } from "react";
import { ArrowRight } from "lucide-react";
import { Reveal } from "../components/Reveal";

const CREAM = "#E1E0CC";
const LATEST = "https://github.com/dw2lam/DotStudio/releases/latest/download/DotStudio.dmg";
const API = "https://api.github.com/repos/dw2lam/DotStudio/releases/latest";

/** The latest release's version ("1.4.4") and its page, fetched once when the card mounts.
 *  Cached for the session; if GitHub can't be reached the line just leaves the version out. */
function useLatestRelease() {
  const [release, setRelease] = useState<{ version: string; url: string } | null>(() => {
    try {
      const v = sessionStorage.getItem("dotstudio.latest");
      return v ? JSON.parse(v) : null;
    } catch {
      return null;
    }
  });
  useEffect(() => {
    if (release) return;
    const ctl = new AbortController();
    fetch(API, { signal: ctl.signal, headers: { Accept: "application/vnd.github+json" } })
      .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
      .then((j: { tag_name?: string; html_url?: string }) => {
        const version = (j.tag_name ?? "").replace(/^v/, "");
        if (!/^\d+(\.\d+)*$/.test(version)) return;
        const next = { version, url: j.html_url ?? "https://github.com/dw2lam/DotStudio/releases/latest" };
        setRelease(next);
        try {
          sessionStorage.setItem("dotstudio.latest", JSON.stringify(next));
        } catch {
          /* private mode: fine, it just fetches again next time */
        }
      })
      .catch(() => {});
    return () => ctl.abort();
  }, [release]);
  return release;
}

export function Download() {
  const release = useLatestRelease();
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
              Thirty-one styles to start, a live editor to make more, and updates that
              arrive on their own. Native, local, free.
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

            <div className="mt-6 flex flex-wrap items-center justify-center gap-x-3 gap-y-1 text-xs text-gray-500">
              {release && (
                <>
                  <a
                    href={release.url}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="text-gray-300 transition-colors hover:text-primary"
                  >
                    Version {release.version}
                  </a>
                  <span aria-hidden="true">·</span>
                </>
              )}
              <span>macOS 14 or later</span>
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
          </div>
        </div>
      </Reveal>
    </section>
  );
}
