"""dotstudio-mcp end-to-end self-test (see run.sh). Exit 0 = PASS."""
import base64, json, os, shutil, signal, struct, subprocess, sys, tempfile, threading, time, zlib

BIN, ROOT, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
FAILS = []
CHECKS = 0


def check(cond, what):
    global CHECKS
    CHECKS += 1
    print(("PASS  " if cond else "FAIL  ") + what, flush=True)
    if not cond:
        FAILS.append(what)
    return cond


def new_store():
    d = tempfile.mkdtemp(prefix="dsmcp-")
    return d


def env_for(store, **extra):
    e = dict(os.environ)
    e["DOTSTUDIO_STORE_DIR"] = store
    e["DOTSTUDIO_MCP_FAKE_DISPLAYS"] = "DISPLAY-A=Built-in Retina Display,DISPLAY-B=LG HDR 4K"
    e["DOTSTUDIO_MCP_FAKE_BLENDER"] = "/fake/Blender"   # never look at (or launch) a real Blender
    e.update({k: str(v) for k, v in extra.items()})
    return e


class Client:
    def __init__(self, store, **extra):
        self.p = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  env=env_for(store, **extra))
        self.next = 1
        self.store = store
        threading.Thread(target=self._drain, daemon=True).start()

    def _drain(self):
        for _ in self.p.stderr:
            pass

    def raw(self, line):
        self.p.stdin.write((line + "\n").encode())
        self.p.stdin.flush()
        return json.loads(self.p.stdout.readline())

    def req(self, method, params=None):
        mid = self.next
        self.next += 1
        msg = {"jsonrpc": "2.0", "id": mid, "method": method}
        if params is not None:
            msg["params"] = params
        r = self.raw(json.dumps(msg))
        assert r.get("id") == mid, r
        return r

    def notify(self, method):
        self.p.stdin.write((json.dumps({"jsonrpc": "2.0", "method": method}) + "\n").encode())
        self.p.stdin.flush()

    def init(self):
        r = self.req("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                    "clientInfo": {"name": "claude-ai", "version": "selftest"}})
        self.notify("notifications/initialized")
        return r

    def call(self, name, args=None):
        r = self.req("tools/call", {"name": name, "arguments": args or {}})
        return r["result"]

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(10)
        except Exception:
            self.p.kill()


def text(res):
    return "\n".join(c.get("text", "") for c in res["content"] if c["type"] == "text")


def ok(res, what):
    return check(not res.get("isError"), what + ("" if not res.get("isError") else " — " + text(res)[:300]))


def err(res, what, needle=None):
    good = res.get("isError") is True and (needle is None or needle.lower() in text(res).lower())
    return check(good, what + ("" if good else " — got: " + text(res)[:300]))


def png_ok(b):
    """Valid PNG: signature, IHDR, every chunk's CRC, IEND, image data inflates to the right size."""
    if b[:8] != b"\x89PNG\r\n\x1a\n":
        return False, None
    i, w, h, idat, ihdr = 8, 0, 0, b"", None
    while i < len(b):
        ln, = struct.unpack(">I", b[i:i + 4])
        typ, data = b[i + 4:i + 8], b[i + 8:i + 8 + ln]
        crc, = struct.unpack(">I", b[i + 8 + ln:i + 12 + ln])
        if zlib.crc32(typ + data) & 0xffffffff != crc:
            return False, None
        if typ == b"IHDR":
            w, h = struct.unpack(">II", data[:8])
            ihdr = data
        elif typ == b"IDAT":
            idat += data
        elif typ == b"IEND":
            break
        i += 12 + ln
    bpp = {6: 4, 2: 3, 0: 1, 4: 2}.get(ihdr[9], 4) if ihdr else 4
    raw = zlib.decompress(idat)
    return len(raw) == h * (1 + w * bpp * ihdr[8] // 8), (w, h)


def image(res):
    imgs = [c for c in res["content"] if c["type"] == "image"]
    return base64.b64decode(imgs[0]["data"]) if imgs else None


def png_pixels(b):
    """8-bit RGB(A) PNG → (w, h, rows of [(r, g, b) 0…1]), undoing the scanline filters."""
    i, idat, w, h, ct = 8, b"", 0, 0, 6
    while i < len(b):
        ln, = struct.unpack(">I", b[i:i + 4])
        typ, data = b[i + 4:i + 8], b[i + 8:i + 8 + ln]
        if typ == b"IHDR":
            w, h = struct.unpack(">II", data[:8])
            ct = data[9]
        elif typ == b"IDAT":
            idat += data
        i += 12 + ln
    bpp = 4 if ct == 6 else 3
    raw, stride, rows, prev = zlib.decompress(idat), w * bpp, [], bytearray(w * bpp)
    for y in range(h):
        f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            up, ul = prev[x], (prev[x - bpp] if x >= bpp else 0)
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + up) & 255
            elif f == 3: line[x] = (line[x] + (a + up) // 2) & 255
            elif f == 4:
                p = a + up - ul
                pa, pb, pc = abs(p - a), abs(p - up), abs(p - ul)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else up if pb <= pc else ul)) & 255
        rows.append([(line[x] / 255, line[x + 1] / 255, line[x + 2] / 255) for x in range(0, stride, bpp)])
        prev = line
    return w, h, rows


def region_mean(px, x0, x1, y0, y1):
    """Mean (r, g, b) of a region given in fractions of the image."""
    w, h, rows = px
    cells = [rows[y][x] for y in range(int(y0 * h), max(int(y1 * h), int(y0 * h) + 1))
             for x in range(int(x0 * w), max(int(x1 * w), int(x0 * w) + 1))]
    return tuple(sum(c[k] for c in cells) / len(cells) for k in range(3))


def library(store):
    with open(os.path.join(store, "library.json")) as f:
        return json.load(f)


def names(store):
    return [p["name"] for p in library(store)["presets"]]


# ---------------------------------------------------------------- protocol

print("== protocol")
S = new_store()
c = Client(S)
r = c.init()
check(r["result"]["protocolVersion"] == "2025-06-18", "initialize negotiates the client's version")
check("tools" in r["result"]["capabilities"] and "resources" in r["result"]["capabilities"] and "prompts" in r["result"]["capabilities"], "capabilities: tools, resources, prompts")
check(len(r["result"].get("instructions", "")) > 50, "server instructions present")
check(c.req("ping")["result"] == {}, "ping")
r = c.req("initialize", {"protocolVersion": "1999-01-01", "capabilities": {}, "clientInfo": {"name": "x", "version": "1"}})
check(r["result"]["protocolVersion"] == "2025-11-25", "unknown version → server's latest")
check(c.req("no/such")["error"]["code"] == -32601, "unknown method → -32601")
check(c.raw("{not json")["error"]["code"] == -32700, "parse error → -32700")
check("error" in c.req("tools/call", {"name": "nope", "arguments": {}}), "unknown tool → JSON-RPC error")
tools = c.req("tools/list")["result"]["tools"]
tnames = [t["name"] for t in tools]
expected = ["get_started", "list_guides", "read_guide", "list_scenes", "describe_scene", "list_styles", "get_style",
            "create_style", "update_style", "duplicate_style", "delete_style", "preview_style", "benchmark_style",
            "export_style", "import_style", "list_displays", "set_screensaver", "set_wallpaper", "list_engines",
            "pull_engine", "list_custom_scenes", "validate_custom_scene", "create_custom_scene", "update_custom_scene",
            "film_status", "list_film_templates", "create_film_scene", "get_film_scene", "update_film_scene", "render_film_stills", "render_film_loop", "film_job_status", "cancel_film_job"]
