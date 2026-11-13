"""Record docs/ai/examples: each session's tool calls run against the REAL dotstudio-mcp in a throwaway store.

usage: python3 -I tools/mcp-selftest/examples.py <dotstudio-mcp> <repo root> <out dir> [slug,slug…]
The prompts and the assistant's choices are written here by hand (they're what a good session looks like); every
tool result, style JSON and preview PNG is what the server actually returned. Custom scenes run on the real engines;
the film session runs the self-test's stand-in toolkit (DOTSTUDIO_MCP_TEST_FAKES=film: the Blender toolkit isn't in
this build yet) with the real film engine, and says so. Give slugs to record just those sessions.
"""
import base64, json, os, shutil, subprocess, sys, tempfile, threading

BIN, ROOT, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
DOCS = os.path.join(ROOT, "docs", "ai", "examples")
os.makedirs(os.path.join(DOCS, "img"), exist_ok=True)
os.makedirs(OUT, exist_ok=True)


class Session:
    def __init__(self, slug, title, prompt, fakes=False, note=None, env_extra=None):
        """fakes: "film" = the real engines with the stand-in film toolkit; True = every stand-in."""
        self.slug, self.title, self.prompt, self.note = slug, title, prompt, note
        self.store = tempfile.mkdtemp(prefix="dsmcp-ex-")
        env = dict(os.environ, DOTSTUDIO_STORE_DIR=self.store, DOTSTUDIO_MCP_FAKE_DISPLAYS="37D8832A-2D66-02CA-B9F7-8F30A301B230=Built-in Retina Display")
        if fakes:
            env.update(DOTSTUDIO_MCP_TEST_FAKES="1" if fakes is True else fakes, DOTSTUDIO_MCP_FAKE_RENDER_SECONDS="2",
                       DOTSTUDIO_MCP_FAKE_BLENDER="/Applications/Blender.app/Contents/MacOS/Blender")
        env.update(env_extra or {})
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
            if "scene_files" in shown_args:
                shown_args["scene_files"] = {k: "…below…" for k in shown_args["scene_files"]}
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


ONLY = set(sys.argv[4].split(",")) if len(sys.argv) > 4 else None


def want(slug):
    """examples.py … [slug,slug]: record just these sessions (default: all)."""
    return ONLY is None or slug in ONLY


# 1 ─ calm ocean at dusk with a big clock
if want("calm-ocean-clock"):
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
if want("brand-guide"):
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
if want("match-my-wallpaper"):
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
if want("pixel-cat-led"):
    s = Session("pixel-cat-led", "A pixel cat on an LED panel (custom scene, cells engine)",
                "Make a little pixel cat sleeping on an LED panel, like the penguin one.")
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
    r = s.call("create_style", {"name": "Sleepy Cat", "fps": 24, "effects": [{"kind": "custom", "scene": scene,
                                                                             "params": {"zzz": True, "ds.render": "Dots"}}]})
    cat = r["structuredContent"]["id"]
    s.call("preview_style", {"style": cat, "t": 4, "width": 1280, "height": 800}, image="pixel-cat-led.png")
    s.call("benchmark_style", {"style": cat})
    s.style_json(cat)
    s.done()

