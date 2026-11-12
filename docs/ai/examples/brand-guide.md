# My brand colours, from a guide

> **You:** Use our brand guide and make a screensaver for the office Macs.

```
→ get_started({})
```
```text
DotStudio makes calm, living screensavers and live wallpapers for the Mac. A STYLE is a named stack of effects: a SCENE first (it draws its own image: ocean, meadow, clocks, liquid chrome, bloom…), then 0–2 LOOKS that restyle it (halftone, riso, glass, grain…). A stack of looks alone restyles the shared photo slideshow.

Workflow:
1. read_guide("style/dotstudio") — the house taste. Non-negotiable: calm, premium, dark-first, slow motion, no cheap/glossy looks.
2. Read the user's own guides if any …
```

```
→ read_guide({"id": "user/northwind-brand"})
```
```text
# Northwind brand

Primary: Northwind Navy #0E1B33. Accent: Harbour Orange #F26B3A (sparingly).
Secondary: Fog #C9D3DD. Tone: calm, precise, maritime. Never use the orange as a background.

```

**Assistant:** Navy is the ground, orange only as a glow, fog for light. A slow mesh gradient carries colour without a logo wall; grain keeps it from banding on big displays.

```
→ create_style({"name": "Northwind Tide", "fps": 24, "effects": [{"kind": "meshGradient", "params": {"speed": 0.25, "scale": 1.6, "hue": 0.12, "grain": 0.06}, "colorA": {"r": 0.055, "g": 0.106, "b": 0.2}, "colorB": {"r": 0.949, "g": 0.42, "b": 0.227}}]})
```
```text
Created “Northwind Tide” (B780A858-0AA0-4D53-B4F1-1100EBED2077). DotStudio isn't running: library.json was updated; the app shows it next time it opens.
Next: preview_style(style: "B780A858-0AA0-4D53-B4F1-1100EBED2077") — and a contact sheet over time (frames: 6) to check the motion.
```

```
→ preview_style({"style": "B780A858-0AA0-4D53-B4F1-1100EBED2077", "t": 30, "width": 1280, "height": 800})
```
```text
“Northwind Tide” at t = 30.0 s.
```

![brand-guide.jpg](img/brand-guide.jpg)

**Assistant:** The orange reads a little strong for “sparingly” — I'll take it down toward the navy and soften the field so the orange is a glow, not a wall.

```
→ update_style({"style": "B780A858-0AA0-4D53-B4F1-1100EBED2077", "patch": [{"index": 0, "params": {"hue": 0.05, "scale": 1.9}, "colorB": {"r": 0.5, "g": 0.29, "b": 0.24}}]})
```
```text
Updated “Northwind Tide”. DotStudio isn't running: library.json was updated; the app shows it next time it opens.
```

```
→ preview_style({"style": "B780A858-0AA0-4D53-B4F1-1100EBED2077", "t": 30, "width": 1280, "height": 800})
```
```text
“Northwind Tide” at t = 30.0 s.
```

![brand-guide-2.jpg](img/brand-guide-2.jpg)

```
→ export_style({"style": "B780A858-0AA0-4D53-B4F1-1100EBED2077", "path": "/var/folders/zl/ljs1svhj5px24269ln0rxvgm0000gn/T//ai-mcp/examples/Northwind Tide.dotstudiopreset"})
```
```text
Exported “Northwind Tide” to /var/folders/zl/ljs1svhj5px24269ln0rxvgm0000gn/T//ai-mcp/examples/Northwind Tide.dotstudiopreset.
```

**Assistant:** Exported as a .dotstudiopreset you can send to the team: double-clicking it adds the style in DotStudio.

Resulting style (as stored in `library.json`):

```json
{
  "effects": [
    {
      "colorA": {
        "r": 0.055,
        "b": 0.2,
        "g": 0.106,
        "a": 1
      },
      "id": "099E1545-373C-43C1-9461-620281D8E00C",
      "colorB": {
        "r": 0.5,
        "b": 0.24,
        "g": 0.29,
        "a": 1
      },
      "enabled": true,
      "kind": "meshGradient",
      "params": {
        "hue": 0.05,
        "speed": 0.25,
        "grain": 0.06,
        "scale": 1.9
      }
    }
  ],
  "id": "B780A858-0AA0-4D53-B4F1-1100EBED2077",
  "fps": 24,
  "name": "Northwind Tide"
}
```
