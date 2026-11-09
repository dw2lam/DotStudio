import { useEffect, useRef, useState } from "react";

type CycleStillsProps = {
  frames: { src: string; alt: string }[];
  /** Seconds each still holds before cross-fading to the next. */
  hold?: number;
  className?: string;
};

/**
 * A few renders of one scene, cross-fading in turn (e.g. one sky at different hours).
 * Only the first still loads up front; the rest load and start cycling once the tile is
 * near the viewport, and it pauses off-screen. Under prefers-reduced-motion the first
 * still simply stays up.
 */
export function CycleStills({ frames, hold = 3.2, className = "" }: CycleStillsProps) {
  const ref = useRef<HTMLDivElement>(null);
  const [active, setActive] = useState(0);
  const [visible, setVisible] = useState(false);
  const [armed, setArmed] = useState(false);

  useEffect(() => {
    const el = ref.current;
    if (!el || !("IntersectionObserver" in window)) return;
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const io = new IntersectionObserver(
      ([entry]) => {
        setVisible(entry.isIntersecting);
        if (entry.isIntersecting) setArmed(true);
      },
      { rootMargin: "200px 0px" }
    );
    io.observe(el);
    return () => io.disconnect();
  }, []);

  useEffect(() => {
    if (!visible) return;
    const id = window.setInterval(() => setActive((i) => (i + 1) % frames.length), hold * 1000);
    return () => window.clearInterval(id);
  }, [visible, hold, frames.length]);

  return (
    <div ref={ref} className={className}>
      {frames.map((f, i) =>
        i === 0 || armed ? (
          <img
            key={f.src}
            src={f.src}
            alt={i === active ? f.alt : ""}
            aria-hidden={i === active ? undefined : true}
            loading="lazy"
            decoding="async"
            width={1280}
            height={800}
            className={`absolute inset-0 h-full w-full object-cover transition-opacity duration-[1400ms] ease-in-out ${
              i === active ? "opacity-100" : "opacity-0"
            }`}
          />
        ) : null
      )}
    </div>
  );
}
