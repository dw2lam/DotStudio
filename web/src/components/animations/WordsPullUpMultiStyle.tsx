import { useRef } from "react";
import { motion, useInView, type Variants } from "framer-motion";

export type StyledSegment = {
  /** A run of text that shares one className (e.g. an italic serif clause). */
  text: string;
  /** Tailwind/utility classes for every word in this segment. */
  className?: string;
};

type WordsPullUpMultiStyleProps = {
  /** Ordered segments; each is split into words that keep the segment's class. */
  segments: StyledSegment[];
  /** Class applied to the flex-wrap container. */
  className?: string;
  /** Per-word stagger, in seconds. */
  staggerDelay?: number;
  /** Delay before the first word starts, in seconds. */
  delayOffset?: number;
};

const EASE = [0.16, 1, 0.3, 1] as const;

/**
 * Like {@link WordsPullUp} but each word can carry its own styling. Segments are
 * flattened into individual words (className preserved) and pulled up in order,
 * wrapped in an `inline-flex flex-wrap justify-center` container.
 */
export function WordsPullUpMultiStyle({
  segments,
  className = "",
  staggerDelay = 0.08,
  delayOffset = 0,
}: WordsPullUpMultiStyleProps) {
  const ref = useRef<HTMLSpanElement>(null);
  const inView = useInView(ref, { once: true });

  const words = segments.flatMap((seg) =>
    seg.text
      .split(" ")
      .filter(Boolean)
      .map((word) => ({ word, className: seg.className ?? "" }))
  );

  const variants: Variants = {
    hidden: { y: 20, opacity: 0 },
    show: (i: number) => ({
      y: 0,
      opacity: 1,
      transition: { duration: 0.6, delay: delayOffset + i * staggerDelay, ease: EASE },
    }),
  };

  return (
    <span ref={ref} className={`inline-flex flex-wrap justify-center ${className}`}>
      {words.map(({ word, className: wc }, i) => (
        <motion.span
          key={`${word}-${i}`}
          className={`inline-block ${wc}`}
          style={{ marginRight: "0.25em" }}
          custom={i}
          variants={variants}
          initial="hidden"
          animate={inView ? "show" : "hidden"}
        >
          {word}
        </motion.span>
      ))}
    </span>
  );
}