check(sorted(tnames) == sorted(expected), f"tools/list has the {len(expected)} tools")
check(all(t["inputSchema"]["type"] == "object" and t["inputSchema"].get("additionalProperties") is False
          and len(t["description"]) > 40 and "annotations" in t for t in tools), "every tool: strict object schema, description, annotations")
check(next(t for t in tools if t["name"] == "set_screensaver")["description"].startswith("CHANGES THE USER'S MAC"), "set_screensaver says it changes the Mac")
err(c.call("read_guide", {"id": "style/dotstudio", "bogus": 1}), "extra argument → invalid_arguments", "unknown property")
err(c.call("read_guide", {}), "missing required argument", "missing required")

# ---------------------------------------------------------------- guides, catalog
print("== guides, resources, prompts, catalog")
os.makedirs(os.path.join(S, "guides"), exist_ok=True)
with open(os.path.join(S, "guides", "acme-brand.md"), "w") as f:
    f.write("# Acme brand\n\nNavy #0B1F3A and signal orange #FF6A13. Calm, confident.\n")
res = c.call("get_started")
ok(res, "get_started")
check("user/acme-brand" in res["structuredContent"]["userGuides"], "get_started lists the user's guide")
check(res["structuredContent"]["appRunning"] is False, "get_started: app not running")
res = c.call("list_guides")
ids = [g["id"] for g in res["structuredContent"]["guides"]]
for g in ["style/dotstudio", "settings/app", "settings/index", "settings/looks", "settings/oceanHorizon", "power", "burn-in",
          "engines/metal", "engines/film", "user/acme-brand"]:
    check(g in ids, f"list_guides has {g}")
check(ids[0] == "style/dotstudio", "style guide listed first")
res = c.call("read_guide", {"id": "style/dotstudio"})
ok(res, "read_guide style/dotstudio")
check(len(text(res)) > 3000, "style guide has substance")
res = c.call("read_guide", {"id": "settings/oceanHorizon"})
check("`weather`" in text(res) and "Follow the Sun" in text(res), "generated scene guide lists params")
err(c.call("read_guide", {"id": "nope/never"}), "read_guide unknown id", "list_guides")
rl = c.req("resources/list")["result"]["resources"]
check(any(x["uri"] == "dotstudio://guides/style/dotstudio" for x in rl), "resources/list exposes guides")
rr = c.req("resources/read", {"uri": "dotstudio://guides/user/acme-brand"})["result"]["contents"][0]
check(rr["mimeType"] == "text/markdown" and "Acme" in rr["text"], "resources/read a user guide")
check("error" in c.req("resources/read", {"uri": "dotstudio://guides/none"}), "resources/read missing → error")
check(len(c.req("resources/templates/list")["result"]["resourceTemplates"]) == 1, "resource template")
pl = c.req("prompts/list")["result"]["prompts"]
check(sorted(p["name"] for p in pl) == ["brand-screensaver", "design-a-screensaver", "match-my-wallpaper"], "prompts/list")
pg = c.req("prompts/get", {"name": "design-a-screensaver", "arguments": {"mood": "calm", "colours": "teal and amber", "subject": "the sea"}})
check("teal and amber" in pg["result"]["messages"][0]["content"]["text"], "prompts/get fills arguments")
pg = c.req("prompts/get", {"name": "brand-screensaver", "arguments": {"guide": "user/acme-brand"}})
check("user/acme-brand" in pg["result"]["messages"][0]["content"]["text"], "brand prompt names the guide")
check("error" in c.req("prompts/get", {"name": "design-a-screensaver", "arguments": {}}), "prompt missing required arg → error")
check("error" in c.req("prompts/get", {"name": "nope"}), "unknown prompt → error")
res = c.call("list_scenes")
ok(res, "list_scenes")
kinds = [s["kind"] for s in res["structuredContent"]["items"]]
check("oceanHorizon" in kinds and "flowerBloom" in kinds and "pipes" not in kinds and "dialClock" not in kinds, "list_scenes: live scenes, no retired ones")
res = c.call("list_scenes", {"type": "look"})
check("halftone" in [s["kind"] for s in res["structuredContent"]["items"]], "list_scenes looks")
err(c.call("list_scenes", {"type": "weird"}), "list_scenes bad type", "isn't one of")
res = c.call("describe_scene", {"kind": "oceanHorizon"})
ok(res, "describe_scene oceanHorizon")
d = res["structuredContent"]
check("weather" in d["reactsTo"] and "sun" in d["reactsTo"] and d["colors"]["colorA"]["label"] == "Deep Water", "describe_scene: reacts to + colour labels")
check(any(p["key"] == "weather" and p["kind"] == "menu" for p in d["params"]), "describe_scene: menu params")
check(c.call("describe_scene", {"kind": "Liquid Chrome"})["structuredContent"]["kind"] == "liquidChrome", "describe_scene by display name")
err(c.call("describe_scene", {"kind": "unicorns"}), "describe_scene unknown", "list_scenes")

# ---------------------------------------------------------------- styles
print("== styles (app not running: files under the lock)")
res = c.call("list_styles")
ok(res, "list_styles")
check(len(res["structuredContent"]["styles"]) > 10, "default library listed")
res = c.call("get_style", {"style": "Golden Hour"})
ok(res, "get_style by name")
check(res["structuredContent"]["style"]["effects"][0]["kind"] == "oceanHorizon", "get_style returns the stored JSON")
err(c.call("get_style", {"style": "No Such Style"}), "get_style unknown", "list_styles")
dusk = {"name": "Harbour Dusk", "fps": 30, "effects": [
    {"kind": "oceanHorizon", "params": {"sun": 1.5, "waves": 0.3, "weather": "Clear", "live": False},
     "colorA": {"r": 0.02, "g": 0.06, "b": 0.1}, "colorB": {"r": 1, "g": 0.72, "b": 0.48}},
    {"kind": "grain", "params": {"amount": 0.08}}]}
