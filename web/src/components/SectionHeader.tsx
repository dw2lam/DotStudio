import type { ReactNode } from "react";
import { WordsPullUpMultiStyle } from "./animations/WordsPullUpMultiStyle";

type SectionHeaderProps = {
  eyebrow: string;
  title: string;
  /** Second clause, set in gray after the title. */
  aside?: string;
  children?: ReactNode;
  className?: string;
};

/** The eyebrow + pulled-up two-tone headline every section below the hero opens with. */
export function SectionHeader({ eyebrow, title, aside, children, className = "mb-8 sm:mb-12" }: SectionHeaderProps) {
  return (
    <header className={className}>
      <span className="text-[10px] uppercase tracking-[0.25em] text-primary sm:text-xs">{eyebrow}</span>
      <div className="mt-4">
        <WordsPullUpMultiStyle
          className="!justify-start text-2xl font-normal sm:text-3xl md:text-4xl lg:text-5xl"
          segments={[
            { text: title, className: "" },
            ...(aside ? [{ text: aside, className: "text-gray-500" }] : []),
          ]}
        />
      </div>
      {children}
    </header>
  );
}
