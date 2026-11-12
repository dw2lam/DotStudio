"""Record docs/ai/examples: each session's tool calls run against the REAL dotstudio-mcp in a throwaway store.

usage: python3 -I tools/mcp-selftest/examples.py <dotstudio-mcp> <repo root> <out dir>
The prompts and the assistant's choices are written here by hand (they're what a good session looks like); every
tool result, style JSON and preview PNG is what the server actually returned. Sessions that need an engine this
build doesn't have yet run against the self-test's stand-in engine (DOTSTUDIO_MCP_TEST_FAKES) and say so.
"""
import base64, json, os, shutil, subprocess, sys, tempfile, threading

BIN, ROOT, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
DOCS = os.path.join(ROOT, "docs", "ai", "examples")
os.makedirs(os.path.join(DOCS, "img"), exist_ok=True)
os.makedirs(OUT, exist_ok=True)


class Session:
    def __init__(self, slug, title, prompt, fakes=False, note=None):
        self.slug, self.title, self.prompt, self.note = slug, title, prompt, note
        self.store = tempfile.mkdtemp(prefix="dsmcp-ex-")
        env = dict(os.environ, DOTSTUDIO_STORE_DIR=self.store, DOTSTUDIO_MCP_FAKE_DISPLAYS="37D8832A-2D66-02CA-B9F7-8F30A301B230=Built-in Retina Display")
        if fakes:
            env.update(DOTSTUDIO_MCP_TEST_FAKES="1", DOTSTUDIO_MCP_FAKE_RENDER_SECONDS="2")
        self.p = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
        self.n = 0
        self.md = [f"# {title}\n", f"> **You:** {prompt}\n"]
        if note:
            self.md.append(f"_{note}_\n")
        self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "claude-ai", "version": "example"}})

    def rpc(self, method, params):
        self.n += 1
        self.p.stdin.write((json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params}) + "\n").encode())
        self.p.stdin.flush()
        return json.loads(self.p.stdout.readline())

    def say(self, text):
        self.md.append(f"**Assistant:** {text}\n")

    def call(self, name, args=None, show=True, max_text=900, image=None):
        r = self.rpc("tools/call", {"name": name, "arguments": args or {}})["result"]
        texts = [c["text"] for c in r["content"] if c["type"] == "text"]
        main = texts[0] if texts else ""
        if show:
            shown_args = dict(args or {})
            source = shown_args.pop("source", None)
            if source is not None:
                shown_args["source"] = "…below…"
            a = json.dumps(shown_args, ensure_ascii=False)
            self.md.append(f"```\n→ {name}({a})\n```")
            if source is not None:
                lang = "glsl" if "mainImage" in source else "metal"
                self.md.append(f"`source`:\n\n```{lang}\n{source.rstrip()}\n```")
            shown = main if len(main) <= max_text else main[:max_text] + " …"
            self.md.append("```text\n" + ("ERROR " if r.get("isError") else "") + shown + "\n```\n")
        for c in r["content"]:
            if c["type"] == "image" and image:
                png = base64.b64decode(c["data"])
                with open(os.path.join(OUT, image), "wb") as f:      # the PNG exactly as the tool returned it
                    f.write(png)
                # The repo keeps a JPEG (grainy previews are megabytes as PNG).
                jpg = image.replace(".png", ".jpg")
                subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "82", os.path.join(OUT, image),
                                "--out", os.path.join(DOCS, "img", jpg)], check=True, capture_output=True)
                self.md.append(f"![{jpg}](img/{jpg})\n")
                break
        return r

    def style_json(self, sid):
        r = self.call("get_style", {"style": sid}, show=False)
        self.md.append("Resulting style (as stored in `library.json`):\n\n```json\n" +
                       json.dumps(r["structuredContent"]["style"], indent=2, ensure_ascii=False) + "\n```\n")

    def done(self):
        self.p.stdin.close()
        self.p.wait(10)
        path = os.path.join(DOCS, f"{self.slug}.md")
        with open(path, "w") as f:
            f.write("\n".join(self.md))
        shutil.copy(path, OUT)
        shutil.rmtree(self.store, ignore_errors=True)
        print("wrote", path)