res = c.call("create_style", dusk)
ok(res, "create_style")
dusk_id = res["structuredContent"]["id"]
check("Harbour Dusk" in names(S), "create_style wrote library.json")
lib = library(S)
p = next(p for p in lib["presets"] if p["id"] == dusk_id)
check(p["effects"][0]["params"]["weather"] == 1 and p["effects"][0]["params"]["live"] == 0, "menu by name → index, toggle → 0/1")
check(res["structuredContent"]["liveInApp"] is False, "offline write reported")
res = c.call("create_style", dusk)
check(res["structuredContent"]["name"] == "Harbour Dusk 2", "duplicate names get a number")
err(c.call("create_style", {"name": "X", "effects": [{"kind": "oceanHorizon", "params": {"sun": 99}}]}), "out-of-range param", "outside")
err(c.call("create_style", {"name": "X", "effects": [{"kind": "oceanHorizon", "params": {"nope": 1}}]}), "unknown param", "has no param")
err(c.call("create_style", {"name": "X", "effects": [{"kind": "warpDrive"}]}), "unknown kind", "list_scenes")
err(c.call("create_style", {"name": "X", "effects": [{"kind": "pipes"}]}), "retired kind refused", "retired")
err(c.call("create_style", {"name": "X", "effects": [{"kind": "oceanHorizon", "params": {"weather": "Hurricane"}}]}), "bad menu option", "isn't an option")
err(c.call("create_style", {"name": "X", "effects": []}), "empty effects", "at least 1")
err(c.call("create_style", {"name": "X", "fps": 50, "effects": [{"kind": "silk"}]}), "fps not a choice", "isn't one of")
err(c.call("create_style", {"name": "X", "effects": [{"kind": "silk", "colorA": {"r": 2, "g": 0, "b": 0}}]}), "colour out of range", "maximum")
err(c.call("create_style", {"name": "X", "effects": [{"kind": "custom", "scene": "x-12345678"}]}), "custom kind with a scene that isn't installed", "no installed")
res = c.call("update_style", {"style": dusk_id, "patch": [{"index": 0, "params": {"waves": 0.6}}], "name": "Harbour Night"})
ok(res, "update_style patch + rename")
p = next(p for p in library(S)["presets"] if p["id"] == dusk_id)
check(p["name"] == "Harbour Night" and p["effects"][0]["params"]["waves"] == 0.6 and p["effects"][0]["params"]["sun"] == 1.5, "patch merges params")
err(c.call("update_style", {"style": dusk_id, "patch": [{"index": 5, "params": {}}]}), "patch bad index", "effect(s)")
err(c.call("update_style", {"style": dusk_id, "effects": [{"kind": "silk"}], "patch": [{"index": 0}]}), "effects + patch", "not both")
res = c.call("duplicate_style", {"style": "Golden Hour", "name": "Golden Hour Variation"})
ok(res, "duplicate_style a built-in")
dup_id = res["structuredContent"]["id"]
err(c.call("duplicate_style", {"style": "nope"}), "duplicate unknown", "No style")
err(c.call("delete_style", {"style": "Liquid Chrome"}), "delete the user's style without confirm", "confirm")
check("Liquid Chrome" in names(S), "…and it's still there")
ok(c.call("delete_style", {"style": "Liquid Chrome", "confirm": True}), "delete the user's style with confirm")
ok(c.call("delete_style", {"style": dup_id}), "delete an AI style")
check(dup_id not in [p["id"] for p in library(S)["presets"]], "deleted from library.json")
res = c.call("list_styles", {"filter": "ai"})
check(sorted(s["name"] for s in res["structuredContent"]["styles"]) == ["Harbour Dusk 2", "Harbour Night"], "list_styles filter ai")

# ---------------------------------------------------------------- previews
print("== previews")
res = c.call("preview_style", {"style": dusk_id, "width": 640, "height": 400, "t": 30, "save_path": os.path.join(OUT, "harbour.png")})
ok(res, "preview_style still")
b = image(res)
good, size = png_ok(b) if b else (False, None)
check(good and size == (640, 400), f"preview is a valid 640×400 PNG ({size})")
check(os.path.exists(os.path.join(OUT, "harbour.png")), "save_path written")
check(res["structuredContent"]["meanLuminance"] > 0.02, "preview isn't black")
res = c.call("preview_style", {"style": dusk_id, "width": 900, "height": 600, "frames": 4, "span": 60})
ok(res, "contact sheet")
good, size = png_ok(image(res))
check(good and len(res["structuredContent"]["times"]) == 4, f"contact sheet PNG {size}, 4 times")
res = c.call("preview_style", {"style": "StandBy", "clock": "07:45", "date": "2026-06-21", "music_card": True, "width": 800, "height": 500,
                               "save_path": os.path.join(OUT, "standby-0745-music.png")})
ok(res, "preview with clock + music card")
res = c.call("preview_style", {"style": "Golden Hour", "weather": "thunderstorm", "width": 640, "height": 400})
ok(res, "preview with forced weather")
res = c.call("preview_style", {"draft": {"effects": [{"kind": "liquidChrome", "params": {"speed": 0.3}}]}, "width": 480, "height": 300})
ok(res, "preview an unsaved draft")
err(c.call("preview_style", {"style": dusk_id, "clock": "25:00"}), "bad clock", "match")
err(c.call("preview_style", {"style": dusk_id, "weather": "acid"}), "bad weather", "isn't one of")
err(c.call("preview_style", {}), "preview needs a style", "style")
err(c.call("preview_style", {"style": dusk_id, "draft": {"effects": [{"kind": "silk"}]}}), "style + draft", "not both")
res = c.call("benchmark_style", {"style": "Golden Hour"})
ok(res, "benchmark_style at 5K")
sc = res["structuredContent"]
check(sc["width"] == 5120 and 0 < sc["minMs"] < 100, f"benchmark numbers ({sc['minMs']:.2f} ms)")
err(c.call("benchmark_style", {"style": "nope"}), "benchmark unknown", "No style")

# ---------------------------------------------------------------- share files
print("== export / import")
path = os.path.join(OUT, "Harbour Night.dotstudiopreset")
res = c.call("export_style", {"style": dusk_id, "path": path})
ok(res, "export_style")
doc = json.load(open(path))
check(doc["formatVersion"] == 1 and doc["preset"]["name"] == "Harbour Night", "share file format")
res = c.call("import_style", {"path": path})
ok(res, "import_style from file")
check(res["structuredContent"]["id"] != dusk_id, "import gets a fresh id")
doc["preset"]["name"] = "From JSON"
ok(c.call("import_style", {"json": doc}), "import_style from JSON")
err(c.call("import_style", {"json": {"hello": 1}}), "import junk", "share file")
err(c.call("export_style", {"style": dusk_id, "path": "/tmp/x.txt"}), "export bad extension", "match")

