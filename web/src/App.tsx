import { Hero } from "./sections/Hero";
import { MCPDemo } from "./sections/MCPDemo";
import { Showcase } from "./sections/Showcase";
import { LiveSky } from "./sections/LiveSky";
import { NowPlaying } from "./sections/NowPlaying";
import { Studio } from "./sections/Studio";
import { Looks } from "./sections/Looks";
import { Steps } from "./sections/Steps";
import { Questions } from "./sections/Questions";
import { Download } from "./sections/Download";

export default function App() {
  return (
    <div className="min-h-screen bg-black">
      <Hero />
      <MCPDemo />
      <Showcase />
      <LiveSky />
      <NowPlaying />
      <Studio />
      <Looks />
      <Steps />
      <Questions />
      <Download />

      <footer className="border-t border-white/5 bg-black px-6 py-10">
        <div className="mx-auto flex max-w-7xl flex-col items-center justify-between gap-4 text-xs text-gray-500 sm:flex-row">
          <div className="flex items-center gap-2.5">
            <img src="/icon.png" alt="" className="h-6 w-6 rounded" />
            <span>
              <span className="text-primary">DotStudio</span> — living screensavers for your Mac.
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
