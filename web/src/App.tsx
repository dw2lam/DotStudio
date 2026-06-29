import { Hero } from "./sections/Hero";
import { Collection } from "./sections/Collection";
import { LiveStrip } from "./sections/LiveStrip";
import { Catalog } from "./sections/Catalog";
import { Steps } from "./sections/Steps";
import { Download } from "./sections/Download";

export default function App() {
  return (
    <div className="min-h-screen bg-black">
      <Hero />
      <Collection />
      <LiveStrip />
      <Catalog />
      <Steps />
      <Download />

      <footer className="border-t border-white/5 bg-black px-6 py-10">
        <div className="mx-auto flex max-w-7xl flex-col items-center justify-between gap-4 text-xs text-gray-500 sm:flex-row">
          <div className="flex items-center gap-2.5">
            <img src="/icon.png" alt="" className="h-6 w-6 rounded" />
            <span>
              <span className="text-primary">DotStudio</span> — any art → a living Mac screensaver.
            </span>
          </div>
          <div className="flex items-center gap-5">
            <a className="transition-colors hover:text-primary" href="https://github.com/dw2lam/dotstudio" target="_blank" rel="noopener noreferrer">
              GitHub
            </a>
            <a className="transition-colors hover:text-primary" href="https://github.com/dw2lam/dotstudio/releases" target="_blank" rel="noopener noreferrer">
              Releases
            </a>
            <span>© 2026 David Lam</span>
          </div>
        </div>
      </footer>
    </div>
  );
}