# ---------------------------------------------------------------- what plays (offline)
print("== screensaver / wallpaper (offline)")
res = c.call("list_displays")
ok(res, "list_displays")
check([d["key"] for d in res["structuredContent"]["displays"]] == ["DISPLAY-A", "DISPLAY-B"], "displays listed")
ok(c.call("set_screensaver", {"style": dusk_id}), "set_screensaver only")
lib = library(S)
check(lib["activeID"] == dusk_id and lib["rotation"]["enabled"] is False, "lineup = just that style")
gh = next(p["id"] for p in lib["presets"] if p["name"] == "Golden Hour")
ok(c.call("set_screensaver", {"style": "Golden Hour", "mode": "add"}), "add to rotation")
lib = library(S)
check(lib["rotation"]["enabled"] is True and set(lib["rotation"]["presetIDs"]) == {dusk_id, gh}, "rotation of two")
ok(c.call("set_screensaver", {"style": "Golden Hour", "mode": "remove"}), "remove from rotation")
err(c.call("set_screensaver", {"style": dusk_id, "mode": "remove"}), "can't remove the last", "only style")
ok(c.call("set_screensaver", {"style": "Night Sky", "mode": "night"}), "night style")
check(library(S)["schedule"]["enabled"] is True, "schedule on")
ok(c.call("set_screensaver", {"mode": "dayOnly"}), "dayOnly")
check(library(S)["schedule"]["enabled"] is False, "schedule off")
ok(c.call("set_screensaver", {"style": "Golden Hour", "display": "DISPLAY-B"}), "per-display screensaver")
check(library(S)["displayStyles"]["DISPLAY-B"]["presetID"] == gh, "pin stored under the display key")
err(c.call("set_screensaver", {"style": "Golden Hour", "display": "NOPE"}), "unknown display", "list_displays")
ok(c.call("set_screensaver", {"mode": "unpin", "display": "DISPLAY-B"}), "unpin")
check("displayStyles" not in library(S), "pin removed")
ok(c.call("set_wallpaper", {"style": dusk_id}), "set_wallpaper")
w = json.load(open(os.path.join(S, "wallpaper.json")))
check(w["enabled"] is True and w["presetID"] == dusk_id and w["followsScreensaver"] is False, "wallpaper.json set")
ok(c.call("set_wallpaper", {"style": "Golden Hour", "display": "DISPLAY-A"}), "per-display wallpaper")
check(json.load(open(os.path.join(S, "wallpaper.json")))["displayStyles"]["DISPLAY-A"]["presetID"] == gh, "wallpaper pin")
ok(c.call("set_wallpaper", {"mode": "follow"}), "wallpaper follows screensaver")
ok(c.call("set_wallpaper", {"mode": "off"}), "wallpaper off")
check(json.load(open(os.path.join(S, "wallpaper.json")))["enabled"] is False, "wallpaper off stored")
with open(os.path.join(S, "ai-settings.json"), "w") as f:
    json.dump({"allowPlaybackChanges": False}, f)
err(c.call("set_screensaver", {"style": "Golden Hour"}), "playback changes off → refused", "turned off")
err(c.call("set_wallpaper", {"style": "Golden Hour"}), "wallpaper refused too", "turned off")
ok(c.call("create_style", {"name": "Still Allowed", "effects": [{"kind": "silk"}]}), "styles still creatable with playback off")
os.remove(os.path.join(S, "ai-settings.json"))

# ---------------------------------------------------------------- custom + film: this build
print("== custom scenes / film (this build: real engines, no film toolkit yet)")
res = c.call("list_engines")
ok(res, "list_engines")
eng = {e["id"]: e for e in res["structuredContent"]["installed"]}
check({"metal", "cells", "film"} <= set(eng) and all(eng[i]["builtIn"] for i in ("metal", "cells", "film")),
      "metal, cells and film are built in")
res = c.call("create_custom_scene", {"manifest": {"name": "A", "engine": {"id": "metal"}}, "source": "x"})
err(res, "create_custom_scene: a real compile rejects junk", "doesn't compile")
check(not os.path.isdir(os.path.join(S, "scenes")) or os.listdir(os.path.join(S, "scenes")) == [], "nothing installed")
res = c.call("film_status")
ok(res, "film_status works without the toolkit")
check(res["structuredContent"]["available"] is False, "the film toolkit isn't in this build")
err(c.call("create_film_scene", {"spec": {"scene": {}}}), "create_film_scene unavailable", "isn't available")
c.close()

# ---------------------------------------------------------------- custom + film: fakes
print("== custom scenes / film (test fakes)")
F = new_store()
c = Client(F, DOTSTUDIO_MCP_TEST_FAKES=1, DOTSTUDIO_MCP_FAKE_RENDER_SECONDS=2)
c.init()
res = c.call("list_engines", {"include_available": True})
ok(res, "list_engines")
check({"metal", "cells"} <= {e["id"] for e in res["structuredContent"]["installed"]}, "built-in engines")
err(c.call("pull_engine", {"id": "nope"}), "pull unknown engine", "no engine")
ok(c.call("pull_engine", {"id": "shadertoy"}), "pull_engine shadertoy")
check("engines/shadertoy" in [g["id"] for g in c.call("list_guides")["structuredContent"]["guides"]], "pulled engine's guide listed")
manifest = {"name": "Aurora Lake", "engine": {"id": "metal", "version": ">=1"}, "fps": 30,
            "params": [{"key": "speed", "label": "Speed", "kind": "slider", "min": 0, "max": 1, "default": 0.4},
                       {"key": "stars", "label": "Stars", "kind": "toggle", "default": 1},
                       {"key": "mood", "label": "Mood", "kind": "menu", "options": ["Calm", "Vivid"], "default": 0}],
            "colors": {"a": {"label": "Sky", "default": [0.02, 0.04, 0.1, 1]}, "b": {"label": "Glow", "default": [0.3, 1, 0.7, 1]}},
            "uses": ["sun"]}
src = "#include <DotStudio.h>\nfloat4 dsScene(float2 uv, DSContext ctx) {\n  return float4(uv, 0.2, 1);\n}\n"
bad = src.replace("return", "#error nope\n  return")
res = c.call("validate_custom_scene", {"manifest": manifest, "source": bad})
err(res, "validate reports compile errors", "error")
check(res["structuredContent"]["diagnostics"][0]["line"] == 3 and ">   3 |   #error nope" in text(res), "diagnostic with line + source excerpt")
err(c.call("create_custom_scene", {"manifest": dict(manifest, params=[{"key": "s", "label": "S", "kind": "slider", "min": 1, "max": 0, "default": 2}]), "source": src}),
    "manifest rule: min < max", "min must be below max")
err(c.call("create_custom_scene", {"manifest": dict(manifest, engine={"id": "film9"}), "source": src}), "unknown engine", "isn't installed")
err(c.call("create_custom_scene", {"manifest": manifest, "source": src, "files": {"../evil": "x"}}), "path traversal refused", "allowed file name")
res = c.call("create_custom_scene", {"manifest": manifest, "source": bad})
err(res, "create with errors installs nothing", "doesn't compile")
check(not os.path.isdir(os.path.join(F, "scenes")) or os.listdir(os.path.join(F, "scenes")) == [], "nothing installed")
res = c.call("create_custom_scene", {"manifest": manifest, "source": src})
ok(res, "create_custom_scene")
sid = res["structuredContent"]["id"]
check(sid.startswith("aurora-lake-") and os.path.exists(os.path.join(F, "scenes", sid, "scene.metal")), f"installed as {sid}")
check(not os.listdir(os.path.join(F, ".staging")), "staging cleaned up")
err(c.call("create_custom_scene", {"manifest": dict(manifest, id=sid), "source": src}), "create with an existing id", "update_custom_scene")
ok(c.call("update_custom_scene", {"id": sid, "source": src.replace("0.2", "0.3")}), "update_custom_scene")
check("0.3" in open(os.path.join(F, "scenes", sid, "scene.metal")).read(), "updated source installed")
err(c.call("update_custom_scene", {"id": sid, "source": bad}), "bad update keeps the old one", "doesn't compile")
check("0.3" in open(os.path.join(F, "scenes", sid, "scene.metal")).read(), "…old source still installed")
ok(c.call("validate_custom_scene", {"id": sid}), "validate installed scene")
check([s["id"] for s in c.call("list_custom_scenes")["structuredContent"]["scenes"]] == [sid], "list_custom_scenes")
res = c.call("create_style", {"name": "Lake", "effects": [{"kind": "custom", "scene": sid, "params": {"speed": 0.2, "mood": "Vivid"}}]})
ok(res, "create_style with a custom scene")
raw = next(p for p in library(F)["presets"] if p["name"] == "Lake")
check(raw["effects"][0]["kind"] == "custom" and raw["effects"][0]["custom"]["id"] == sid and raw["effects"][0]["params"]["mood"] == 1
      and raw["effects"][0]["params"]["stars"] == 1 and raw["effects"][0]["colorA"]["b"] == 0.1, "custom effect stored per contract §1")