# 1 ─ calm ocean at dusk with a big clock
s = Session("calm-ocean-clock", "Calm ocean at dusk, with a big clock",
            "Make me a calm screensaver: the ocean at dusk, and I want to see the time big.")
s.call("get_started", max_text=600)
s.call("read_guide", {"id": "style/dotstudio"}, max_text=300)
s.call("describe_scene", {"kind": "oceanHorizon"}, max_text=200)
s.say("A style draws one scene, so the sea and a big clock can't share a frame. I'll make the dusk sea, a matching "
      "clock, and rotate them every few minutes — the clock keeps the dusk palette so the two read as one piece.")
r = s.call("create_style", {"name": "Dusk Tide", "fps": 30, "effects": [
    {"kind": "oceanHorizon", "params": {"sun": -0.6, "waves": 0.28, "clouds": 0.4, "haze": 0.7, "speed": 0.6, "weather": "Clear", "live": False},
     "colorA": {"r": 0.02, "g": 0.05, "b": 0.09}, "colorB": {"r": 1.0, "g": 0.66, "b": 0.45}}]})
tide = r["structuredContent"]["id"]
s.call("preview_style", {"style": tide, "t": 20, "width": 1280, "height": 800}, image="calm-ocean-clock-tide.png")
s.call("preview_style", {"style": tide, "frames": 6, "span": 240, "width": 1200, "height": 750}, image="calm-ocean-clock-sheet.png")
s.say("The sun sits just under the horizon and the swell is slow; the contact sheet shows four minutes of motion with no visible loop. Now the clock.")
s.call("describe_scene", {"kind": "minimalClock"}, max_text=200)
r = s.call("create_style", {"name": "Dusk Clock", "fps": 24, "effects": [
    {"kind": "minimalClock", "params": {"background": "Soft Gradient", "size": 1.4, "date": True}}]})
clock = r["structuredContent"]["id"]
s.call("preview_style", {"style": clock, "clock": "19:42", "width": 1280, "height": 800}, image="calm-ocean-clock-clock.png")
s.call("benchmark_style", {"style": tide})
s.say("Both are within budget. Want them as your screensaver, rotating every five minutes?")
s.md.append("> **You:** Yes please.\n")
s.call("set_screensaver", {"style": tide})
s.call("set_screensaver", {"style": clock, "mode": "add"})
s.style_json(tide)
s.done()

# 2 ─ brand colours from a guide
s = Session("brand-guide", "My brand colours, from a guide",
            "Use our brand guide and make a screensaver for the office Macs.")
os.makedirs(os.path.join(s.store, "guides"), exist_ok=True)
with open(os.path.join(s.store, "guides", "northwind-brand.md"), "w") as f:
    f.write("# Northwind brand\n\nPrimary: Northwind Navy #0E1B33. Accent: Harbour Orange #F26B3A (sparingly).\n"
            "Secondary: Fog #C9D3DD. Tone: calm, precise, maritime. Never use the orange as a background.\n")
s.call("get_started", max_text=500)
s.call("read_guide", {"id": "user/northwind-brand"})
s.say("Navy is the ground, orange only as a glow, fog for light. A slow mesh gradient carries colour without a logo wall; "
      "grain keeps it from banding on big displays.")
r = s.call("create_style", {"name": "Northwind Tide", "fps": 24, "effects": [
    {"kind": "meshGradient", "params": {"speed": 0.25, "scale": 1.6, "hue": 0.12, "grain": 0.06},
     "colorA": {"r": 0.055, "g": 0.106, "b": 0.2}, "colorB": {"r": 0.949, "g": 0.42, "b": 0.227}}]})
sid = r["structuredContent"]["id"]
s.call("preview_style", {"style": sid, "t": 30, "width": 1280, "height": 800}, image="brand-guide.png")
s.say("The orange reads a little strong for “sparingly” — I'll take it down toward the navy and soften the field so the orange is a glow, not a wall.")
s.call("update_style", {"style": sid, "patch": [{"index": 0, "params": {"hue": 0.05, "scale": 1.9},
                                                 "colorB": {"r": 0.5, "g": 0.29, "b": 0.24}}]})
