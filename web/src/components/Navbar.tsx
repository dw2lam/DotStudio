const LINK_COLOR = "rgba(225, 224, 204, 0.8)";
const LINK_HOVER = "#E1E0CC";

const ITEMS: { label: string; href: string; external?: boolean }[] = [
  { label: "Gallery", href: "#collection" },
  { label: "Live", href: "#live" },
  { label: "Effects", href: "#catalog" },
  { label: "Source", href: "https://github.com/dw2lam/dotstudio", external: true },
  { label: "Download", href: "#download" },
];

/** Black pill that hangs from the top edge of the hero. */
export function Navbar() {
  return (
    <nav className="absolute left-1/2 top-0 z-20 -translate-x-1/2">
      <ul className="flex items-center gap-3 rounded-b-2xl bg-black px-4 py-2 sm:gap-6 md:gap-12 md:rounded-b-3xl md:px-8 lg:gap-14">
        {ITEMS.map((item) => (
          <li key={item.label}>
            <a
              href={item.href}
              {...(item.external ? { target: "_blank", rel: "noopener noreferrer" } : {})}
              className="whitespace-nowrap text-[10px] tracking-wide transition-colors duration-200 sm:text-xs md:text-sm"
              style={{ color: LINK_COLOR }}
              onMouseEnter={(e) => (e.currentTarget.style.color = LINK_HOVER)}
              onMouseLeave={(e) => (e.currentTarget.style.color = LINK_COLOR)}
            >
              {item.label}
            </a>
          </li>
        ))}
      </ul>
    </nav>
  );
}