err(c.call("create_style", {"name": "Lake", "effects": [{"kind": "custom", "scene": sid, "params": {"speed": 3}}]}), "custom param range", "outside")
err(c.call("create_style", {"name": "Lake", "effects": [{"kind": "custom", "scene": "nope-12345678"}]}), "unknown custom scene", "no installed")
# film
err(c.call("render_film_stills", {"draft": "film-00000000"}), "stills for a missing draft", "no film draft")
nb = Client(F, DOTSTUDIO_MCP_TEST_FAKES=1, DOTSTUDIO_MCP_FAKE_BLENDER="none")
nb.init()
st = nb.call("film_status")
check(st["structuredContent"]["blenderReady"] is False and "blender.org" in st["structuredContent"]["installAdvice"]
      and "never installs" in text(st), "no Blender → install steps for the user, never installs it")
nb.close()
check(c.call("film_status")["structuredContent"]["blenderReady"] is True, "fake Blender 5.1 is ready")
res = c.call("list_film_templates")
ok(res, "list_film_templates")
check(res["structuredContent"]["templates"][0]["id"] == "commute", "Commute is the first template")
err(c.call("create_film_scene", {"template": "nope"}), "unknown template", "list_film_templates")
err(c.call("create_film_scene", {}), "template or spec needed", "template")
err(c.call("create_film_scene", {"template": "commute", "look": {"halation": 3}}), "look out of range", "maximum")
res = c.call("create_film_scene", {"template": "commute", "name": "Rainy Commute", "variants": ["night", "rain"],
                                   "params": {"sway": 0.6}, "look": {"halation": 0.3, "grain": 0.25}})
ok(res, "create_film_scene from a template with a look")
draft = res["structuredContent"]["draft"]
spec = res["structuredContent"]["spec"]
check(spec["look"] == {"bloom": 0.25, "halation": 0.3, "grain": 0.25} and spec["params"]["sway"] == 0.6
      and spec["params"]["penguin_color"] == [0.0, 0.30, 0.47] and spec["variants"] == ["night", "rain"], "look + params merged into the template spec")
res = c.call("update_film_scene", {"draft": draft, "look": {"bloom": 0.1}, "spec_patch": {"render": {"samples": 128}}, "loop_seconds": 24})
ok(res, "update_film_scene")
sp = c.call("get_film_scene", {"draft": draft})["structuredContent"]["spec"]
check(sp["look"]["bloom"] == 0.1 and sp["look"]["halation"] == 0.3 and sp["render"]["samples"] == 128 and sp["render"]["engine"] == "cycles"
      and sp["loop"] == {"seconds": 24, "fps": 24}, "get_film_scene: edits deep-merged")
err(c.call("create_film_scene", {"spec": {"scene": "warehouse"}}), "spec for a scene the toolkit lacks", "no scene module")
before = set(os.listdir(os.path.join(F, "film")))
err(c.call("create_film_scene", {"spec": {"scene": "local"}, "scene_files": {"scene.py": "ASSETS = []\n"}}), "new set without build(ctx)", "build(ctx)")
err(c.call("create_film_scene", {"spec": {"scene": "local"}, "scene_files": {"scene.py": "x", "../evil.py": "x"}}), "scene file names checked", "isn't allowed")
check(set(os.listdir(os.path.join(F, "film"))) == before, "failed drafts leave nothing behind")
res = c.call("create_film_scene", {"spec": {"scene": "local", "loop": {"seconds": 24, "fps": 24}}, "name": "Café",
                                   "scene_files": {"scene.py": "ASSETS = ['ph:hdri:x']\nVARIANTS = ['night']\nCAMERAS = ['wide']\ndef build(ctx):\n    return {'cameras': {}}\n",
                                                   "assets.json": "{}"}})
ok(res, "create_film_scene with a new set (scene_files)")
check(os.path.exists(os.path.join(res["structuredContent"]["spec"]["scene_dir"], "scene.py")), "scene module stored in the draft")
err(c.call("render_film_stills", {"draft": draft}), "stills need the film engine", "pull")
ok(c.call("pull_engine", {"id": "film"}), "pull_engine film")
check(c.call("film_status")["structuredContent"]["toolkitPulled"] is True, "film_status sees the toolkit")
t0 = time.time()
res = c.call("render_film_stills", {"draft": draft, "wait_seconds": 30})
ok(res, "render_film_stills (the draft's own variants)")
imgs = [cc for cc in res["content"] if cc["type"] == "image"]
check(res["structuredContent"]["state"] == "done" and len(imgs) == 2 and png_ok(base64.b64decode(imgs[0]["data"]))[0], "stills returned as PNG images")
res = c.call("render_film_loop", {"draft": draft, "variants": ["day", "night"], "seconds": 8})
ok(res, "render_film_loop returns at once")
job = res["structuredContent"]["job"]
# the job must outlive the server
c.p.kill()
c.p.wait()
time.sleep(3.5)
c = Client(F, DOTSTUDIO_MCP_TEST_FAKES=1)
c.init()
res = c.call("film_job_status", {"job": job})
ok(res, "film_job_status after the server died")
check(res["structuredContent"]["state"] == "done" and res["structuredContent"].get("scene", "").startswith(draft), "loop finished without the server and installed a film scene")
fscene = res["structuredContent"].get("scene", "")
check(os.path.exists(os.path.join(F, "scenes", fscene, "clips", "night.mov")), "film package has its clips")
man = json.load(open(os.path.join(F, "scenes", fscene, "scene.json")))
check(man["engine"]["id"] == "film" and man["look"]["grain"] == 0.25 and man["look"]["bloom"] == 0.1 and "entry" not in man
      and {c_["variant"] for c_ in man["clips"]} == {"day", "night"}, "film package: the film engine's format, carrying the look")
