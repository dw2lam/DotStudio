import { useRef, type ReactNode } from "react";
import { motion, useInView } from "framer-motion";

const EASE = [0.22, 1, 0.36, 1] as const;

type RevealProps = {
  children: ReactNode;
  className?: string;
  /** Stagger index — delay = index * 0.12s. */
  index?: number;
  /** Initial vertical offset, in px. */
  y?: number;
  /** Initial scale. */
  scaleFrom?: number;
};

/** Scale/fade-in-on-scroll wrapper (the Features-card entrance, reused everywhere). */
export function Reveal({ children, className = "", index = 0, y = 0, scaleFrom = 0.95 }: RevealProps) {
  const ref = useRef<HTMLDivElement>(null);
  const inView = useInView(ref, { once: true, margin: "-80px" });
  return (
    <motion.div
      ref={ref}
      initial={{ opacity: 0, scale: scaleFrom, y }}
      animate={inView ? { opacity: 1, scale: 1, y: 0 } : {}}
      transition={{ duration: 0.7, delay: index * 0.12, ease: EASE }}
      className={className}
    >
      {children}
    </motion.div>
  );
}
