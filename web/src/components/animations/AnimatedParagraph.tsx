import { useRef, type CSSProperties } from "react";
import { motion, useScroll, useTransform, type MotionValue } from "framer-motion";

type AnimatedParagraphProps = {
  text: string;
  className?: string;
  style?: CSSProperties;
};

function AnimatedLetter({
  char,
  progress,
  range,
}: {
  char: string;
  progress: MotionValue<number>;
  range: [number, number];
}) {
  const opacity = useTransform(progress, range, [0.2, 1]);
  return <motion.span style={{ opacity }}>{char}</motion.span>;
}

/**
 * Scroll-linked progressive reveal: each character fades from 0.2 → 1 opacity as
 * the paragraph travels through the viewport (offset `start 0.8` → `end 0.2`),
 * staggered so the text "develops" left-to-right like a print in a darkroom.
 */
export function AnimatedParagraph({ text, className = "", style }: AnimatedParagraphProps) {
  const ref = useRef<HTMLParagraphElement>(null);
  const { scrollYProgress } = useScroll({
    target: ref,
    offset: ["start 0.8", "end 0.2"],
  });

  const chars = text.split("");
  const total = chars.length;

  return (
    // `relative` so framer-motion's useScroll can measure offset correctly.
    <p ref={ref} className={`relative ${className}`} style={style}>
      {chars.map((char, i) => {
        if (char === " ") return <span key={i}> </span>;
        const charProgress = i / total;
        const start = Math.max(0, charProgress - 0.1);
        const end = Math.min(1, charProgress + 0.05);
        const range: [number, number] = start < end ? [start, end] : [start, Math.min(1, start + 0.001)];
        return <AnimatedLetter key={i} char={char} progress={scrollYProgress} range={range} />;
      })}
    </p>
  );
}