res = c.call("create_style", {"name": "Rainy Commute", "effects": [{"kind": "custom", "scene": fscene}]})
ok(res, "create_style with the film scene")
check(res["structuredContent"]["style"]["effects"][0]["params"].get("ds.grain") == 0.25, "the package's grain is the style's starting Grain (ds.grain)")
ok(c.call("create_style", {"name": "Rainy Commute B", "effects": [{"kind": "custom", "scene": fscene, "params": {"ds.grain": 0.15}}]}), "the film engine's Grain is a style param")
check(job in [j["id"] for j in c.call("film_job_status")["structuredContent"]["jobs"]], "film_job_status lists jobs")
c.close()
c = Client(F, DOTSTUDIO_MCP_TEST_FAKES=1, DOTSTUDIO_MCP_FAKE_RENDER_SECONDS=60)
c.init()
res = c.call("render_film_loop", {"draft": draft})
job2 = res["structuredContent"]["job"]
time.sleep(1.5)
st = c.call("film_job_status", {"job": job2})["structuredContent"]
check(st["state"] == "running" and 0 <= st["progress"].get("fraction", -1) < 1 and "%" in st["logTail"], "running job reports progress + log tail")
pid = int(open(os.path.join(F, "jobs", job2, "pid")).read())
ok(c.call("cancel_film_job", {"job": job2}), "cancel_film_job")
time.sleep(1)
alive = True
try:
    os.kill(pid, 0)
except ProcessLookupError:
    alive = False
check(not alive, "cancelled render process is gone")
check(c.call("film_job_status", {"job": job2})["structuredContent"]["state"] == "cancelled", "job state cancelled")
err(c.call("film_job_status", {"job": "nope"}), "unknown job", "no film job")
c.close()

# ---------------------------------------------------------------- custom scenes end to end: the real engines
print("== custom scenes end to end (the real engines, a local engines index)")
E = new_store()
idx = tempfile.mkdtemp(prefix="dsidx-")
subprocess.run([os.path.join(ROOT, "tools", "engines", "build-index.sh"), idx], check=True, capture_output=True)
c = Client(E, DOTSTUDIO_MCP_TEST_FAKES="film", DOTSTUDIO_ENGINES_INDEX=os.path.join(idx, "engines-index.json"),
           DOTSTUDIO_MCP_FAKE_RENDER_SECONDS=1)
c.init()
res = c.call("list_engines", {"include_available": True})
ok(res, "list_engines with a local index")
check("shadertoy" in [e["id"] for e in res["structuredContent"]["available"]], "the index offers shadertoy")
err(c.call("pull_engine", {"id": "metal"}), "a built-in engine isn't pulled", "built in")
err(c.call("pull_engine", {"id": "nope"}), "an engine the index lacks", "no engine")
ok(c.call("pull_engine", {"id": "shadertoy"}), "pull_engine shadertoy (index, size + sha256, install)")
check(os.path.exists(os.path.join(E, "engines", "shadertoy", "1", "engine.json")), "pulled into <store>/engines/shadertoy/1")


def same_guide(gid, path):
    return text(c.call("read_guide", {"id": gid})).strip() == open(path).read().strip()


for eid in ("metal", "cells", "film"):
    check(same_guide(f"engines/{eid}", os.path.join(ROOT, "Shared", "Engines", eid, "1", "guide.md")),
          f"read_guide engines/{eid} is the engine's own guide.md (one source)")
check(same_guide("engines/shadertoy", os.path.join(ROOT, "tools", "engines", "shadertoy", "1", "guide.md")),
      "read_guide engines/shadertoy is the pulled engine's guide")
check(same_guide("film", os.path.join(ROOT, "Guides", "film.md")), "read_guide film: the toolkit's flow")

# a metal scene: colour A on the left half, colour B on the right, a slow band (lines numbered for the errors below)
panes_src = ("#include <DotStudio.h>\n"
             "// Two panes and a band.\n"
             "float4 dsScene(float2 uv, DSContext ctx) {\n"
             "    float band = 0.5 + 0.5 * sin(uv.y * 12.0 + ctx.t * ctx.p[0]);\n"
             "    float3 c = uv.x < 0.5 ? ctx.colorA : ctx.colorB;\n"
             "    return float4(c * (0.75 + 0.25 * band), 1.0);\n"
             "}\n")
panes = {"name": "Test Panes", "engine": {"id": "metal", "version": ">=1"}, "fps": 30,
         "params": [{"key": "speed", "label": "Speed", "kind": "slider", "min": 0, "max": 2, "default": 0.5}],
         "colors": {"a": {"label": "Left", "default": [0.8, 0.2, 0.1, 1]}, "b": {"label": "Right", "default": [0.1, 0.25, 0.8, 1]}}}
# compile errors come back with the entry's own line numbers and an excerpt
bad = panes_src.replace("ctx.colorB;", "ctx.colourB;")
res = c.call("create_custom_scene", {"manifest": panes, "source": bad})
err(res, "a compile error installs nothing", "doesn't compile")
d0 = (res["structuredContent"]["diagnostics"] or [{}])[0]
check(d0.get("line") == 5 and d0.get("severity") == "error" and "file" not in d0 and ">   5 |" in text(res) and "colourB" in text(res),
      f"the error is on line 5 of the entry, with the source line (got {d0})")
check(not os.path.isdir(os.path.join(E, "scenes")) or os.listdir(os.path.join(E, "scenes")) == [], "nothing installed after the error")
res = c.call("validate_custom_scene", {"manifest": panes, "source": bad.replace("float band", "float bnad", 1)})
lines_ = sorted(d["line"] for d in res["structuredContent"]["diagnostics"] if d["severity"] == "error")
check(res.get("isError") and 5 in lines_ and 6 in lines_, f"two errors, lines 5 and 6 ({lines_})")
res = c.call("create_custom_scene", {"manifest": panes, "source": panes_src})
ok(res, "create_custom_scene (metal): compiled and installed")
panes_id = res["structuredContent"].get("id", "")
check(res["structuredContent"].get("gpuMsAt5K", 0) > 0, "with its GPU cost at 5K")
ok(c.call("validate_custom_scene", {"id": panes_id}), "validate the installed metal scene")
# a cells scene: a disc of colour B, coverage in alpha
dot_src = ("#include <DotStudio.h>\n"
           "float4 dsScene(float2 uv, DSContext ctx) {\n"
           "    float d = dsSdCircle(dsCentered(uv, ctx), 0.32);\n"
           "    return float4(ctx.colorB, dsFill(d, 0.02));\n"
           "}\n")
res = c.call("create_custom_scene", {"manifest": {"name": "Test Dot", "engine": {"id": "cells"}, "fps": 24,
                                                  "colors": {"a": {"label": "Sky", "default": [0.02, 0.02, 0.04, 1]},
                                                             "b": {"label": "Dot", "default": [1.0, 0.55, 0.2, 1]}}},
                                     "source": dot_src})
ok(res, "create_custom_scene (cells)")
dot_id = res["structuredContent"].get("id", "")
# a Shadertoy port through the pulled engine
st_src = ("void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n"
          "    vec2 uv = fragCoord / iResolution.xy;\n"
          "    fragColor = vec4(uv.x, 0.15, 1.0 - uv.x, 1.0);\n"
          "}\n")
res = c.call("create_custom_scene", {"manifest": {"name": "Test Port", "engine": {"id": "shadertoy"}}, "source": st_src})
ok(res, "create_custom_scene (shadertoy GLSL)")
port_id = res["structuredContent"].get("id", "")
check(os.path.exists(os.path.join(E, "scenes", port_id, "scene.glsl")), "the GLSL entry is scene.glsl")
check(sorted(s["id"] for s in c.call("list_custom_scenes")["structuredContent"]["scenes"]) == sorted([panes_id, dot_id, port_id]),
      "list_custom_scenes lists all three")

