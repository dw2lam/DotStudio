import { useEffect, useRef } from "react";

export type EffectMode = "ascii" | "matrix" | "halftone";

type EffectCanvasProps = {
  mode?: EffectMode;
  /** Grid cell size in CSS pixels. Smaller = denser. */
  cell?: number;
  className?: string;
};

const CREAM = "222, 219, 200"; // #DEDBC8 as rgb triplet
const ASCII_RAMP = " .,:;i1tfLCG08@";

/**
 * A tiny, dependency-free re-creation of three of DotStudio's signature looks,
 * running live on a <canvas>. It transforms a drifting plasma field into ASCII
 * glyphs, Matrix rain, or a halftone dot grid — cream on black to match the
 * cinematic skin. Honors `prefers-reduced-motion` by painting a single frame.
 */
export function EffectCanvas({ mode = "ascii", cell = 14, className = "" }: EffectCanvasProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d", { alpha: false });
    if (!ctx) return;

    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    let raf = 0;
    let cssW = 0;
    let cssH = 0;
    let cols = 0;
    let rows = 0;
    let drops: number[] = []; // matrix: per-column head row (fractional)

    const dpr = Math.min(window.devicePixelRatio || 1, 2);

    // Layered-sine plasma in [0,1]. `t` is seconds.
    const field = (x: number, y: number, t: number) => {
      const v =
        Math.sin(x * 0.18 + t * 0.7) +
        Math.sin(y * 0.22 - t * 0.5) +
        Math.sin((x + y) * 0.12 + t * 0.9) +
        Math.sin(Math.hypot(x - cols * 0.5, y - rows * 0.5) * 0.16 - t);
      return (v + 4) / 8; // → 0..1
    };

    const resize = () => {
      const rect = canvas.getBoundingClientRect();
      cssW = Math.max(1, rect.width);
      cssH = Math.max(1, rect.height);
      canvas.width = Math.round(cssW * dpr);
      canvas.height = Math.round(cssH * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      cols = Math.max(1, Math.ceil(cssW / cell));
      rows = Math.max(1, Math.ceil(cssH / cell));
      drops = Array.from({ length: cols }, (_, i) => -Math.floor((i * 7.3) % rows) - 1);
      ctx.textBaseline = "top";
      ctx.font = `${cell}px "JetBrains Mono", ui-monospace, monospace`;
    };

    const drawAscii = (t: number) => {
      ctx.fillStyle = "#000";
      ctx.fillRect(0, 0, cssW, cssH);
      for (let y = 0; y < rows; y++) {
        for (let x = 0; x < cols; x++) {
          const lum = field(x, y, t);
          const ch = ASCII_RAMP[Math.min(ASCII_RAMP.length - 1, Math.floor(lum * ASCII_RAMP.length))];
          if (ch === " ") continue;
          ctx.fillStyle = `rgba(${CREAM}, ${0.12 + lum * 0.78})`;
          ctx.fillText(ch, x * cell, y * cell);
        }
      }
    };

    const drawHalftone = (t: number) => {
      ctx.fillStyle = "#000";
      ctx.fillRect(0, 0, cssW, cssH);
      const r = cell * 0.5;
      for (let y = 0; y < rows; y++) {
        for (let x = 0; x < cols; x++) {
          const lum = field(x, y, t);
          const radius = lum * r * 0.95;
          if (radius < 0.4) continue;
          ctx.beginPath();
          ctx.arc(x * cell + r, y * cell + r, radius, 0, Math.PI * 2);
          ctx.fillStyle = `rgba(${CREAM}, ${0.25 + lum * 0.6})`;
          ctx.fill();
        }
      }
    };

    const drawMatrix = (t: number) => {
      // Translucent black for the fading trail.
      ctx.fillStyle = "rgba(0, 0, 0, 0.16)";
      ctx.fillRect(0, 0, cssW, cssH);
      for (let x = 0; x < cols; x++) {
        const headRow = drops[x];
        const speed = 0.25 + ((x * 13) % 7) * 0.06;
        // Tail
        for (let k = 0; k < 10; k++) {
          const row = Math.floor(headRow) - k;
          if (row < 0 || row >= rows) continue;
          const lum = field(x, row, t);
          const code = 0x30a0 + ((((x * 31 + row * 17) >> 1) ^ Math.floor(t * 2 + row)) & 0x5f);
          const ch = String.fromCharCode(code);
          const fade = k === 0 ? 1 : Math.max(0, 1 - k / 10) * (0.4 + lum * 0.5);
          ctx.fillStyle =
            k === 0 ? `rgba(245, 243, 230, 0.95)` : `rgba(${CREAM}, ${fade * 0.7})`;
          ctx.fillText(ch, x * cell, row * cell);
        }
        drops[x] += speed;
        if (Math.floor(headRow) > rows + 6) drops[x] = -Math.floor((x * 5) % rows) - 1;
      }
    };

    const render = (ms: number) => {
      const t = ms / 1000;
      if (mode === "matrix") drawMatrix(t);
      else if (mode === "halftone") drawHalftone(t);
      else drawAscii(t);
      raf = requestAnimationFrame(render);
    };

    resize();
    const ro = new ResizeObserver(resize);
    ro.observe(canvas);

    if (reduce) {
      // One representative frame, no animation loop.
      if (mode === "matrix") {
        ctx.fillStyle = "#000";
        ctx.fillRect(0, 0, cssW, cssH);
        drawMatrix(2);
      } else {
        render(1200);
        cancelAnimationFrame(raf);
      }
    } else {
      raf = requestAnimationFrame(render);
    }

    return () => {
      cancelAnimationFrame(raf);
      ro.disconnect();
    };
  }, [mode, cell]);

  return <canvas ref={canvasRef} className={className} aria-hidden="true" />;
}
