/** @type {import('tailwindcss').Config} */
export default {
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        // warm cream — primary text + accents
        primary: "#DEDBC8",
      },
      fontFamily: {
        sans: ['"Almarai"', "-apple-system", "BlinkMacSystemFont", "Segoe UI", "Roboto", "sans-serif"],
        serif: ['"Instrument Serif"', "serif"],
      },
    },
  },
  plugins: [],
};