# 5 ─ port a Shadertoy I own
if want("port-shadertoy"):
    index = os.path.join(OUT, "engines-index")
    subprocess.run([os.path.join(ROOT, "tools", "engines", "build-index.sh"), index], check=True, capture_output=True)
    s = Session("port-shadertoy", "Port a Shadertoy I wrote",
                "Port my Shadertoy “Slow Tide” (I wrote it, MIT) into DotStudio.",
                note="The shadertoy engine was pulled from a local copy of DotStudio's engines index (tools/engines/build-index.sh), "
                "as the app downloads it from the `engines` release.",
                env_extra={"DOTSTUDIO_ENGINES_INDEX": os.path.join(index, "engines-index.json")})
    s.call("list_engines", {"include_available": True}, max_text=400)
    s.call("pull_engine", {"id": "shadertoy"})
    s.call("read_guide", {"id": "engines/shadertoy"}, max_text=300)
    glsl = """// Slow Tide — (c) the user, MIT. Ported to DotStudio: time slowed 4x, palette from the scene's colours.
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    float t = iTime * 0.25;
    float w = sin(uv.x * 6.0 + t) * 0.03 + sin(uv.x * 13.0 - t * 1.3) * 0.015;
    float sea = smoothstep(0.45 + w, 0.44 + w, uv.y);
    vec3 col = mix(dsCtx.colorA, dsCtx.colorB, sea * (0.6 + 0.4 * uv.y));
    fragColor = vec4(col, 1.0);
}
"""
    r = s.call("create_custom_scene", {"manifest": {"name": "Slow Tide", "engine": {"id": "shadertoy"}, "entry": "scene.glsl", "fps": 30,
                                                    "licence": "MIT (user's own)", "author": "the user",
                                                    "colors": {"a": {"label": "Sky", "default": [0.03, 0.05, 0.1, 1]},
                                                               "b": {"label": "Sea", "default": [0.1, 0.35, 0.45, 1]}}},
                                       "source": glsl})
    r = s.call("create_style", {"name": "Slow Tide", "fps": 30, "effects": [{"kind": "custom", "scene": r["structuredContent"]["id"]}]})
    s.call("preview_style", {"style": r["structuredContent"]["id"], "t": 30, "width": 1280, "height": 800}, image="port-shadertoy.png")
    s.done()