# styles, through the engine's own helpers (EffectInstance.customScene)
res = c.call("create_style", {"name": "Panes", "effects": [{"kind": "custom", "scene": panes_id, "params": {"speed": 1.5}}], "fps": 30})
ok(res, "create_style with the metal scene")
panes_style = res["structuredContent"]["id"]
raw = next(p for p in library(E)["presets"] if p["id"] == panes_style)["effects"][0]
check(raw["kind"] == "custom" and raw["custom"]["id"] == panes_id and raw["params"] == {"speed": 1.5}
      and abs(raw["colorA"]["r"] - 0.8) < 1e-6 and abs(raw["colorB"]["b"] - 0.8) < 1e-6, "stored per contract §1 (params by key, colours colorA/B)")
res = c.call("create_style", {"name": "Dot", "effects": [{"kind": "custom", "scene": dot_id, "params": {"ds.render": "Pixels", "ds.cell": 20}}], "fps": 24})
ok(res, "create_style with the cells scene and its engine's params")
dot_style = res["structuredContent"]["id"]
raw = next(p for p in library(E)["presets"] if p["id"] == dot_style)["effects"][0]
check(raw["params"].get("ds.render") == 1 and raw["params"].get("ds.cell") == 20 and raw["params"].get("ds.glow", 0.5) == 0.5,
      "engine params stored by key (menu by name); the rest render at their defaults")
err(c.call("create_style", {"name": "X", "effects": [{"kind": "custom", "scene": dot_id, "params": {"ds.cell": 99}}]}), "engine param range", "outside")
res = c.call("create_style", {"name": "Port", "effects": [{"kind": "custom", "scene": port_id}]})
ok(res, "create_style with the shadertoy scene")
port_style = res["structuredContent"]["id"]

# previews render the scenes' own pipelines (not the calm stand-in): look at the pixels
res = c.call("preview_style", {"style": panes_style, "width": 320, "height": 200, "save_path": os.path.join(OUT, "e2e-panes.png")})
ok(res, "preview_style the metal scene")
px = png_pixels(image(res))
L, R = region_mean(px, 0.05, 0.4, 0.1, 0.9), region_mean(px, 0.6, 0.95, 0.1, 0.9)
check(px[0] == 320 and L[0] > L[2] + 0.3 and R[2] > R[0] + 0.3, f"its PNG is the scene: red left {L}, blue right {R}")
ok(c.call("update_style", {"style": panes_style, "patch": [{"index": 0, "colorA": {"r": 0.1, "g": 0.75, "b": 0.2}}]}), "update_style a custom effect's colour")
raw = next(p for p in library(E)["presets"] if p["id"] == panes_style)["effects"][0]
check(raw["custom"]["id"] == panes_id and raw["params"] == {"speed": 1.5}, "the patch keeps the package and params")
L2 = region_mean(png_pixels(image(c.call("preview_style", {"style": panes_style, "width": 320, "height": 200}))), 0.05, 0.4, 0.1, 0.9)
check(L2[1] > L2[0] + 0.3, f"…and the preview follows it (green left {L2})")
res = c.call("preview_style", {"style": dot_style, "width": 320, "height": 200, "save_path": os.path.join(OUT, "e2e-dot.png")})
ok(res, "preview_style the cells scene")
px = png_pixels(image(res))
mid, corner = region_mean(px, 0.45, 0.55, 0.4, 0.6), region_mean(px, 0.0, 0.1, 0.0, 0.15)
check(mid[0] > 0.35 and mid[0] > mid[2] + 0.2 and corner[0] < 0.15, f"an orange disc of cells on a dark sky (centre {mid}, corner {corner})")
dots = image(c.call("preview_style", {"draft": {"effects": [{"kind": "custom", "scene": dot_id, "params": {"ds.render": "Dots", "ds.cell": 20}}]},
                                       "width": 320, "height": 200}))
check(dots != image(res), "Render = Dots draws differently from Pixels")
px = png_pixels(image(c.call("preview_style", {"style": port_style, "width": 320, "height": 200, "save_path": os.path.join(OUT, "e2e-port.png")})))
L, R = region_mean(px, 0.0, 0.15, 0.2, 0.8), region_mean(px, 0.85, 1.0, 0.2, 0.8)
check(L[2] > L[0] + 0.5 and R[0] > R[2] + 0.5, f"the GLSL port renders (blue left {L}, red right {R})")
for sid_, name_ in ((panes_style, "metal"), (dot_style, "cells")):
    res = c.call("benchmark_style", {"style": sid_})
    ok(res, f"benchmark_style the {name_} scene")
    check(0 < res["structuredContent"].get("minMs", 0) < 100, f"…{res['structuredContent'].get('minMs', 0):.2f} ms at 5K")
ok(c.call("set_screensaver", {"style": panes_style}), "set_screensaver to the custom style (temp store)")
check(library(E)["activeID"] == panes_style, "the screensaver plays it")

# film: the toolkit's stand-in renders real H.264 loops; they install and play through the real film engine
res = c.call("film_status")
check(res["structuredContent"]["available"] is True and res["structuredContent"]["toolkitPulled"] is True, "film_status: the stand-in toolkit, installed")
res = c.call("create_film_scene", {"template": "commute", "name": "Test Commute", "variants": ["day", "night"], "look": {"grain": 0.3}})
ok(res, "create_film_scene")
fdraft = res["structuredContent"]["draft"]
fjob = c.call("render_film_loop", {"draft": fdraft, "seconds": 8})["structuredContent"]["job"]
deadline = time.time() + 90
st = {}
while time.time() < deadline:
    st = c.call("film_job_status", {"job": fjob})["structuredContent"]
    if st["state"] != "running" and ("scene" in st or "packageError" in st or st["state"] != "done"):
        break
    time.sleep(1)
check(st.get("state") == "done" and "scene" in st, f"the loop finished, packaged and installed ({st.get('state')}, {st.get('packageError', '')})")
fscene = st.get("scene", "")
res = c.call("validate_custom_scene", {"id": fscene})
ok(res, "the film package validates in the real engine (playable clips)")
res = c.call("create_style", {"name": "Commute", "effects": [{"kind": "custom", "scene": fscene}], "fps": 24})
ok(res, "create_style with the film scene")
film_style = res["structuredContent"]["id"]
fp = res["structuredContent"]["style"]["effects"][0]["params"]
check(fp.get("ds.grain") == 0.3 and fp.get("ds.halation") == 0, f"its look: grain → ds.grain, halation baked → 0 ({fp})")
day = c.call("preview_style", {"style": film_style, "clock": "13:00", "date": "2026-06-21", "width": 320, "height": 200,
                               "save_path": os.path.join(OUT, "e2e-film-day.png")})
night = c.call("preview_style", {"style": film_style, "clock": "01:00", "date": "2026-06-21", "width": 320, "height": 200})
ok(day, "preview_style the film scene")
check(day["structuredContent"]["meanLuminance"] > night["structuredContent"]["meanLuminance"] + 0.15,
      f"day plays the day clip, night the night clip ({day['structuredContent']['meanLuminance']} vs {night['structuredContent']['meanLuminance']})")
