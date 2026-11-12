# Engine: cells (LED panels, pixels, glyph cells)

Placeholder. The `cells` engine ships with DotStudio once custom scenes arrive; its `guide.md` replaces this page when installed.

Same signature as `metal` (`float4 dsScene(float2 uv, DSContext ctx)`), but the result is colour + coverage per cell: the engine draws it as LED dots, square pixels or glyphs (the CellKit look of LED Wall and Penguin), and adds the params Render, Cell Size and Glow automatically.

Good for: a small character on an LED panel, pixel-art weather, a dot-matrix sky. Keep the subject simple and readable at the default cell size; animate slowly (24 fps or stepped time reads as "LED"); leave most cells dark.
