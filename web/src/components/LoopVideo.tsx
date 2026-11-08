import { useEffect, useRef } from "react";

type LoopVideoProps = {
  /** Base name under /media/loops — expects `<name>.webm`, `<name>.mp4` and a `<name>.webp` poster. */
  name: string;
  alt: string;
  className?: string;
};

/**
 * A short, silent, seamless render loop from the app. Nothing is fetched until the
 * clip nears the viewport; it only plays while visible, and never under
 * prefers-reduced-motion (the poster frame stays up instead).
 */
export function LoopVideo({ name, alt, className = "" }: LoopVideoProps) {
  const ref = useRef<HTMLVideoElement>(null);

  useEffect(() => {
    const v = ref.current;
    if (!v) return;
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (reduced || !("IntersectionObserver" in window)) return;
    const io = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          if (v.preload !== "auto") v.preload = "auto";
          v.play().catch(() => {});
        } else {
          v.pause();
        }
      },
      { rootMargin: "200px 0px" }
    );
    io.observe(v);
    return () => io.disconnect();
  }, []);

  return (
    <video
      ref={ref}
      className={className}
      poster={`/media/loops/${name}.webp`}
      muted
      loop
      playsInline
      preload="none"
      aria-label={alt}
      disablePictureInPicture
    >
      <source src={`/media/loops/${name}.webm`} type={`video/webm; codecs="vp9"`} />
      <source src={`/media/loops/${name}.mp4`} type="video/mp4" />
    </video>
  );
}