res = c.call("benchmark_style", {"style": film_style})
ok(res, "benchmark_style the film scene")
c.close()
shutil.rmtree(idx, ignore_errors=True)

# ---------------------------------------------------------------- the running app
print("== routing through a running app (stand-in that clobbers direct writes)")
A = new_store()
app = subprocess.Popen([BIN, "--fake-app", "--clobber-ms", "150"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                       stderr=subprocess.DEVNULL, env=env_for(A))
check(app.stdout.readline().strip() == b"ready", "stand-in app ready")
applied = []
threading.Thread(target=lambda: [applied.append(l.decode().strip()) for l in app.stdout], daemon=True).start()
c = Client(A)
c.init()
check(c.call("get_started")["structuredContent"]["appRunning"] is True, "get_started sees the app")
res = c.call("create_style", {"name": "Via App", "effects": [{"kind": "silk"}]})
ok(res, "create_style while the app runs")
check(res["structuredContent"]["liveInApp"] is True, "routed through the app")
time.sleep(0.6)  # several clobber saves
check("Via App" in names(A), "survives the app's own saves")
ok(c.call("set_screensaver", {"style": "Via App"}), "set_screensaver via the app")
time.sleep(0.4)
check(library(A)["activeID"] == res["structuredContent"]["id"], "lineup change survives")
check(any("applied upsertStyle ok=true client=Claude" in l for l in applied), "the app saw the request, with the client's name")
# A direct write behind the app's back is what the bridge prevents: prove the stand-in clobbers.
lib = library(A)
lib["presets"][0]["name"] = "Sneaky Direct Write"
with open(os.path.join(A, "library.json"), "w") as f:
    json.dump(lib, f)
time.sleep(0.5)
check("Sneaky Direct Write" not in names(A), "control: a direct write is clobbered by the running app")
# crash: stale socket → the server falls back to the files
app.send_signal(signal.SIGKILL)
app.wait()
check(os.path.exists(os.path.join(A, ".ai-bridge.sock")), "stale socket left by the crash")
res = c.call("create_style", {"name": "After Crash", "effects": [{"kind": "silk"}]})
ok(res, "create_style after the app crashed")
check(res["structuredContent"]["liveInApp"] is False and "After Crash" in names(A), "stale socket → direct write")
# app launching (holding the lock while it loads): the server waits, then routes through it
app = subprocess.Popen([BIN, "--fake-app", "--hold-lock-ms", "1500", "--clobber-ms", "100"], stdin=subprocess.PIPE,
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env_for(A))
check(app.stdout.readline().strip() == b"holding lock", "stand-in app launching (lock held)")
t0 = time.time()
res = c.call("create_style", {"name": "During Launch", "effects": [{"kind": "silk"}]})
waited = time.time() - t0
ok(res, "create_style during the app's launch")
check(waited > 1.0 and res["structuredContent"]["liveInApp"] is True, f"waited for the lock ({waited:.1f} s), then went through the app")
time.sleep(0.4)
check("During Launch" in names(A) and "After Crash" in names(A), "nothing lost across the launch")
app.stdin.close()
app.wait(5)
check(not os.path.exists(os.path.join(A, ".ai-bridge.sock")), "clean quit removes the socket")
c.close()

print("== parallel servers (offline)")
P = new_store()
first = Client(P)
first.init()
first.call("list_styles")  # creates nothing; library missing → default
first.close()
def burst(tag):
    cl = Client(P)
    cl.init()
    for i in range(8):
        cl.call("create_style", {"name": f"{tag} {i}", "effects": [{"kind": "silk"}]})
    cl.close()
ts = [threading.Thread(target=burst, args=(t,)) for t in ("Alpha", "Beta", "Gamma")]
[t.start() for t in ts]
[t.join() for t in ts]
n = names(P)
check(all(f"{t} {i}" in n for t in ("Alpha", "Beta", "Gamma") for i in range(8)), "3 servers × 8 creates: none lost")
check(len(json.load(open(os.path.join(P, "ai-created.json")))["ids"]) == 24, "all 24 recorded as the AI's")

# ---------------------------------------------------------------- Claude Desktop config (temp file only)
print("== Claude Desktop config merge")
tmp = tempfile.mkdtemp()
cfg = os.path.join(tmp, "claude_desktop_config.json")
with open(cfg, "w") as f:
    json.dump({"mcpServers": {"other": {"command": "/usr/bin/other", "args": ["x"]}}, "globalShortcut": "Cmd+Space"}, f)
r = subprocess.run([BIN, "--install-claude-desktop", "--config", cfg], capture_output=True, text=True, env=env_for(S))
check(r.returncode == 0 and "added" in r.stdout, "merge into an existing config")
j = json.load(open(cfg))
check(j["mcpServers"]["other"]["args"] == ["x"] and j["globalShortcut"] == "Cmd+Space", "other servers and settings kept")
check(j["mcpServers"]["dotstudio"]["command"] == os.path.realpath(BIN), "dotstudio entry points at the helper")
check(any(x.startswith("claude_desktop_config.json.dotstudio-backup-") for x in os.listdir(tmp)), "backup made")
r = subprocess.run([BIN, "--install-claude-desktop", "--config", cfg], capture_output=True, text=True, env=env_for(S))
check("unchanged" in r.stdout, "second run: unchanged")
with open(cfg, "w") as f:
    f.write("{ broken")
r = subprocess.run([BIN, "--install-claude-desktop", "--config", cfg], capture_output=True, text=True, env=env_for(S))
check(r.returncode != 0 and open(cfg).read() == "{ broken", "invalid JSON is never overwritten")
fresh = os.path.join(tmp, "new", "claude_desktop_config.json")
r = subprocess.run([BIN, "--install-claude-desktop", "--config", fresh], capture_output=True, text=True, env=env_for(S))
check(r.returncode == 0 and "dotstudio" in json.load(open(fresh))["mcpServers"], "missing config created")
shutil.rmtree(tmp)

# ---------------------------------------------------------------- generated guides drift
print("== settings guides drift")
tmp = tempfile.mkdtemp()
subprocess.run([BIN, "--write-settings-guides", tmp], check=True, capture_output=True, env=env_for(S))
repo = os.path.join(ROOT, "Guides", "settings")
gen = sorted(os.listdir(tmp))
stale = [f for f in gen if not os.path.exists(os.path.join(repo, f)) or open(os.path.join(repo, f)).read() != open(os.path.join(tmp, f)).read()]
extra = [f for f in os.listdir(repo) if f not in gen and f != "app.md"]
check(not stale and not extra, "Guides/settings matches this build" + ("" if not stale and not extra else
      f" — regenerate with tools/guides/generate.sh (stale {stale[:5]}, extra {extra[:5]})"))
shutil.rmtree(tmp)

for d in (S, F, E, A, P):
    shutil.rmtree(d, ignore_errors=True)
print()
print(f"{CHECKS - len(FAILS)}/{CHECKS} checks passed")
print("mcp selftest: " + ("PASS" if not FAILS else f"{len(FAILS)} FAILED"))
sys.exit(1 if FAILS else 0)