s.call("preview_style", {"style": sid, "t": 30, "width": 1280, "height": 800}, image="brand-guide-2.png")
s.call("export_style", {"style": sid, "path": os.path.join(OUT, "Northwind Tide.dotstudiopreset")}, max_text=200)
s.say("Exported as a .dotstudiopreset you can send to the team: double-clicking it adds the style in DotStudio.")
s.style_json(sid)
s.done()

# 3 ─ match my wallpaper
s = Session("match-my-wallpaper", "Match my wallpaper",
            "Match my wallpaper — it's a foggy pine forest in the morning, all teal-grey and soft.")
s.call("get_started", max_text=300)
s.say("Fog, early light, muted greens: Meadow's landscapes do weather and time of day, so I'll take Tall Grass at dawn in fog, "
      "almost no flowers and a still wind, with a light grain wash so it sits with the photo.")
r = s.call("create_style", {"name": "Morning Fog", "fps": 24, "effects": [
    {"kind": "meadow", "params": {"live": False, "hour": 6.5, "weather": "Fog", "landscape": "Tall Grass", "flowers": 0.05, "wind": 0.2, "speed": 0.6},
     "colorA": {"r": 0.22, "g": 0.34, "b": 0.30}, "colorB": {"r": 0.72, "g": 0.76, "b": 0.74}},
    {"kind": "grainWash", "params": {"soft": 0.2, "grain": 0.06, "tint": 0.1}}]})
sid = r["structuredContent"]["id"]
s.call("preview_style", {"style": sid, "t": 12, "width": 1280, "height": 800}, image="match-my-wallpaper.png")
s.call("benchmark_style", {"style": sid})
s.style_json(sid)
s.done()

# 4 ─ a pixel cat on an LED panel (custom cells scene)
s = Session("pixel-cat-led", "A pixel cat on an LED panel (custom scene, cells engine)",
            "Make a little pixel cat sleeping on an LED panel, like the penguin one.",
            fakes=True, note="Custom scenes arrive with DotStudio's scene-engine update. This session was recorded against the "
            "self-test's stand-in engine, so the tool calls and answers are real but no preview image is shown.")
s.call("list_engines", max_text=300)
s.call("read_guide", {"id": "engines/cells"}, max_text=400)
src = r'''#include <DotStudio.h>
// A sleeping cat, 24×14 cells, breathing slowly; one z drifts up every ~9 s.
float4 dsScene(float2 uv, DSContext ctx) {
    float2 g = floor(uv * float2(48, 27));                 // cell grid
    float breathe = 0.5 + 0.5 * sin(ctx.t * 0.7);          // slow, never a hard loop with the z below
    float2 c = g - float2(24, 9);
    float body = step(length(c / float2(9, 4.5 + breathe * 0.4)), 1.0) * step(-4.0, c.y);
    float head = step(length((c - float2(7, 3)) / 3.2), 1.0);
    float ears = step(abs(c.x - 6) + abs(c.y - 6.5), 1.2) + step(abs(c.x - 9) + abs(c.y - 6.5), 1.2);
    float cat = saturate(body + head + ears);
    float zt = fract(ctx.t / 9.0);
    float2 zp = float2(31 + zt * 3, 13 + zt * 6);
    float z = step(abs(g.x - zp.x) + abs(g.y - zp.y), 0.6) * (1 - zt) * ctx.p[1];
    float3 col = mix(ctx.colorA.rgb, ctx.colorB.rgb, cat) + z * 0.6;
    return float4(col, max(cat, z));                       // colour + coverage: the engine lights cells
}
'''
manifest = {"name": "Sleepy Cat", "engine": {"id": "cells", "version": ">=1"}, "fps": 24, "stepped": True, "licence": "own work",
            "params": [{"key": "breath", "label": "Breathing", "kind": "slider", "min": 0, "max": 1, "default": 0.5},
                       {"key": "zzz", "label": "Zzz", "kind": "toggle", "default": 1}],
            "colors": {"a": {"label": "Panel", "default": [0.02, 0.02, 0.03, 1]}, "b": {"label": "Cat", "default": [0.98, 0.72, 0.38, 1]}},
            "uses": [], "description": "A pixel cat asleep on a dark LED panel.", "guides": ["style/dotstudio"]}