# 6 ─ photoreal rainy café window (film)
if want("rainy-cafe-film"):
    s = Session("rainy-cafe-film", "A photoreal rainy café window (film scene)",
                "Can you make a photoreal one — looking out of a café window at night while it rains?", fakes="film",
                note="Making film scenes needs DotStudio's film toolkit (Blender), which isn't in DotStudio yet. This session ran against the "
                "self-test's stand-in toolkit with DotStudio's real film engine: the job flow, packaging, install and playback are real; "
                "its stills and clips are placeholders, so they aren't shown, and the scene module below is illustrative — it has not been run in Blender.")
    s.call("film_status", max_text=500)
    s.say("Blender 5.1 is installed. This uses DotStudio's film toolkit: about a minute per approval still, then "
          "a background render of a few hours for a 24-second loop, and roughly 300 MB for the two variants (night, rain). Go ahead?")
    s.md.append("> **You:** Go ahead.\n")
    s.call("read_guide", {"id": "film"}, max_text=300)
    s.call("list_film_templates", max_text=300)
    s.say("The only template is Commute (a train interior), so I'll write a new set with the toolkit: a café corner looking out "
          "through a rain-streaked window at a wet street. All assets CC0 (Poly Haven / ambientCG); every motion is a whole "
          "number of cycles per 24-second loop so it repeats seamlessly; the sign outside stays dim.")
    cafe_py = '''"""Rainy Café — a corner table at a café window, night, rain on the glass. Original set; CC0 assets only."""
from dsfilm import geometry as G, materials as M, lighting as L, loop as LP

ASSETS = ["ph:hdri:kloppenheim_07_puresky", "ph:tex:wood_table_001", "ph:tex:concrete_wall_008",
          "ph:model:coffee_cup_01", "acg:Asphalt012", "acg:Facade005"]
VARIANTS = ["night", "rain"]
CAMERAS = ["wide", "close"]

def build(ctx):
    c = ctx.coll("cafe")
    loop = ctx.loop                                            # 24 s at 24 fps: everything below repeats exactly
    table = G.box("table", (1.2, 0.7, 0.04), (0, 0.9, 0.74), c)
    table.data.materials.append(M.ph_pbr("oak", "wood_table_001", 0.8))
    cup = G.instance("cup", "coffee_cup_01", (0.15, 0.85, 0.78), c)
    wall = G.slab([[(-2, 0), (2, 0), (2, 2.6), (-2, 2.6)], [(-1.3, 0.9), (1.3, 0.9), (1.3, 2.3), (-1.3, 2.3)]], 0.2)
    wall.data.materials.append(M.ph_pbr("plaster", "concrete_wall_008", 2.0, desat=True, tint=(0.82, 0.74, 0.66)))
    glass = G.box("pane", (2.6, 0.01, 1.4), (0, 1.6, 1.6), c)
    glass.data.materials.append(M.thin_glass("window", 0.06, rain=1.0 if ctx.light.get("rain") else 0.6))
    street = G.box("street", (40, 30, 0.1), (0, 18, -0.4), c)
    street.data.materials.append(M.acg_pbr("wet asphalt", "Asphalt012", 4.0, rough=0.08))
    L.setup(ctx.scene, c, ctx.variant, exposure=3.3)
    lamp = G.sphere("pendant", 0.08, (0.1, 0.8, 1.9), c)
    lamp.data.materials.append(M.emission("tungsten", (1.0, 0.62, 0.32), 6.0))
    # steam: three wisps rising and fading, one full cycle each per loop, phase-offset
    for i in range(3):
        w = G.smooth_tube(f"steam{i}", [(0.15, 0.85, 0.80), (0.16, 0.86, 0.95), (0.13, 0.84, 1.1)], 0.01, c, taper=True)
        loop.bake([w], lambda t, i=i: {"scale": 0.6 + 0.4 * loop.wave(t, 1, i / 3), "alpha": 0.25 * loop.wave(t, 1, i / 3)})
    # a car's headlights sweep the wall twice per loop (period 12 s divides 24 s)
    sweep = G.empty("headlights", (0, 12, 0.6), c)
    loop.pulse_train(sweep, 12.0, lambda u: {"x": -20 + 40 * u, "energy": 400 * LP.bump(u, 0.5, 0.35)}, offsets=[0])
    cams = {"wide": G.look_at(G.empty("cam_wide", (0, -1.6, 1.35), c), (0, -1.6, 1.35), (0, 2.0, 1.2)),
            "close": G.look_at(G.empty("cam_close", (0.5, 0.2, 1.05), c), (0.5, 0.2, 1.05), (0.1, 0.9, 0.85))}
    return {"cameras": cams}
'''
    assets_json = json.dumps({"hdri": ["kloppenheim_07_puresky"], "tex": ["wood_table_001", "concrete_wall_008"],
                              "model": ["coffee_cup_01"], "acg": ["Asphalt012", "Facade005"]}, indent=1)
    r = s.call("create_film_scene", {"spec": {"scene": "local", "variant": "night", "loop": {"seconds": 24, "fps": 24},
                                              "render": {"engine": "cycles", "res": [1600, 1000], "samples": 384, "motion_blur": True},
                                              "stills": [{"name": "night_wide", "camera": "wide", "frame": 1, "variant": "night"},
                                                         {"name": "rain_wide", "camera": "wide", "frame": 1, "variant": "rain"}],
                                              "animation": {"camera": "wide", "engine": "eevee", "res": [2560, 1600], "samples": 64}},
                                     "name": "Rainy Café", "variants": ["night", "rain"],
                                     "look": {"bloom": 0.3, "halation": 0.35, "grain": 0.25},
                                     "scene_files": {"scene.py": cafe_py, "assets.json": assets_json}}, max_text=500)
    draft = r["structuredContent"]["draft"]
    s.md.append("`scene_files[\"scene.py\"]`:\n\n```python\n" + cafe_py.rstrip() + "\n```\n")
    s.call("render_film_stills", {"draft": draft, "wait_seconds": 30}, max_text=400)
    s.say("Here are the night and rain stills. Happy with the framing and the light before I animate it? (Halation is up at "
          "0.35 for the tungsten lamp against the dark window; grain is added live, so it won't repeat with the loop.)")
    s.md.append("> **You:** A touch brighter, a little less bloom. Then animate it.\n")
    s.call("update_film_scene", {"draft": draft, "look": {"bloom": 0.2}, "spec_patch": {"render": {"exposure": 0.3}}}, max_text=400)
    r = s.call("render_film_loop", {"draft": draft}, max_text=300)
    job = r["structuredContent"]["job"]
    import time
    time.sleep(1)
    s.call("film_job_status", {"job": job}, max_text=300)
    time.sleep(3)
    r = s.call("film_job_status", {"job": job}, max_text=400)
    scene = r["structuredContent"].get("scene", "")
    r = s.call("create_style", {"name": "Rainy Café", "fps": 24, "effects": [{"kind": "custom", "scene": scene, "params": {"ds.grain": 0.25}}]})
    s.say("“Rainy Café” is in your library. It's video, so it's light on the GPU — a good live wallpaper too.")
    s.done()
print("examples →", DOCS, "and", OUT)
