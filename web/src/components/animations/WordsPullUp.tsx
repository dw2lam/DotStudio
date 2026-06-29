import { useRef } from "react";
import { motion, useInView, type Variants } from "framer-motion";

type WordsPullUpProps = {
  /** The text to animate. Split on spaces; each word slides up independently. */
  text: string;
  /** Class applied to the wrapping element. */
  className?: string;
  /** Class applied to every animated word. */
  wordClassName?: string;
  /** Per-word stagger, in seconds. */
  staggerDelay?: number;
  /** Delay before the first word starts, in seconds. */
  delayOffset?: number;
  /**
   * When true, a superscript asterisk is appended after the final character of
   * the last word — the Prisma "Prisma*" flourish.
   */
  showAsterisk?: boolean;
};

const EASE = [0.16, 1, 0.3, 1] as const;

/**
 * Splits `text` by spaces and slides each word up from `y: 20` (with a fade)
 * on a staggered delay, once it scrolls into view.
 */
export function WordsPullUp({
  text,
  className = "",
  wordClassName = "",
  staggerDelay = 0.08,
  delayOffset = 0,
  showAsterisk = false,
}: WordsPullUpProps) {
  const words = text.split(" ");
  const ref = useRef<HTMLSpanElement>(null);
  const inView = useInView(ref, { once: true });

  const variants: Variants = {
    hidden: { y: 20, opacity: 0 },
    show: (i: number) => ({
      y: 0,
      opacity: 1,
      transition: { duration: 0.6, delay: delayOffset + i * staggerDelay, ease: EASE },
    }),
  };

  return (
    <span ref={ref} className={className}>
      {words.map((word, i) => {
        const isLast = i === words.length - 1;
        return (
          <span
            key={`${word}-${i}`}
            className="relative inline-block"
            style={{ marginRight: i < words.length - 1 ? "0.25em" : undefined }}
          >
            <motion.span
              className={`inline-block ${wordClassName}`}
              custom={i}
              variants={variants}
              initial="hidden"
              animate={inView ? "show" : "hidden"}
            >
              {word}
            </motion.span>
            {isLast && showAsterisk && (
              <span
                aria-hidden="true"
                className="absolute"
                style={{ top: "0.65em", right: "-0.3em", fontSize: "0.31em" }}
              >
                *
              </span>
            )}
          </span>
        );
      })}
    </span>
  );
}