r = s.call("create_custom_scene", {"manifest": manifest, "source": src})
scene = r["structuredContent"].get("id", "sleepy-cat")
r = s.call("create_style", {"name": "Sleepy Cat", "fps": 24, "effects": [{"kind": "custom", "scene": scene, "params": {"zzz": True}}]})
s.style_json(r["structuredContent"]["id"])
s.done()

# 5 ─ port a Shadertoy I own
s = Session("port-shadertoy", "Port a Shadertoy I wrote",
            "Port my Shadertoy “Slow Tide” (I wrote it, MIT) into DotStudio.", fakes=True,
            note="Recorded against the self-test's stand-in engine (the shadertoy engine is pullable once the scene-engine update ships); no preview image.")
s.call("list_engines", {"include_available": True}, max_text=400)
s.call("pull_engine", {"id": "shadertoy"})
s.call("read_guide", {"id": "engines/shadertoy"}, max_text=300)
glsl = """// Slow Tide — (c) the user, MIT. Ported to DotStudio: time slowed 4x, palette from the scene's colours.
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    float t = iTime * 0.25;
    float w = sin(uv.x * 6.0 + t) * 0.03 + sin(uv.x * 13.0 - t * 1.3) * 0.015;
    float sea = smoothstep(0.45 + w, 0.44 + w, uv.y);
    vec3 col = mix(colorA.rgb, colorB.rgb, sea * (0.6 + 0.4 * uv.y));
    fragColor = vec4(col, 1.0);
}
"""
r = s.call("create_custom_scene", {"manifest": {"name": "Slow Tide", "engine": {"id": "shadertoy"}, "entry": "scene.glsl", "fps": 30,
                                                "licence": "MIT (user's own)", "author": "the user",
                                                "colors": {"a": {"label": "Sky", "default": [0.03, 0.05, 0.1, 1]},
                                                           "b": {"label": "Sea", "default": [0.1, 0.35, 0.45, 1]}}},
                                   "source": glsl})
s.done()

# 6 ─ photoreal rainy café window (film)
s = Session("rainy-cafe-film", "A photoreal rainy café window (film scene)",
            "Can you make a photoreal one — looking out of a café window at night while it rains?", fakes=True,
            note="Film scenes arrive with the film engine (DotStudio's Blender toolkit). This session was recorded against the "
            "self-test's stand-in toolkit: the job flow, progress and install are real; the stills it returned were placeholders, "
            "so they aren't shown.")
s.call("film_status", max_text=400)
s.say("This needs Blender and the film engine, a render of roughly an hour, and a few hundred MB. Shall I go ahead?")
s.md.append("> **You:** Go ahead.\n")
s.call("pull_engine", {"id": "film"})
s.call("read_guide", {"id": "engines/film"}, max_text=300)
spec = {"scene": {"set": "cafe-window", "camera": {"lens_mm": 35, "height_m": 1.2, "look": "street"},
                  "assets": ["cc0:polyhaven/wooden_table_02", "cc0:polyhaven/coffee_cup", "cc0:ambientcg/Glass_Rain"],
                  "lighting": {"interior": "warm tungsten 2700K, low", "exterior": "sodium street lamps, wet asphalt"},
                  "motion": [{"type": "rain_on_glass", "loop": True}, {"type": "steam", "source": "coffee_cup", "loop": True},
                             {"type": "passing_headlights", "every_s": 14}]},
        "variants": ["night", "rain"]}
r = s.call("create_film_scene", {"spec": spec, "name": "Rainy Café"})
draft = r["structuredContent"]["draft"]
s.call("render_film_stills", {"draft": draft, "variants": ["night", "rain"], "samples": 64, "wait_seconds": 30})
s.say("Here are the base stills. Happy with the framing and the light before I animate it?")
s.md.append("> **You:** Love it. Animate it.\n")
r = s.call("render_film_loop", {"draft": draft, "variants": ["night", "rain"], "seconds": 20, "fps": 24})
job = r["structuredContent"]["job"]
import time
time.sleep(1)
s.call("film_job_status", {"job": job}, max_text=300)
time.sleep(3)
r = s.call("film_job_status", {"job": job}, max_text=400)
scene = r["structuredContent"].get("scene", "")
r = s.call("create_style", {"name": "Rainy Café", "fps": 24, "effects": [{"kind": "custom", "scene": scene}]})
s.done()
print("examples →", DOCS, "and", OUT)
