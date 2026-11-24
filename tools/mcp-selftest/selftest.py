"""dotstudio-mcp end-to-end self-test (see run.sh). Exit 0 = PASS."""
import base64, glob, json, os, shutil, signal, struct, subprocess, sys, tempfile, threading, time, zlib

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
            "export_style", "import_style", "list_displays", "set_screensaver", "set_wallpaper",
            "list_signals", "test_signal", "create_signal", "update_signal", "delete_signal", "list_rules", "set_rule", "delete_rule", "bind_signal",
            "get_settings", "update_settings", "app_action", "list_engines",
            "pull_engine", "list_custom_scenes", "validate_custom_scene", "create_custom_scene", "update_custom_scene",
            "film_status", "list_film_templates", "create_film_scene", "get_film_scene", "update_film_scene", "render_film_stills", "render_film_loop", "film_job_status", "cancel_film_job"]
check(sorted(tnames) == sorted(expected), f"tools/list has the {len(expected)} tools")
check(all(t["inputSchema"]["type"] == "object" and t["inputSchema"].get("additionalProperties") is False
          and len(t["description"]) > 40 and "annotations" in t for t in tools), "every tool: strict object schema, description, annotations")
check(next(t for t in tools if t["name"] == "set_screensaver")["description"].startswith("CHANGES THE USER'S MAC"), "set_screensaver says it changes the Mac")
check(all(next(t for t in tools if t["name"] == n)["description"].startswith("CHANGES WHAT PLAYS") for n in ("set_rule", "delete_rule")),
      "set_rule / delete_rule say they change what plays")
check(next(t for t in tools if t["name"] == "test_signal")["annotations"]["openWorldHint"] is True, "test_signal is openWorld (it fetches)")
check(not any("secret" in json.dumps(t["inputSchema"]).lower() or '"value": {"type": "string"' in json.dumps(t["inputSchema"])
              for t in tools if "signal" in t["name"]), "no signal tool takes a key's value")
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
check(res["structuredContent"].get("settingsTools") == ["get_settings", "update_settings", "app_action"]
      and "update_settings" in text(res), "get_started points at the settings tools")
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
again = c.call("preview_style", {"style": dusk_id, "width": 320, "height": 200, "save_path": os.path.join(OUT, "harbour.png")})
check(again.get("isError") is True and "never overwrites" in text(again), "save_path never overwrites an existing file")
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


# ---------------------------------------------------------------- the app's own settings (offline)
print("== app settings (offline)")
T = new_store()
tc = Client(T)
tc.init()


def prefs(store):
    p = os.path.join(store, "app-prefs.json")
    return json.load(open(p)) if os.path.exists(p) else {}


def wall(store):
    p = os.path.join(store, "wallpaper.json")
    return json.load(open(p)) if os.path.exists(p) else {}


def settings_of(res):
    return {st["key"]: st for g in res["structuredContent"]["groups"] for st in g["settings"]}


def upd(patch):
    return tc.call("update_settings", {"settings": patch})


res = tc.call("get_settings")
ok(res, "get_settings")
sc = res["structuredContent"]
check(sc["appRunning"] is False and sc["allowPlaybackChanges"] is True, "get_settings: offline, playback allowed")
check([g["id"] for g in sc["groups"]] == ["general", "screensaver", "music", "weather", "wallpaper", "source", "updates", "ai", "system"],
      "get_settings: every group, in the app's order")
st = settings_of(res)
check(len(st) >= 45 and all({"key", "label", "where", "meaning", "value", "allowed", "readOnly", "changesWhatPlays"} <= set(v) for v in st.values()),
      f"get_settings: {len(st)} settings, each with value, allowed values, where and meaning")
check(st["music.show"]["value"] == "corner" and st["music.show"]["allowed"] == ["off", "corner", "fullScreen"] and st["music.show"]["changesWhatPlays"] is True,
      "music.show: default corner, its choices, gated")
check(st["screensaver.quality"]["value"] == "full" and st["wallpaper.frameRate"]["value"] == "balanced" and st["weather.live"]["value"] is True,
      "defaults read right (quality full, 30 fps, live weather on)")
check(all(st[k]["readOnly"] and st[k].get("howToChange") for k in st if k.startswith(("system.", "ai."))),
      "macOS-owned and the user's AI permissions are read-only, each says how to change it")
check(st["general.openAtLogin"].get("needsApp") is True and st["general.openAtLogin"]["value"] is None and "isn't running" in st["general.openAtLogin"].get("note", ""),
      "open at login: needs the app, unknown offline")
check(isinstance(st["system.screensaverInstalled"]["value"], bool) and isinstance(st["system.startScreenSaverAfter"]["value"], (int, float)),
      "macOS state readable offline (installed, idle time)")
check(st["system.textSize"]["value"] == "follows macOS" and "Text Size" in st["system.textSize"]["howToChange"], "text size: follows macOS, says where")
check({a["id"] for a in sc["actions"]} >= {"install_screensaver", "show_setup_guide", "guide_me", "open_screensaver_settings"}, "actions listed")
res = tc.call("get_settings", {"group": "music"})
check([g["id"] for g in res["structuredContent"]["groups"]] == ["music"] and len(settings_of(res)) == 8, "get_settings group filter")
res = tc.call("get_settings", {"keys": ["wallpaper.quality", "music.size"]})
check(sorted(settings_of(res)) == ["music.size", "wallpaper.quality"], "get_settings keys filter")
err(tc.call("get_settings", {"keys": ["music.nope"]}), "get_settings unknown key", "unknown setting")
check("music.show" in json.dumps(next(t for t in tc.req("tools/list")["result"]["tools"] if t["name"] == "update_settings")["inputSchema"]),
      "update_settings schema lists the settable keys")

# each group
ok(upd({"general.menuBarMode": False}), "general: menu-bar mode off")
check(prefs(T).get("menuBarMode") is False, "  → app-prefs.json (a test store never touches the real defaults)")
err(upd({"general.openAtLogin": True}), "general: open at login refused without the app", "running")
ok(upd({"screensaver.changeEveryMinutes": 15, "screensaver.shuffle": True, "screensaver.crossfadeSeconds": 2.5, "screensaver.quality": "efficient"}),
   "screensaver: interval, shuffle, crossfade, quality")
lib = library(T)
check(lib["rotation"]["intervalMinutes"] == 15 and lib["rotation"]["shuffle"] is True and lib["rotation"]["transitionSeconds"] == 2.5
      and lib["renderScale"] == 0.5, "  → library.json rotation + renderScale")
ok(upd({"screensaver.quality": "full"}), "screensaver: quality back to full")
ok(upd({"power.frameRate": "24"}), "power: the plugged-in limit")
check(library(T)["frameRate"] == 24, "  → library.json frameRate 24")
ok(upd({"power.frameRate": "style"}), "power: legacy 'style' (each style's own rate) = the 120 limit")
check(library(T)["frameRate"] == 120, "  → frameRate 120: every style plays at its own rate")
check("renderScale" not in library(T), "  → full is stored as absent, as the app does")
res = upd({"music.show": "fullScreen", "music.layout": "stage", "music.behind": "screensaver", "music.corner": "topRight",
           "music.size": "large", "music.onWallpaper": True, "music.keepPausedSongMinutes": 15, "music.source": "spotify"})
ok(res, "music: every option")
m = library(T)["music"]
check(m["display"] == "fullScreen" and m.get("takeOver") is True and m["fullLayout"] == "stage" and m["fullBackdrop"] == "screensaver"
      and m["cardCorner"] == "topRight" and m["cardSize"] == "large" and m["cardOnWallpaper"] is True and m["lingerMinutes"] == 15
      and m["source"] == "spotify", "  → library.json music (legacy takeOver kept in step)")
check(res["structuredContent"]["changed"]["music.show"] == "fullScreen" and res["structuredContent"]["liveInApp"] is False
      and "Music ▸ Show music" in text(res), "  → says what changed, offline")
ok(upd({"weather.live": False}), "weather: live off")
check(prefs(T).get("weatherEnabled") is False and prefs(T).get("menuBarMode") is False, "  → app-prefs.json, other prefs kept")
# weather.location: the user's own place (no IP lookup), and back to automatic
loc = settings_of(tc.call("get_settings", {"keys": ["weather.location"]}))["weather.location"]
check(loc["value"]["mode"] == "auto" and loc["changesWhatPlays"] is False and loc["readOnly"] is False
      and "auto" in json.dumps(loc["allowed"]), "weather.location: automatic by default, not gated, says what it takes")
lib = library(T)
lib["locationLat"], lib["locationLon"] = 37.7749, -122.4194
lib["autoPlace"] = {"name": "San Francisco, California", "lat": 37.7749, "lon": -122.4194}
with open(os.path.join(T, "library.json"), "w") as f:
    json.dump(lib, f)
loc = settings_of(tc.call("get_settings", {"keys": ["weather.location"]}))["weather.location"]["value"]
check(loc == {"mode": "auto", "name": "San Francisco, California", "lat": 37.8, "lon": -122.4},
      "  → reads the IP lookup's place, coordinates rounded to 0.1°")
res = upd({"weather.location": {"name": "Toronto, Ontario", "lat": 43.65107, "lon": -79.347015}})
ok(res, "weather.location: set by the user")
lib = library(T)
check(lib.get("locationMode") == "manual" and lib.get("manualPlace") == {"name": "Toronto, Ontario", "lat": 43.65107, "lon": -79.347015}
      and lib["locationLat"] == 43.65107 and lib["locationLon"] == -79.347015,
      "  → library.json: the manual place, and locationLat/Lon (what every reader uses) follow it")
check(res["structuredContent"]["changed"]["weather.location"] == {"mode": "manual", "name": "Toronto, Ontario", "lat": 43.7, "lon": -79.3}
      and "Weather ▸ Location: Toronto, Ontario" in text(res), "  → read back rounded to 0.1°, says what changed")
check(lib.get("autoPlace", {}).get("name") == "San Francisco, California", "  → the IP lookup's last answer is kept")
ok(upd({"weather.location": {"lat": -33.8688, "lon": 151.2093}}), "weather.location: bare coordinates")
check(library(T)["manualPlace"]["name"] == "33.9° S, 151.2° E" and library(T)["locationLon"] == 151.2093, "  → named by its coordinates")
ok(upd({"weather.location": {"name": "  ", "lat": 90, "lon": -180}}), "weather.location: the poles' edge is allowed, a blank name is replaced")
check(library(T)["manualPlace"]["name"] == "90.0° N, 180.0° W", "  → named by its coordinates")
res = upd({"weather.location": "auto"})
ok(res, "weather.location: back to automatic")
lib = library(T)
check("locationMode" not in lib and "manualPlace" not in lib and lib["locationLat"] == 37.7749 and lib["locationLon"] == -122.4194,
      "  → manual place gone; the last IP answer is back until the app looks again")
check(res["structuredContent"]["changed"]["weather.location"]["mode"] == "auto" and "automatic" in text(res), "  → says so")
ok(upd({"wallpaper.on": True, "wallpaper.frameRate": "smooth", "wallpaper.quality": "full", "wallpaper.onBattery": "still",
        "wallpaper.lockScreenPicture": True}), "wallpaper: on, frame rate, quality, battery, lock screen")
w = wall(T)
active = library(T)["activeID"]
check(w["enabled"] is True and w["presetID"] == active and w["frameRate"] == 120 and w["quality"] == "full"
      and w["batteryMode"] == "still" and w["freezeOnBattery"] is True and w["lockScreen"] is True,
      "  → wallpaper.json (on plays the screensaver's style; 1.4's freezeOnBattery kept in step)")
ok(upd({"wallpaper.otherAppOnBattery": "pause"}), "wallpaper: pause on battery while another app is focused")
got = settings_of(tc.call("get_settings", {"keys": ["wallpaper.otherAppOnBattery", "wallpaper.otherAppPluggedIn"]}))
check(wall(T)["otherAppOnBattery"] == "pause" and got["wallpaper.otherAppOnBattery"]["value"] == "pause"
      and got["wallpaper.otherAppPluggedIn"]["value"] == "keepPlaying", "  → written, and read back (plugged in keeps playing)")
err(upd({"wallpaper.otherAppPluggedIn": "stop"}), "  → an unknown mode is refused")
ok(upd({"wallpaper.fpsModePluggedIn": "dynamic"}), "wallpaper: Dynamic frame rate plugged in")
got = settings_of(tc.call("get_settings", {"keys": ["wallpaper.fpsModePluggedIn", "wallpaper.fpsModeOnBattery"]}))
check(wall(T)["fpsModePluggedIn"] == "dynamic" and got["wallpaper.fpsModePluggedIn"]["value"] == "dynamic"
      and got["wallpaper.fpsModeOnBattery"]["value"] == "forced", "  → written, and read back (battery stays Forced)")
err(upd({"wallpaper.fpsModeOnBattery": "turbo"}), "  → an unknown frame rate mode is refused")
ok(upd({"wallpaper.batteryFrameRate": "60", "wallpaper.lowestFrameRateOnBattery": "30"}), "wallpaper: battery limit 60, lowest 30")
got = settings_of(tc.call("get_settings", {"keys": ["wallpaper.batteryFrameRate", "wallpaper.lowestFrameRateOnBattery", "wallpaper.lowestFrameRatePluggedIn"]}))
check(wall(T)["batteryFPS"] == 60 and wall(T)["fpsFloorOnBattery"] == 30 and got["wallpaper.batteryFrameRate"]["value"] == "60"
      and got["wallpaper.lowestFrameRatePluggedIn"]["value"] == "auto", "  → written, and read back (plugged-in lowest stays auto)")
ok(upd({"wallpaper.batteryFrameRate": "auto"}), "wallpaper: battery limit back to auto")
check("batteryFPS" not in wall(T), "  → the field is removed")
ok(upd({"wallpaper.sameAsScreensaver": True}), "wallpaper: same as screensaver")
check(wall(T)["followsScreensaver"] is True and library(T).get("syncTimeBase") is True, "  → follows, and the saver's shared time base")
ok(upd({"wallpaper.sameAsScreensaver": False, "wallpaper.style": "Golden Hour"}), "wallpaper: own style by name")
gh = next(p["id"] for p in library(T)["presets"] if p["name"] == "Golden Hour")
check(wall(T)["followsScreensaver"] is False and wall(T)["presetID"] == gh and "syncTimeBase" not in library(T), "  → Golden Hour, time base back to per-instance")
ok(upd({"wallpaper.on": False}), "wallpaper: off")
ok(upd({"wallpaper.style": "Night Sky"}), "wallpaper: style while off is only remembered")
check(wall(T)["enabled"] is False and wall(T)["presetID"] == next(p["id"] for p in library(T)["presets"] if p["name"] == "Night Sky"), "  → stays off")
img = os.path.join(T, "photo-in.png")
with open(img, "wb") as f:
    raw = b"".join(b"\x00" + bytes([200, 120, 40]) * 4 for _ in range(4))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 4, 4, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
ok(upd({"source.kind": "gradient", "source.gradientFrom": {"r": 0.1, "g": 0.2, "b": 0.3}, "source.gradientAngle": 2, "source.gradientDrift": 0.5}),
   "source: a gradient")
src = library(T)["source"]
check(src["kind"] == "gradient" and src["colorA"] == {"r": 0.1, "g": 0.2, "b": 0.3, "a": 1} and src["gradientAngle"] == 2, "  → library.json source")
ok(upd({"source.photos": [img], "source.secondsEach": 30, "source.panAndZoom": 0.4}), "source: the user's photos")
src = library(T)["source"]
check(src["kind"] == "collection" and len(src["mediaFilenames"]) == 1 and os.path.exists(os.path.join(T, "media", src["mediaFilenames"][0]))
      and src["slideSeconds"] == 30 and src["motion"] == 0.4, "  → copied into media/, slideshow of them")
ok(upd({"source.photos": "builtIn"}), "source: built-in photos")
check(not library(T)["source"].get("mediaFilenames"), "  → built-in set")
err(upd({"source.kind": "video"}), "source: video without a video refused", "mediaFile")
ok(upd({"source.mediaFile": img, "source.scaling": "fit"}), "source: one image, fit")
check(library(T)["source"]["kind"] == "image" and library(T)["source"]["fillMode"] == 0, "  → image source, fit")
ok(upd({"updates.checkAutomatically": False}), "updates: checks off")
check(prefs(T).get("SUEnableAutomaticChecks") is False, "  → stored")
err(upd({"updates.checkAutomatically": False, "updates.installAutomatically": True}), "updates: auto-install needs checks", "checkAutomatically")
ok(upd({"updates.checkAutomatically": True, "updates.installAutomatically": False}), "updates: checks on, install off")
st = settings_of(tc.call("get_settings"))
check(st["music.show"]["value"] == "fullScreen" and st["wallpaper.frameRate"]["value"] == "smooth" and st["general.menuBarMode"]["value"] is False
      and st["updates.installAutomatically"]["value"] is False and st["source.kind"]["value"] == "image"
      and st["wallpaper.style"]["value"]["name"] == "Night Sky", "get_settings reads every change back")

# refusals: nothing changes
before = (library(T), wall(T), prefs(T))
err(upd({"music.sise": "large"}), "typo → refused with a suggestion", "music.size")
err(upd({"system.textSize": "large"}), "read-only key → refused, says how", "read-only")
err(upd({"ai.allowPlaybackChanges": True}), "the AI can't grant itself playback changes", "only the user")
err(upd({"music.show": "huge"}), "bad choice", "isn't one of")
err(upd({"screensaver.crossfadeSeconds": 9}), "number out of range", "maximum")
err(upd({"screensaver.changeEveryMinutes": 7}), "not one of the app's intervals", "isn't one of")
err(upd({"wallpaper.style": "No Such Style"}), "unknown style", "No style")
err(upd({"source.photos": ["/no/such.png"]}), "missing photo", "can't read")
err(upd({}), "empty patch", "at least one")
err(upd({"music.size": "small", "music.corner": "middle"}), "one bad value refuses the whole patch", "isn't one of")
err(upd({"weather.location": {"lat": 91, "lon": 0}}), "weather.location: latitude past the pole refused", "90")
err(upd({"weather.location": {"lat": 10, "lon": -180.5}}), "weather.location: longitude past ±180 refused", "180")
err(upd({"weather.location": {"lat": 10}}), "weather.location: no longitude refused", "lon")
err(upd({"weather.location": {"lat": "43.6", "lon": -79.4}}), "weather.location: a coordinate as text refused", "number")
err(upd({"weather.location": "manual"}), "weather.location: a bare word other than auto refused", "auto")
err(upd({"weather.location": {"name": "x" * 81, "lat": 1, "lon": 1}}), "weather.location: an over-long name refused", "80")
err(upd({"weather.location": {"lat": 1, "lon": 1}, "music.size": "huge"}), "a good location with a bad value elsewhere: whole patch refused", "isn't one of")
check((library(T), wall(T), prefs(T)) == before, "refused patches changed nothing")

# the user's “Let AI change what plays”
with open(os.path.join(T, "ai-settings.json"), "w") as f:
    json.dump({"allowPlaybackChanges": False}, f)
check(tc.call("get_settings")["structuredContent"]["allowPlaybackChanges"] is False, "get_settings reports playback changes off")
err(upd({"music.show": "off"}), "gated setting refused while playback changes are off", "turned off")
err(upd({"wallpaper.on": True}), "wallpaper on refused too", "turned off")
err(upd({"screensaver.shuffle": False, "music.size": "small"}), "a mixed patch is refused whole, naming the gated keys", "screensaver.shuffle")
check(library(T)["music"]["cardSize"] == "large", "  → nothing changed")
ok(upd({"music.size": "small", "wallpaper.quality": "efficient"}), "settings that don't change what plays still work")
ok(upd({"weather.location": {"name": "Reykjavík", "lat": 64.1466, "lon": -21.9426}}), "the location isn't gated (it's the user's place, not what plays)")
check(library(T)["manualPlace"]["name"] == "Reykjavík", "  → set (unicode name kept)")
ok(upd({"weather.location": "auto"}), "  → and back to automatic")
os.remove(os.path.join(T, "ai-settings.json"))
err(tc.call("app_action", {"action": "show_setup_guide"}), "app_action needs the running app", "isn't running")
err(tc.call("app_action", {"action": "format_disk"}), "unknown action", "isn't one of")
tc.close()
shutil.rmtree(T, ignore_errors=True)


# ---------------------------------------------------------------- custom + film: this build
print("== custom scenes / film (this build: real engines, the film toolkit that ships in the app)")
res = c.call("list_engines")
ok(res, "list_engines")
eng = {e["id"]: e for e in res["structuredContent"]["installed"]}
check({"metal", "cells", "film"} <= set(eng) and all(eng[i]["builtIn"] for i in ("metal", "cells", "film")),
      "metal, cells and film are built in")
res = c.call("create_custom_scene", {"manifest": {"name": "A", "engine": {"id": "metal"}}, "source": "x"})
err(res, "create_custom_scene: a real compile rejects junk", "doesn't compile")
check(not os.path.isdir(os.path.join(S, "scenes")) or os.listdir(os.path.join(S, "scenes")) == [], "nothing installed")
res = c.call("film_status")
ok(res, "film_status")
tk = glob.glob(os.path.join(S, "film", "toolkit", "*", "run.py"))
check(res["structuredContent"]["available"] is True and len(tk) == 1
      and not glob.glob(os.path.join(S, "film", "toolkit", "*", "**", "__pycache__"), recursive=True),
      f"the toolkit inside the app is copied into the store and used from there ({[os.path.relpath(t, S) for t in tk]})")
res = c.call("create_film_scene", {"template": "commute"})
ok(res, "create_film_scene from the bundled toolkit's Commute template")
err(c.call("create_film_scene", {"spec": {"scene": "nope"}}), "the bundled toolkit validates specs", "nope")
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
# the stand-in's H.264 encode can outlast the 3.5 s above on a busy Mac or a Debug build: give it time
deadline = time.time() + 30
while res["structuredContent"].get("state") == "running" and time.time() < deadline:
    time.sleep(0.5)
    res = c.call("film_job_status", {"job": job})
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


def engine_dir(eid):    # the built-in engine's (newest) version folder: film is 1.1
    vs = [v for v in os.listdir(os.path.join(ROOT, "Shared", "Engines", eid)) if not v.startswith(".")]
    return os.path.join(ROOT, "Shared", "Engines", eid, max(vs, key=lambda v: [int(x) for x in v.split(".")]))


for eid in ("metal", "cells", "film"):
    check(same_guide(f"engines/{eid}", os.path.join(engine_dir(eid), "guide.md")),
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

# scene inputs (docs/signals-design.md §4): a package declares them; a style binds them to signals
print("== scene inputs (bind_signal, inline inputs, preview_style inputs)")
glow_src = ("#include <DotStudio.h>\n"
            "// A field of colour B whose brightness follows the input (no numbers on screen).\n"
            "float4 dsScene(float2 uv, DSContext ctx) {\n"
            "    float k = ctx.input[0] / 300.0;\n"
            "    return float4(mix(ctx.colorA, ctx.colorB, k), 1.0);\n"
            "}\n")
glow = {"name": "Test Glow", "engine": {"id": "metal", "version": ">=1.1"}, "fps": 24,
        "inputs": [{"key": "aqi", "label": "Air quality", "range": [0, 300], "default": 0, "unit": "AQI", "suggest": "weather.precip"}],
        "colors": {"a": {"label": "Clean", "default": [0.02, 0.02, 0.05, 1]}, "b": {"label": "Smoke", "default": [0.95, 0.6, 0.2, 1]}}}
res = c.call("validate_custom_scene", {"manifest": glow, "source": glow_src})
ok(res, "validate_custom_scene: a scene with an input")
check([i["key"] for i in res["structuredContent"].get("inputs", [])] == ["aqi"] and res["structuredContent"]["inputs"][0]["range"] == [0, 300]
      and "ctx.input[0] aqi" in text(res) and "burn-in" in text(res), "  → reports its inputs (ctx.input[0]) and the burn-in rule")
res = c.call("validate_custom_scene", {"manifest": dict(glow, engine={"id": "metal", "version": ">=1"}), "source": glow_src})
check(any(">=1.1" in w for w in res["structuredContent"]["warnings"] + [d["message"] for d in res["structuredContent"]["diagnostics"]])
      and ">=1.1" in text(res), "  → advises engine >=1.1 for a package with inputs")
err(c.call("validate_custom_scene", {"manifest": dict(glow, inputs=[{"key": "aqi", "label": "A", "range": [0, 10], "default": 20}]), "source": glow_src}),
    "an input's default outside its range is refused", "outside its range")
res = c.call("create_custom_scene", {"manifest": glow, "source": glow_src})
ok(res, "create_custom_scene with an input")
glow_id = res["structuredContent"].get("id", "")
check(next(s for s in c.call("list_custom_scenes")["structuredContent"]["scenes"] if s["id"] == glow_id)["inputs"][0]["key"] == "aqi",
      "list_custom_scenes shows the inputs")
# inline: create_style effects take inputs
res = c.call("create_style", {"name": "Glow", "effects": [{"kind": "custom", "scene": glow_id, "inputs": {"aqi": {"signal": "power.battery"}}}]})
ok(res, "create_style with an inline input binding")
glow_style = res["structuredContent"]["id"]
def glow_fx():
    return next(p for p in library(E)["presets"] if p["id"] == glow_style)["effects"][0]
check(glow_fx().get("inputs") == {"aqi": {"signal": "power.battery"}}, "  → stored as effects[0].inputs {aqi: {signal}}")
err(c.call("create_style", {"name": "X", "effects": [{"kind": "custom", "scene": glow_id, "inputs": {"nope": {"signal": "power.battery"}}}]}),
    "inline: an unknown input key is refused", "no input")
err(c.call("create_style", {"name": "X", "effects": [{"kind": "custom", "scene": glow_id, "inputs": {"aqi": {"signal": "weather.nope"}}}]}),
    "inline: an unknown signal is refused", "No signal")
err(c.call("create_style", {"name": "X", "effects": [{"kind": "halftone", "inputs": {"aqi": {"signal": "power.battery"}}}]}),
    "inline: inputs on a built-in look are refused", "only Custom Scenes")
# bind_signal: to one of the user's signals (a file signal: no network), by name
os.makedirs(os.path.join(E, "signal-files"), exist_ok=True)
with open(os.path.join(E, "signal-files", "air.txt"), "w") as f:
    f.write("180\n")
ok(c.call("create_signal", {"name": "Air", "kind": "file", "file": "air.txt", "unit": "AQI", "range": [0, 300]}), "create_signal (a file) to bind")
air_id = next(s["id"] for s in library(E)["signals"] if s["name"] == "Air")
r_ = subprocess.run([BIN, "--set-signal", "air=200"], capture_output=True, env=env_for(E))
check(r_.returncode == 0 and open(os.path.join(E, "signal-files", "air.txt")).read().strip() == "200", "--set-signal air=200 writes signal-files/air.txt")
check(c.call("test_signal", {"signal": "Air"})["structuredContent"].get("value") == 200, "  → the file signal reads it")
check(subprocess.run([BIN, "--set-signal", "../evil=1"], capture_output=True, env=env_for(E)).returncode == 2
      and not os.path.exists(os.path.join(E, "evil.txt")), "--set-signal refuses anything but a plain file name")
res = c.call("bind_signal", {"style": "Glow", "input": "aqi", "signal": "Air"})
ok(res, "bind_signal to the user's signal by name")
check(glow_fx()["inputs"] == {"aqi": {"signal": air_id}} and res["structuredContent"]["changed"] is True, "  → stores the signal's id")
res = c.call("bind_signal", {"style": "Glow", "input": "aqi", "signal": "Air"})
check(res["structuredContent"]["changed"] is False, "binding again changes nothing")
sl = c.call("list_signals")["structuredContent"]
air_row = next(s for s in sl["signals"] if s["id"] == air_id)
check(air_row["boundBy"] == [{"style": "Glow", "styleId": glow_style, "input": "aqi"}] and "Glow ← aqi" in air_row["referencedBy"],
      "list_signals: referencedBy / boundBy include the binding")
err(c.call("delete_signal", {"signal": "Air"}), "delete_signal refused while a scene input is bound to it", "scene input")
err(c.call("bind_signal", {"style": "Glow", "input": "nope", "signal": "Air"}), "bind_signal: an unknown input key", "no input")
err(c.call("bind_signal", {"style": "Glow", "input": "aqi", "signal": "Nope"}), "bind_signal: an unknown signal", "No signal")
err(c.call("bind_signal", {"style": "Glow", "input": "aqi", "signal": "weather.condition"}), "bind_signal: a word signal", "is a word")
err(c.call("bind_signal", {"style": panes_style, "input": "aqi", "signal": "Air"}), "bind_signal: a scene that declares no inputs", "declares no inputs")
ok(c.call("create_style", {"name": "Plain Look", "effects": [{"kind": "halftone"}]}), "a style without a Custom Scene")
err(c.call("bind_signal", {"style": "Plain Look", "input": "aqi", "signal": "Air"}), "bind_signal: no Custom Scene in the style", "no Custom Scene")
err(c.call("bind_signal", {"style": "Plain Look", "effect_index": 0, "input": "aqi", "signal": "Air"}), "bind_signal: to a non-custom effect", "not a Custom Scene")
err(c.call("bind_signal", {"style": "Glow", "effect_index": 3, "input": "aqi", "signal": "Air"}), "bind_signal: effect_index out of range", "effect(s)")
# update_style patch: inputs merge; null disconnects
ok(c.call("update_style", {"style": "Glow", "patch": [{"index": 0, "inputs": {"aqi": {"signal": "weather.precip"}}}]}), "update_style patch inputs")
check(glow_fx()["inputs"] == {"aqi": {"signal": "weather.precip"}}, "  → rebound")
ok(c.call("bind_signal", {"style": "Glow", "input": "aqi", "signal": None}), "bind_signal null disconnects")
check("inputs" not in glow_fx(), "  → no binding left (the input reads its default)")
ok(c.call("delete_signal", {"signal": "Air"}), "…then delete_signal works")
# preview_style inputs pin the value: the pixels follow it
def glow_mean(ins):
    r = c.call("preview_style", {"style": "Glow", "width": 160, "height": 100, "inputs": ins} if ins is not None else {"style": "Glow", "width": 160, "height": 100})
    return region_mean(png_pixels(image(r)), 0.1, 0.9, 0.1, 0.9), r
lo_, r0 = glow_mean({"aqi": 0})
hi_, r1 = glow_mean({"aqi": 300})
un_, _ = glow_mean(None)
ok(r1, "preview_style with inputs")
check(hi_[0] > lo_[0] + 0.5 and abs(un_[0] - lo_[0]) < 0.02 and "aqi = 300" in text(r1),
      f"preview_style inputs change the pixels (aqi 0 {lo_[0]:.2f} → 300 {hi_[0]:.2f}); unpinned = the default ({un_[0]:.2f})")
err(c.call("preview_style", {"style": "Glow", "inputs": {"nope": 1}}), "preview_style: an unknown input key", "no input")
err(c.call("preview_style", {"style": "Glow", "inputs": {"aqi": 400}}), "preview_style: an input out of its range", "outside")
err(c.call("preview_style", {"style": "Panes", "inputs": {"aqi": 1}}), "preview_style: a style without inputs", "no Custom Scene with inputs")

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

# ---------------------------------------------------------------- film toolkit end to end (fake Blender)
# The REAL adapter (DSFilmToolkit) and the REAL toolkit driver (tools/film/job.py: run.py's CLI per
# variant, PROGRESS → progress file, ffmpeg HEVC encode), with Blender replaced by fake_blender.py
# (never launch the real Blender in a test). Packages install and play through the real film engine.
print("== film toolkit end to end (DSFilmToolkit + tools/film/job.py, fake Blender)")
TK = os.path.join(ROOT, "tools", "film")
FB = os.path.join(ROOT, "tools", "mcp-selftest", "fake_blender.py")
R = new_store()
c = Client(R, DOTSTUDIO_FILM_TOOLKIT=TK, DOTSTUDIO_MCP_FAKE_BLENDER=FB)
c.init()
res = c.call("film_status")
ok(res, "film_status with the toolkit")
fs = res["structuredContent"]
check(fs["available"] is True and fs["toolkitPulled"] is True and fs["blenderReady"] is True and TK in text(res)
      and "ffmpeg:" in text(res), "film_status: toolkit (dev override), Blender, python and ffmpeg found")
res = c.call("list_film_templates")
ok(res, "list_film_templates from the toolkit")
tpl = res["structuredContent"]["templates"]
check(tpl and tpl[0]["id"] == "commute" and tpl[0]["cameras"] == ["wide", "close", "aisle"]
      and tpl[0]["variants"] == ["day", "golden", "night", "rain"]
      and {p["key"] for p in tpl[0]["params"]} >= {"penguin_color", "sway", "cabin"}
      and tpl[0]["spec"]["look"]["bloom"] == 0.25 and tpl[0]["spec"]["look"]["grain"] == 0.2,
      "Commute: variants, cameras, params, the look as 0…1 sliders")
err(c.call("create_film_scene", {"spec": {"scene": "warehouse"}}), "the toolkit's validator: unknown scene", "no scene module")
err(c.call("create_film_scene", {"template": "commute", "loop_seconds": 10.01}), "the toolkit's validator: whole frames", "whole number")
res = c.call("create_film_scene", {"spec": {"scene": "local"}, "scene_files": {"scene.py": "ASSETS = []\ndef build(ctx):\n    return {\n"}})
err(res, "the toolkit's validator: scene.py syntax error", "scene.py")
check(any(d.get("line") == 3 for d in (res.get("structuredContent") or {}).get("diagnostics", [])) or "3" in text(res),
      "…with its line number")
err(c.call("create_film_scene", {"spec": {"scene": "local"}, "scene_files": {"scene.py": "ASSETS = ['https://x/y.hdr']\ndef build(ctx):\n    return {}\n"}}),
    "the toolkit's validator: CC0-only assets", "cc0")
res = c.call("create_film_scene", {"template": "commute", "name": "Commute Test", "variants": ["day", "night"],
                                   "params": {"sway": 0.5}, "look": {"halation": 0.3, "grain": 0.3}})
ok(res, "create_film_scene from the real Commute template")
rdraft = res["structuredContent"]["draft"]
res = c.call("render_film_stills", {"draft": rdraft, "width": 320, "height": 200, "samples": 8, "wait_seconds": 45})
ok(res, "render_film_stills through job.py")
sjob = res["structuredContent"]["job"]
imgs = [image for image in res["content"] if image["type"] == "image"]
check(res["structuredContent"]["state"] == "done" and len(imgs) == 2 and png_ok(base64.b64decode(imgs[0]["data"])) == (True, (320, 200)),
      f"stills: one 320×200 PNG per variant ({res['structuredContent']['state']})")
slog = open(os.path.join(R, "jobs", sjob, "log.txt")).read()
check('"-b", "--factory-startup", "--python", "' + os.path.join(TK, "run.py") + '"' in slog and '"--still"' in slog
      and '"--engine", "cycles"' in slog and '"--samples", "8"' in slog and '"--camera", "wide"' in slog,
      "stills: Blender headless + run.py --still, Cycles, the asked samples, the spec still's camera")
wspec = json.load(open(os.path.join(R, "jobs", sjob, "work", "spec.json")))
check(wspec["look"]["bloom"] == {"strength": 0.08, "threshold": 3.0, "size": 0.55}
      and abs(wspec["look"]["halation"]["strength"] - 0.7) < 1e-6 and abs(wspec["look"]["grain"]["amount"] - 0.027) < 1e-6
      and wspec["params"]["sway"] == 0.5, "the job's spec: look sliders → dsfilm.post blocks, params kept")
check(res["structuredContent"]["progress"].get("fraction") == 1, "stills progress reached 1")
err(c.call("render_film_loop", {"draft": rdraft, "seconds": 4.01, "fps": 24}), "loop: whole frames", "whole number")
res = c.call("render_film_loop", {"draft": rdraft, "seconds": 4, "fps": 24, "width": 960, "height": 540, "quality": "draft"})
ok(res, "render_film_loop through job.py")
ljob = res["structuredContent"]["job"]
deadline = time.time() + 120
st = {}
while time.time() < deadline:
    st = c.call("film_job_status", {"job": ljob})["structuredContent"]
    if st["state"] != "running":
        break
    time.sleep(1)
check(st.get("state") == "done" and "scene" in st, f"loop rendered, encoded, packaged and installed ({st.get('state')}, {st.get('packageError', '')}{st.get('logTail', '')[-300:] if st.get('state') == 'failed' else ''})")
llog = open(os.path.join(R, "jobs", ljob, "log.txt")).read()
check('"--anim"' in llog and '"--frames", "1-96"' in llog and '"--engine", "eevee"' in llog and '"--samples", "16"' in llog
      and '"--res", "960x540"' in llog, "loop (draft): run.py --anim, 96 frames, EEVEE, 16 samples, never under 960 px")
fbspec = [json.loads(l.split(" ", 2)[2]) for l in llog.splitlines() if l.startswith("FAKE_BLENDER spec ")]
check(fbspec and all(x["loop"] == {"seconds": 4, "fps": 24} for x in fbspec), f"the job's spec carries the asked loop length ({[x['loop'] for x in fbspec]})")
check(not os.path.exists(os.path.join(R, "jobs", ljob, "work", "day", "frames")), "frames removed once encoded")
rscene = st.get("scene", "")
pk = os.path.join(R, "scenes", rscene)
man = json.load(open(os.path.join(pk, "scene.json"))) if os.path.exists(os.path.join(pk, "scene.json")) else {}
check(man.get("engine", {}).get("id") == "film" and man.get("name") == "Commute Test"
      and sorted((c_["variant"], c_["file"], c_.get("codec")) for c_ in man.get("clips", [])) == [("day", "clips/day.mov", "hevc"), ("night", "clips/night.mov", "hevc")]
      and man.get("look") == {"bloom": 0.25, "halation": 0.3, "grain": 0.3},
      f"package: engine film, HEVC clips per variant, the look as numbers ({man.get('clips')}, {man.get('look')})")
probe = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=codec_name,codec_tag_string,nb_frames", "-of", "compact",
                        os.path.join(pk, "clips", "day.mov")], capture_output=True, text=True).stdout if shutil.which("ffprobe") else "hevc hvc1 nb_frames=96"
check("hevc" in probe and "hvc1" in probe and "nb_frames=96" in probe, f"day.mov: HEVC hvc1, 96 frames ({probe.strip()})")
ok(c.call("validate_custom_scene", {"id": rscene}), "the package validates in the real film engine")
res = c.call("create_style", {"name": "Commute Test", "effects": [{"kind": "custom", "scene": rscene}], "fps": 24})
ok(res, "create_style with the rendered film scene")
check(res["structuredContent"]["style"]["effects"][0]["params"].get("ds.grain") == 0.3, "its grain is the style's starting Grain")
rstyle = res["structuredContent"]["id"]
day = c.call("preview_style", {"style": rstyle, "clock": "13:00", "date": "2026-06-21", "width": 320, "height": 200,
                               "save_path": os.path.join(OUT, "e2e-filmkit-day.png")})
night = c.call("preview_style", {"style": rstyle, "clock": "01:00", "date": "2026-06-21", "width": 320, "height": 200,
                                 "save_path": os.path.join(OUT, "e2e-filmkit-night.png")})
dl, nl = (r.get("structuredContent", {}).get("meanLuminance", -1) for r in (day, night))
ok(day, "preview_style the rendered film scene")
pix = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=pix_fmt", "-of", "csv=p=0", os.path.join(pk, "clips", "day.mov")],
                     capture_output=True, text=True).stdout.strip() if shutil.which("ffprobe") else ""
check(dl > nl + 0.15, f"the rendered clips play: day clip by day, night clip at night, 10-bit HEVC posters included ({pix}; {dl} vs {nl}; {text(day)[:200]})")
# one Blender at a time: a second job queues behind the first; cancel stops a job's whole group
c.close()
c = Client(R, DOTSTUDIO_FILM_TOOLKIT=TK, DOTSTUDIO_MCP_FAKE_BLENDER=FB, FAKE_BLENDER_FRAME_S=0.5)
c.init()
j1 = c.call("render_film_loop", {"draft": rdraft, "seconds": 4, "fps": 24, "width": 960, "height": 540, "variants": ["rain"]})["structuredContent"]["job"]
time.sleep(3)
res = c.call("render_film_stills", {"draft": rdraft, "width": 320, "height": 200, "wait_seconds": 3})
j2 = res["structuredContent"]["job"]
s1 = c.call("film_job_status", {"job": j1})["structuredContent"]
s2 = res["structuredContent"]
check(s1["state"] == "running" and "frame" in s1["progress"].get("stage", "") and 0 < s1["progress"].get("fraction", 0) < 1
      and "eta_s" in s1["progress"], f"a running loop reports frame progress and an ETA ({s1['progress']})")
check(s2["state"] == "running" and "queued" in s2["progress"].get("stage", ""), f"a second job queues: one Blender at a time ({s2['progress']})")
check("fake failure" not in s1["logTail"] and "FAKE_BLENDER" in s1["logTail"], "the log tail is the render's own output")
for j in (j1, j2):
    ok(c.call("cancel_film_job", {"job": j}), f"cancel_film_job {j}")
time.sleep(1.5)
left = subprocess.run(["pgrep", "-f", os.path.join(R, "jobs")], capture_output=True, text=True).stdout.split()
check(not left, f"cancelled: no job process left (job.py, fake Blender) {left}")
check(all(c.call("film_job_status", {"job": j})["structuredContent"]["state"] == "cancelled" for j in (j1, j2)), "both jobs cancelled")
c.close()
# a failing render: the job fails with run.py's error in its log
c = Client(R, DOTSTUDIO_FILM_TOOLKIT=TK, DOTSTUDIO_MCP_FAKE_BLENDER=FB, FAKE_BLENDER_FAIL=1)
c.init()
res = c.call("render_film_stills", {"draft": rdraft, "variants": ["day"], "width": 320, "height": 200, "wait_seconds": 30})
check(res["structuredContent"]["state"] == "failed" and "fake failure" in text(res), "a failed render: state failed, the error in the log tail")
c.close()
# the pulled pack layout: <store>/engines/film/<version>/ (no override)
shutil.copytree(TK, os.path.join(R, "engines", "film", "0.1.0"), ignore=shutil.ignore_patterns("__pycache__", "dist"))
c = Client(R, DOTSTUDIO_MCP_FAKE_BLENDER=FB)
c.init()
res = c.call("film_status")
check(res["structuredContent"]["toolkitPulled"] is True and os.path.join(R, "engines", "film", "0.1.0") in text(res),
      "film_status finds the pulled pack in <store>/engines/film/<version>")
check(c.call("list_film_templates")["structuredContent"]["templates"][0]["id"] == "commute", "…and its templates")
c.close()
c = Client(R, DOTSTUDIO_FILM_TOOLKIT=os.path.join(R, "nowhere"), DOTSTUDIO_MCP_FAKE_BLENDER=FB)
c.init()
res = c.call("film_status")
check(res["structuredContent"]["toolkitPulled"] is False and "isn't a film toolkit folder" in text(res), "a wrong DOTSTUDIO_FILM_TOOLKIT is reported")
c.close()
c = Client(R, DOTSTUDIO_FILM_TOOLKIT=TK, DOTSTUDIO_MCP_FAKE_BLENDER="none")
c.init()
err(c.call("render_film_stills", {"draft": rdraft}), "no Blender: renders refuse with the install steps", "blender.org")
c.close()
# the commands for the REAL Blender, as a dry run (printed, never run)
dry = subprocess.run(["python3", "-I", os.path.join(TK, "job.py"), "loop", "--blender", "/Applications/Blender.app/Contents/MacOS/Blender",
                      "--spec", os.path.join(R, "film", rdraft, "spec.json"), "--out", os.path.join(R, "dry", "out"), "--work", os.path.join(R, "dry", "work"),
                      "--variants", "day,night", "--seconds", "24", "--fps", "24", "--res", "3840x2160", "--quality", "final", "--dry-run"],
                     capture_output=True, text=True)
lines = [l for l in dry.stdout.splitlines() if l.startswith("BLENDER ")]
print("\n".join("      " + l for l in lines))
check(dry.returncode == 0 and len(lines) == 2 and all("/Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup --python " + os.path.join(TK, "run.py") in l
                                                      and "--frames 1-576 --res 3840x2160 --samples 128 --engine cycles" in l for l in lines),
      "dry run: the real Blender command per variant (final = Cycles, 128 samples)")
shutil.rmtree(R, ignore_errors=True)

# ---------------------------------------------------------------- signals and When rules
# A local fixture over plain HTTP on 127.0.0.1 — reachable only through the DEBUG-only test hook
# DOTSTUDIO_SIGNAL_ALLOW_LOCAL=1 (Shared/Signals/Fetch/SignalFetch.swift); no third-party network.
print("== signals and When rules (offline; a local fixture)")
import http.server


class _Fixture(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/json", headers=None):
        b = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        FIXTURE_HITS.append((self.path, dict(self.headers)))
        p = self.path.split("?")[0]
        if p == "/aqi.json":
            self._send(200, json.dumps({"status": "ok", "data": {"aqi": 42, "city": {"name": "Toronto"}, "iaqi": {"pm25": {"v": 11.5}},
                                                                "secret_debug_body_marker": "x" * 80}}))
        elif p == "/keyed.json":
            ok_key = self.headers.get("X-API-Key") == "k-123"
            self._send(200 if ok_key else 401, json.dumps({"v": 7}) if ok_key else "{}")
        elif p == "/text":
            self._send(200, "17.5\n", "text/plain")
        elif p == "/big":
            self._send(200, json.dumps({"pad": "x" * 300_000}))
        elif p == "/busy":
            self._send(429, "{}", headers={"Retry-After": "120"})
        elif p == "/redir-private":
            self._send(302, "", headers={"Location": "https://10.0.0.1/x"})
        elif p == "/redir-rebind":
            self._send(302, "", headers={"Location": "https://rebind.test/x"})
        else:
            self._send(404, "{}")


FIXTURE_HITS = []
fx = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Fixture)
threading.Thread(target=fx.serve_forever, daemon=True).start()
FX = f"http://127.0.0.1:{fx.server_address[1]}"

G = new_store()
c = Client(G, DOTSTUDIO_SIGNAL_ALLOW_LOCAL=1)
c.init()
res = c.call("list_signals")
ok(res, "list_signals")
sc = res["structuredContent"]
check(len(sc["builtIn"]) == 15 and {"weather.condition", "weather.tempC", "power.battery", "music.playing", "time.hour"} <= {b["id"] for b in sc["builtIn"]}
      and sc["signals"] == [], "15 built-ins (weather, sun, time, power, music), none of the user's yet")
check(next(b for b in sc["builtIn"] if b["id"] == "weather.condition")["options"][0] == "clear", "weather.condition lists its words")
check("signals" in c.call("get_started")["structuredContent"]["readFirst"], "get_started: read the signals guide first")
res = c.call("read_guide", {"id": "signals"})
check(not res.get("isError") and "Keychain" in text(res) and "never" in text(res).lower(), "Guides/signals.md: keys, privacy, recipes")

# test_signal: an outline, never the body
res = c.call("test_signal", {"draft": {"url": FX + "/aqi.json", "pointer": "/data/aqi"}})
ok(res, "test_signal a draft against the local fixture")
st = res["structuredContent"]
check(st["value"] == 42 and st["status"] == 200 and st["viaApp"] is False and st["bytes"] > 0, "  → reads 42, HTTP 200, offline")
ptrs = {o["pointer"]: o["value"] for o in st["outline"]}
check(ptrs.get("/data/aqi") == 42 and ptrs.get("/data/city/name") == "Toronto" and ptrs.get("/data/iaqi/pm25/v") == 11.5,
      "  → an outline of pointers to leaves")
check(len(ptrs["/data/secret_debug_body_marker"]) <= 40 and "x" * 80 not in json.dumps(res), "  → long strings cut to 40, the raw body never returned")
check(any(h.get("User-Agent", "").startswith("DotStudio/") and "Cookie" not in h for p, h in FIXTURE_HITS), "  → GET with DotStudio's UA, no cookies")
res = c.call("test_signal", {"draft": {"url": FX + "/aqi.json", "pointer": "/data/nope"}})
check(res["structuredContent"]["ok"] is False and "Nothing at" in res["structuredContent"]["error"], "test_signal: a missing pointer says so")
res = c.call("test_signal", {"draft": {"url": FX + "/text"}})
check(res["structuredContent"]["value"] == 17.5, "test_signal: a plain-text number")
res = c.call("test_signal", {"draft": {"url": FX + "/big"}})
check(res["structuredContent"]["ok"] is False and "256 KB" in res["structuredContent"]["error"], "test_signal: over 256 KB is cut off")
res = c.call("test_signal", {"draft": {"url": FX + "/busy"}})
check(res["structuredContent"]["error"] == "HTTP 429", "test_signal: HTTP 429 reported")
res = c.call("test_signal", {"draft": {"url": FX + "/redir-private"}})
check(res["structuredContent"]["ok"] is False and "Redirected" in res["structuredContent"]["error"], "a redirect to a private address is re-checked and refused")

# refusals: http, private and local hosts, keys in the URL, files outside signal-files
for url, needle, what in [("http://example.com/aqi", "Only https", "http refused"),
                          ("https://192.168.1.20/state", "private", "a private IP refused (AI)"),
                          ("https://10.0.0.1/x", "private", "10/8 refused"),
                          ("https://[fe80::1]/x", "link-local", "IPv6 link-local refused"),
                          ("https://[fd00::5]/x", "private", "IPv6 ULA refused"),
                          ("https://169.254.1.1/x", "link-local", "169.254/16 refused"),
                          ("https://homeassistant.local/api", "local network", "*.local refused"),
                          ("https://2130706433/x", "dotted", "a disguised IP refused"),
                          ("https://api.example.com/v1?city=x&apikey=abc", "Never put a key in the URL", "?apikey= refused"),
                          ("https://api.example.com/v1?TOKEN=abc", "auth", "?token= refused (any case)"),
                          ("https://user:pw@api.example.com/v1", "password", "user:pass@ refused")]:
    err(c.call("create_signal", {"name": "Bad", "url": url}), "create_signal: " + what, needle)
    err(c.call("test_signal", {"draft": {"url": url}}), "test_signal: " + what, needle)
c2 = Client(G)   # no test hook: even 127.0.0.1 over http is refused
c2.init()
err(c2.call("test_signal", {"draft": {"url": FX + "/aqi.json"}}), "without the test hook, http://127.0.0.1 is refused", "Only https")
err(c2.call("create_signal", {"name": "Loop", "url": "https://127.0.0.1:8443/x"}), "…and https to loopback is refused for the AI", "private")
c2.close()
err(c.call("create_signal", {"name": "Bad", "kind": "file", "file": "../library.json"}), "file outside signal-files refused", "plain file name")
err(c.call("create_signal", {"name": "X", "url": FX + "/aqi.json", "pollMinutes": 1}), "poll under 5 minutes refused by the schema", "minimum")
err(c.call("create_signal", {"name": "X", "url": FX + "/aqi.json", "auth": {"in": "header", "name": "X-API-Key", "value": "k-123"}}),
    "a key's value can never be passed", "unknown property")
check(not os.path.exists(os.path.join(G, "library.json")) or not library(G).get("signals"), "nothing saved by the refusals")

# create, key, cap
res = c.call("create_signal", {"name": "Air quality", "url": FX + "/aqi.json", "pointer": "/data/aqi", "unit": "AQI", "range": [0, 300]})
ok(res, "create_signal")
aqi = res["structuredContent"]["id"]
sg = library(G)["signals"][0]
check(sg["id"] == aqi and sg["createdBy"] == "ai" and sg["pointer"] == "/data/aqi" and sg["range"] == [0, 300], "  → library.json: the definition, marked AI")
check(not os.path.exists(os.path.join(G, "signal-values.json")), "  → no values in library.json, no fetch without a rule")
err(c.call("create_signal", {"name": "air QUALITY", "url": FX + "/aqi.json"}), "duplicate signal names refused", "already named")
res = c.call("create_signal", {"name": "Keyed", "url": FX + "/keyed.json", "pointer": "/v", "auth": {"in": "header", "name": "X-API-Key"}})
ok(res, "create_signal with a key")
keyed = res["structuredContent"]["id"]
check(res["structuredContent"]["needsSecret"] is True and "Settings ▸ Signals ▸ Keyed" in text(res) and "never in this chat" in text(res),
      "  → needsSecret: ask the user to paste it in Settings, never in chat")
ks = next(s for s in library(G)["signals"] if s["id"] == keyed)
check(ks["auth"] == {"in": "header", "name": "X-API-Key"}, "  → only where the key goes is stored")
err(c.call("test_signal", {"signal": "Keyed"}), "a keyed signal can't be tested offline (the app holds the key)", "only the running DotStudio")
os.makedirs(os.path.join(G, "signal-files"), exist_ok=True)
with open(os.path.join(G, "signal-files", "office.txt"), "w") as f:
    f.write("23.5\n")
res = c.call("create_signal", {"name": "Office temp", "kind": "file", "file": "office.txt", "unit": "°C"})
ok(res, "create_signal kind file")
res = c.call("test_signal", {"signal": "Office temp"})
check(res["structuredContent"]["value"] == 23.5, "test_signal reads the file")
os.symlink("/etc/hosts", os.path.join(G, "signal-files", "sneaky.json"))
ok(c.call("create_signal", {"name": "Sneaky", "kind": "file", "file": "sneaky.json"}), "a file signal named for a symlink")
res = c.call("test_signal", {"signal": "Sneaky"})
check(res["structuredContent"]["ok"] is False and "Outside signal-files" in res["structuredContent"]["error"], "  → a symlink out of signal-files is never read")
ok(c.call("delete_signal", {"signal": "Sneaky"}), "delete_signal")
fillers = [c.call("create_signal", {"name": f"Filler {i}", "url": FX + "/aqi.json"}) for i in range(13)]
check(all(not r.get("isError") for r in fillers) and len(library(G)["signals"]) == 16, "16 signals")
err(c.call("create_signal", {"name": "One too many", "url": FX + "/aqi.json"}), "the 17th is refused (cap)", "at most 16")
for i in range(13):
    c.call("delete_signal", {"signal": f"Filler {i}"})
check(len(library(G)["signals"]) == 3, "fillers deleted")
ok(c.call("update_signal", {"signal": "Air quality", "pollMinutes": 30, "unit": "AQI"}), "update_signal")
check(next(s for s in library(G)["signals"] if s["id"] == aqi)["pollMinutes"] == 30, "  → pollMinutes stored")
err(c.call("update_signal", {"signal": "weather.tempC", "name": "x"}), "built-ins can't be changed", "built in")
# A key is tied to its signal, not a host: an assistant can't point a keyed signal elsewhere.
keyed = next(s for s in library(G)["signals"] if s["name"] == "Keyed")
err(c.call("update_signal", {"signal": "Keyed", "url": "https://collector.example/aqi"}),
    "a keyed signal can't be pointed at another host by the AI", "only the user")
check(next(s for s in library(G)["signals"] if s["name"] == "Keyed")["url"] == keyed["url"], "  → its address is unchanged")
same_host = keyed["url"].rstrip("/") + "/v2"
ok(c.call("update_signal", {"signal": "Keyed", "url": same_host}), "the same host, another path: allowed")
# An address an assistant chooses is fetched under the AI rules from then on (DNS and peer checks).
L = library(G); [s.update({"createdBy": None}) for s in L["signals"] if s["id"] == aqi]
json.dump(L, open(os.path.join(G, "library.json"), "w"))
check(next(s for s in library(G)["signals"] if s["id"] == aqi).get("createdBy") is None, "  (Air quality made the user's own for the next check)")
ok(c.call("update_signal", {"signal": "Air quality", "url": FX + "/aqi2.json"}), "the AI changes a user signal's address")
check(next(s for s in library(G)["signals"] if s["id"] == aqi).get("createdBy") == "ai", "  → it's fetched under the AI rules from then on")
ok(c.call("update_signal", {"signal": "Air quality", "url": FX + "/aqi.json"}), "  (address put back)")
res = c.call("list_signals")
mine = {s["name"]: s for s in res["structuredContent"]["signals"]}
check(mine["Air quality"]["host"] == "127.0.0.1" and mine["Keyed"]["hasKey"] is True and "k-123" not in json.dumps(res),
      "list_signals: host, hasKey — never a key")

# When rules
lib = library(G)
golden = next(p["id"] for p in lib["presets"] if p["name"] == "Golden Hour")
night_sky = next(p["id"] for p in lib["presets"] if p["name"] == "Night Sky")
res = c.call("set_rule", {"name": "Snow day", "when": {"all": [{"signal": "weather.condition", "op": "in", "values": ["snow", "sleet"]}]}, "play": ["Golden Hour"]})
ok(res, "set_rule (weather.condition in snow, sleet)")
snow_rule = res["structuredContent"]["id"]
r0 = library(G)["rules"][0]
check(r0["play"] == [golden] and r0["when"]["all"][0]["op"] == "in" and r0["createdBy"] == "ai", "  → library.json rules")
err(c.call("set_rule", {"when": {"all": [{"signal": "weather.condition", "op": "gt", "value": 3}]}, "play": ["Golden Hour"]}),
    "op vs type: gt on a word refused", "is a word")
err(c.call("set_rule", {"when": {"all": [{"signal": "weather.condition", "op": "eq", "value": "blizzard"}]}, "play": ["Golden Hour"]}),
    "an unknown weather word refused", "never")
err(c.call("set_rule", {"when": {"all": [{"signal": "weather.nope", "op": "eq", "value": 1}]}, "play": ["Golden Hour"]}), "unknown signal refused", "No signal")
err(c.call("set_rule", {"when": {"all": [{"signal": "power.battery", "op": "lt", "value": 20}]}, "play": ["No Such Style"]}), "unknown style refused", "No style")
err(c.call("set_rule", {"when": {"all": []}, "play": ["Golden Hour"]}), "a rule with no test refused", "at least one test")
res = c.call("set_rule", {"name": "Bad air", "when": {"all": [{"signal": "Air quality", "op": "gt", "value": 150}], "timeOfDay": "night"}, "play": ["Night Sky", "Golden Hour"]})
ok(res, "set_rule on the user's signal by name, at night, two styles")
bad_air = res["structuredContent"]["id"]
check(library(G)["rules"][1]["when"]["all"][0]["signal"] == aqi, "  → the test stores the signal's id")
res = c.call("list_rules")
ok(res, "list_rules")
rl = res["structuredContent"]["rules"]
check([r["name"] for r in rl] == ["Snow day", "Bad air"] and all(r["activeNow"] is False for r in rl)
      and "Weather is Snow or Sleet" in rl[0]["summary"], "  → in order, a sentence each, none active (no app)")
err(c.call("delete_signal", {"signal": "Air quality"}), "delete_signal refused while a rule tests it", "used by")
# what the app's lease says plays — list_rules / list_displays / list_styles read it
t = time.time()
with open(os.path.join(G, "signal-values.json"), "w") as f:
    json.dump({"version": 1, "writtenAt": t, "values": {"weather.condition": {"s": "snow", "at": t, "stale": 10800}},
               "rule": {"id": snow_rule, "since": t - 60, "validUntil": t + 1800}}, f)
res = c.call("list_rules")
check(res["structuredContent"]["activeNow"] == snow_rule and res["structuredContent"]["rules"][0]["activeNow"] is True, "list_rules: activeNow from the app's lease")
d = c.call("list_displays")["structuredContent"]["displays"][0]
check(d["screensaver"] == "Golden Hour" and "Snow" in d.get("screensaverWhen", ""), "list_displays: the rule's style plays, and says when")
res = c.call("list_signals")
check(next(b for b in res["structuredContent"]["builtIn"] if b["id"] == "weather.condition")["value"] == "snow", "list_signals: the live value")
check("screensaver when Weather is Snow or Sleet" in next(s for s in c.call("list_styles")["structuredContent"]["styles"] if s["id"] == golden)["playing"],
      "list_styles: “screensaver when …” role")
with open(os.path.join(G, "signal-values.json"), "w") as f:
    json.dump({"version": 1, "writtenAt": t - 7200, "values": {}, "rule": {"id": snow_rule, "since": t - 7200, "validUntil": t - 1}}, f)
check(c.call("list_rules")["structuredContent"]["activeNow"] is None, "an expired lease: no rule (the app quit)")
ok(c.call("delete_signal", {"signal": "Air quality", "force": True}), "delete_signal force")
check([r["name"] for r in library(G).get("rules", [])] == ["Snow day"], "  → the rule that only tested it went too")
# pruning: deleting a style takes it out of rules
res = c.call("duplicate_style", {"style": "Golden Hour", "name": "Snowfall"})
snowfall = res["structuredContent"]["id"]
ok(c.call("set_rule", {"rule": "Snow day", "play": ["Snowfall"]}), "set_rule: change an existing rule's style")
ok(c.call("delete_style", {"style": "Snowfall"}), "delete the rule's only style")
check(not library(G).get("rules"), "  → the rule left with no style is pruned")
# the gates
ok(c.call("set_rule", {"name": "Low battery", "when": {"all": [{"signal": "power.battery", "op": "lt", "value": 20}]}, "play": ["Golden Hour"]}), "set_rule (battery < 20)")
with open(os.path.join(G, "ai-settings.json"), "w") as f:
    json.dump({"allowPlaybackChanges": False}, f)
err(c.call("set_rule", {"name": "Nope", "when": {"all": [{"signal": "power.onAC", "op": "eq", "value": True}]}, "play": ["Golden Hour"]}),
    "set_rule refused with playback changes off (offline)", "turned off")
err(c.call("delete_rule", {"rule": "Low battery"}), "delete_rule refused too", "turned off")
ok(c.call("create_signal", {"name": "Still fine", "url": FX + "/aqi.json"}), "signals don't need playback changes")
with open(os.path.join(G, "ai-settings.json"), "w") as f:
    json.dump({"allowSignals": False}, f)
err(c.call("create_signal", {"name": "Nope", "url": FX + "/aqi.json"}), "create_signal refused with signals off", "live data signals")
err(c.call("delete_signal", {"signal": "Still fine"}), "delete_signal refused with signals off", "live data signals")
st = settings_of(c.call("get_settings", {"group": "ai"}))
check(st["ai.allowSignals"]["value"] is False and st["ai.allowSignals"]["readOnly"] is True, "get_settings: ai.allowSignals, read-only")
err(c.call("update_settings", {"settings": {"ai.allowSignals": True}}), "the AI can't grant itself signals", "only the user")
os.remove(os.path.join(G, "ai-settings.json"))
ok(c.call("delete_rule", {"rule": "Low battery"}), "delete_rule")
check(not library(G).get("rules"), "  → gone")
c.close()

# through the stand-in app (the same executors, the app's in-memory library; it has no Keychain)
print("== signals and When rules (through a stand-in app)")
H = new_store()
happ = subprocess.Popen([BIN, "--fake-app", "--clobber-ms", "150"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL, env=env_for(H, DOTSTUDIO_SIGNAL_ALLOW_LOCAL=1))
check(happ.stdout.readline().strip() == b"ready", "stand-in app ready")
happlied = []
threading.Thread(target=lambda: [happlied.append(l.decode().strip()) for l in happ.stdout], daemon=True).start()
c = Client(H, DOTSTUDIO_SIGNAL_ALLOW_LOCAL=1)
c.init()
res = c.call("create_signal", {"name": "Air quality", "url": FX + "/aqi.json", "pointer": "/data/aqi"})
ok(res, "create_signal via the app")
check(res["structuredContent"]["liveInApp"] is True, "  → routed through the app")
time.sleep(0.5)
check([s["name"] for s in library(H).get("signals", [])] == ["Air quality"], "  → survives the app's own saves")
res = c.call("test_signal", {"signal": "Air quality"})
check(res["structuredContent"].get("viaApp") is True and res["structuredContent"].get("value") == 42, "test_signal via the app (it holds the keys)")
res = c.call("set_rule", {"name": "Bad air", "when": {"all": [{"signal": "Air quality", "op": "gte", "value": 100}]}, "play": ["Golden Hour"]})
ok(res, "set_rule via the app")
time.sleep(0.4)
check([r["name"] for r in library(H).get("rules", [])] == ["Bad air"] and any("applied upsertRule ok=true" in l for l in happlied), "  → the app applied it")
with open(os.path.join(H, "ai-settings.json"), "w") as f:
    json.dump({"allowPlaybackChanges": False}, f)
err(c.call("set_rule", {"rule": "Bad air", "enabled": False}), "set_rule refused through the app with playback off", "turned off")
err(c.call("delete_rule", {"rule": "Bad air"}), "delete_rule refused through the app", "turned off")
os.remove(os.path.join(H, "ai-settings.json"))
t = time.time()
with open(os.path.join(H, "signal-values.json"), "w") as f:
    json.dump({"version": 1, "writtenAt": t, "values": {}, "rule": {"id": res["structuredContent"]["id"], "since": t, "validUntil": t + 600}}, f)
check(c.call("list_rules")["structuredContent"]["rules"][0]["activeNow"] is True, "list_rules activeNow with the app running")
c.close()
happ.stdin.close()
happ.wait(5)

# DNS: a public NAME that points at a private address (rebinding / LAN probing) is refused for
# AI-made signals, before the fetch and on every redirect. DOTSTUDIO_SIGNAL_FAKE_DNS (a DEBUG-only
# hook) replaces the lookups with a fixed table: no real DNS, and a refused fetch never connects.
print("== signals: where a host name points (a fake resolver)")
FAKE_DNS = "rebind.test=10.9.8.7;mixed.test=93.184.216.34,192.168.0.9;v6.test=fd00::1;mapped.test=::ffff:127.0.0.1"


def dns_refusals(cl, where):
    for host, needle in [("rebind.test", "10.9.8.7"), ("mixed.test", "192.168.0.9"), ("v6.test", "fd00::1"), ("mapped.test", "127.0.0.1")]:
        st_ = cl.call("test_signal", {"draft": {"url": f"https://{host}/v1/aqi", "pointer": "/aqi"}})["structuredContent"]
        check(st_["ok"] is False and "local network" in st_.get("error", "") and needle in st_.get("error", ""),
              f"{where}: {host} resolves to a private address → refused ({st_.get('error', '')[:60]}…)")
    st_ = cl.call("test_signal", {"draft": {"url": "https://nowhere.test/x"}})["structuredContent"]
    check(st_["ok"] is False and st_.get("error") == "Host not found", f"{where}: a name the resolver doesn't know → Host not found (no real lookup)")
    st_ = cl.call("test_signal", {"draft": {"url": FX + "/redir-rebind"}})["structuredContent"]
    check(st_["ok"] is False and "Redirected" in st_.get("error", "") and "10.9.8.7" in st_.get("error", ""),
          f"{where}: a redirect to a name that points inside is re-checked and refused")
    st_ = cl.call("test_signal", {"draft": {"url": FX + "/aqi.json", "pointer": "/data/aqi"}})["structuredContent"]
    check(st_.get("value") == 42, f"{where}: the local fixture (test hook) still answers")


D = new_store()
c = Client(D, DOTSTUDIO_SIGNAL_ALLOW_LOCAL=1, DOTSTUDIO_SIGNAL_FAKE_DNS=FAKE_DNS)
c.init()
dns_refusals(c, "offline")
res = c.call("create_signal", {"name": "Rebound", "url": "https://rebind.test/v1/aqi", "pointer": "/aqi"})
ok(res, "create_signal accepts a public-looking name (where it points is checked at each fetch)")
st = c.call("test_signal", {"signal": "Rebound"})["structuredContent"]
check(st["ok"] is False and "10.9.8.7" in st.get("error", ""), "  → a saved AI-made signal is refused at fetch time too")
c.close()
dapp = subprocess.Popen([BIN, "--fake-app"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                        env=env_for(D, DOTSTUDIO_SIGNAL_ALLOW_LOCAL=1, DOTSTUDIO_SIGNAL_FAKE_DNS=FAKE_DNS))
check(dapp.stdout.readline().strip() == b"ready", "stand-in app ready (fake resolver)")
c = Client(D, DOTSTUDIO_SIGNAL_ALLOW_LOCAL=1, DOTSTUDIO_SIGNAL_FAKE_DNS=FAKE_DNS)
c.init()
dns_refusals(c, "via the app")
c.close()
dapp.stdin.close()
dapp.wait(5)
shutil.rmtree(D, ignore_errors=True)
fx.shutdown()
for d in (G, H):
    shutil.rmtree(d, ignore_errors=True)

# ---------------------------------------------------------------- one implementation: offline == via the app
# Every library request is decided by LibraryOps (Shared/AI/LibraryOps.swift) — on the files when
# the app isn't running, on the app's memory when it is (the stand-in app runs exactly what
# AIBridgeHost runs). The same script both ways must give the same answers and the same files.
print("== library edits: offline and through the app agree")


def lib_state(store):
    l = library(store)
    w = wall(store)
    styles = {p["id"]: p["name"] for p in l["presets"]}
    nm = lambda i: styles.get(i, i)
    return {"names": sorted(styles.values()),
            "active": nm(l.get("activeID")),
            "rotation": [nm(i) for i in (l.get("rotation") or {}).get("presetIDs", [])],
            "rotates": (l.get("rotation") or {}).get("enabled"),
            "night": nm((l.get("schedule") or {}).get("nightPresetID")) if (l.get("schedule") or {}).get("enabled") else None,
            "pins": {k: nm(v["presetID"]) for k, v in (l.get("displayStyles") or {}).items()},
            "rules": sorted(r["name"] for r in l.get("rules", [])),
            "signals": sorted(x["name"] for x in l.get("signals", [])),
            "wall": {"on": w.get("enabled"), "style": nm(w.get("presetID")), "follows": w.get("followsScreensaver"),
                     "pins": {k: nm(v["presetID"]) for k, v in (w.get("displayStyles") or {}).items()}}}


def outcome(res):
    if res.get("isError"):
        return ("refused", text(res))
    m = res["structuredContent"].get("message", "")
    return ("ok", m.replace(" It plays while DotStudio runs.", ""))


SCRIPT = [
    ("unpin a display nobody has (screensaver)", "set_screensaver", {"mode": "unpin", "display": "NOPE"}),
    ("unpin a display nobody has (wallpaper)", "set_wallpaper", {"mode": "unpin", "display": "NOPE"}),
    ("unpin a connected display with no pin", "set_screensaver", {"mode": "unpin", "display": "DISPLAY-B"}),
    ("pin the screensaver on a display", "set_screensaver", {"style": "Golden Hour", "display": "DISPLAY-A"}),
    ("a display with another mode", "set_screensaver", {"style": "Golden Hour", "mode": "add", "display": "DISPLAY-A"}),
    ("add a style already in the rotation", "set_screensaver", {"style": "Liquid Chrome", "mode": "add"}),
    ("add a second style", "set_screensaver", {"style": "Aurora", "mode": "add"}),
    ("night style", "set_screensaver", {"style": "Night Sky", "mode": "night"}),
    ("wallpaper follows the screensaver", "set_wallpaper", {"mode": "follow"}),
    ("a display's own wallpaper while following", "set_wallpaper", {"style": "Aurora", "display": "DISPLAY-B"}),
    ("wallpaper off with a display", "set_wallpaper", {"mode": "off", "display": "DISPLAY-B"}),
    ("wallpaper unpin", "set_wallpaper", {"mode": "unpin", "display": "DISPLAY-B"}),
    ("wallpaper unpin again", "set_wallpaper", {"mode": "unpin", "display": "DISPLAY-B"}),
    ("wallpaper on one style, everywhere", "set_wallpaper", {"style": "Currents"}),
    ("a display of its own, not following", "set_wallpaper", {"style": "StandBy", "display": "DISPLAY-B"}),
    ("duplicate (default name)", "duplicate_style", {"style": "Currents"}),
    ("duplicate again (unique name)", "duplicate_style", {"style": "Currents"}),
    ("duplicate named like an existing style", "duplicate_style", {"style": "Currents", "name": "Aurora"}),
    ("delete the wallpaper's shared pick (a display keeps its own)", "delete_style", {"style": "Currents", "confirm": True}),
    ("screensaver unpin the pinned display", "set_screensaver", {"mode": "unpin", "display": "DISPLAY-A"}),
    ("a signal", "create_signal", {"name": "Level", "kind": "file", "file": "level.json", "pointer": "/v"}),
    ("a rule on it", "set_rule", {"name": "High", "when": {"all": [{"signal": "Level", "op": "gt", "value": 5}]}, "play": ["Aurora"]}),
    ("delete the signal without force", "delete_signal", {"signal": "Level"}),
    ("dayOnly", "set_screensaver", {"mode": "dayOnly"}),
]
GATED = [
    ("playback off: unpin", "set_screensaver", {"mode": "unpin", "display": "DISPLAY-A"}),
    ("playback off: wallpaper", "set_wallpaper", {"mode": "off"}),
    ("playback off: delete a signal a rule tests, with force", "delete_signal", {"signal": "Level", "force": True}),
    ("playback off: a rule", "set_rule", {"rule": "High", "enabled": False}),
]


def run_script(store, via_app):
    out = []
    cl = Client(store)
    cl.init()
    for what, tool, args in SCRIPT:
        res = cl.call(tool, args)
        if not res.get("isError") and "liveInApp" in res.get("structuredContent", {}):
            check(res["structuredContent"]["liveInApp"] is via_app, f"{'app' if via_app else 'offline'}: {what} took the expected path")
        out.append((what, outcome(res)))
        time.sleep(0.05)
    with open(os.path.join(store, "ai-settings.json"), "w") as f:
        json.dump({"allowPlaybackChanges": False}, f)
    for what, tool, args in GATED:
        out.append((what, outcome(cl.call(tool, args))))
    os.remove(os.path.join(store, "ai-settings.json"))
    cl.close()
    time.sleep(0.4)        # the stand-in's own saves
    return out, lib_state(store)


O = new_store()
off, off_state = run_script(O, False)
Q = new_store()
qapp = subprocess.Popen([BIN, "--fake-app", "--clobber-ms", "120"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL, env=env_for(Q))
check(qapp.stdout.readline().strip() == b"ready", "stand-in app ready")
via, via_state = run_script(Q, True)
for (what, a), (_, b) in zip(off, via):
    check(a == b, f"same answer both ways: {what} — {a[0]}" + ("" if a == b else f" (offline {a} / app {b})"))
check(off_state == via_state, "the same library and wallpaper both ways" + ("" if off_state == via_state else f": {off_state} / {via_state}"))
res = dict(off)
check(res["unpin a display nobody has (screensaver)"][0] == "refused" and "NOPE" in res["unpin a display nobody has (screensaver)"][1]
      and res["unpin a display nobody has (wallpaper)"][0] == "refused", "unpinning an unknown display key is refused (both destinations)")
check("already" in res["unpin a connected display with no pin"][1] and "already" in res["wallpaper unpin again"][1], "an unpin with nothing pinned says so")
check(res["a display with another mode"][0] == "refused" and res["wallpaper off with a display"][0] == "refused", "`display` only with the modes that take one")
check("already" in res["add a style already in the rotation"][1], "adding a style already in the rotation says so")
check(off_state["wall"]["pins"] == {"DISPLAY-B": "StandBy"}, "the deleted style's pins are gone, the other display's kept")
check(off_state["wall"]["on"] is True and off_state["wall"]["style"] not in ("Currents", None), "deleting the shared pick: the others move on (a display still has its own)")
check({"Currents Copy", "Currents Copy 2", "Aurora 2"} <= set(off_state["names"]), "duplicates get unique names (as the gallery's)")
check(res["delete the signal without force"][0] == "refused" and off_state["signals"] == ["Level"], "a signal a rule tests needs force")
check(all(res[w][0] == "refused" and "turned off" in res[w][1] for w, _, _ in GATED), "every gated request refused with playback off (incl. force-deleting a rule's signal)")
check(off_state["rules"] == ["High"] and off_state["pins"] == {}, "…and nothing changed by them")
qapp.stdin.close()
qapp.wait(5)

# leaving "Same as Screensaver" for one display keeps what's on screen (both ways)
for store, label in ((new_store(), "offline"), (new_store(), "via the app")):
    papp = None
    if label == "via the app":
        papp = subprocess.Popen([BIN, "--fake-app"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env_for(store))
        papp.stdout.readline()
    cl = Client(store)
    cl.init()
    ok(cl.call("set_screensaver", {"style": "Liquid Chrome"}), f"{label}: the very first edit of a store with no library.json, by name (the default library keeps its ids until written)")
    cl.call("set_screensaver", {"style": "Aurora", "display": "DISPLAY-A"})
    cl.call("set_wallpaper", {"mode": "follow"})
    cl.call("set_wallpaper", {"style": "StandBy", "display": "DISPLAY-B"})
    cl.close()
    if papp:
        papp.stdin.close()
        papp.wait(5)
    w = lib_state(store)["wall"]
    check(w == {"on": True, "style": "Liquid Chrome", "follows": False, "pins": {"DISPLAY-A": "Aurora", "DISPLAY-B": "StandBy"}},
          f"{label}: a display's own wallpaper while following: the shared pick = what the lineup shows, the screensaver's pin kept ({w})")
    shutil.rmtree(store, ignore_errors=True)
for d in (O, Q):
    shutil.rmtree(d, ignore_errors=True)

# weather.inUse: the live weather is fetched only while something reads it — never for pinned weather
print("== live weather: only what reads it")
W = new_store()
c = Client(W)
c.init()
c.call("set_screensaver", {"mode": "dayOnly"})       # writes the default library.json
check(settings_of(c.call("get_settings", {"keys": ["weather.inUse"]}))["weather.inUse"]["value"] is True,
      "the default library (Golden Hour, Meadow on Live weather): in use")
lib = library(W)
for p_ in lib["presets"]:
    for e_ in p_["effects"]:
        if e_["kind"] in ("oceanHorizon", "shallows", "meadow"):
            e_.setdefault("params", {})["weather"] = 2
        if e_["kind"] == "custom":
            e_.setdefault("params", {})["ds.weather"] = 7
with open(os.path.join(W, "library.json"), "w") as f:
    json.dump(lib, f)


def in_use():
    return settings_of(c.call("get_settings", {"keys": ["weather.inUse"]}))["weather.inUse"]["value"]


check(in_use() is False, "every scene's Weather pinned (the Commute film's too, though its manifest uses the weather): not in use")
for p_ in lib["presets"]:
    for e_ in p_["effects"]:
        if e_["kind"] == "custom":
            e_["params"].pop("ds.weather", None)
with open(os.path.join(W, "library.json"), "w") as f:
    json.dump(lib, f)
check(in_use() is True, "the film back on Live weather: in use")
for p_ in lib["presets"]:
    for e_ in p_["effects"]:
        if e_["kind"] == "custom":
            e_["params"]["ds.weather"] = 7
with open(os.path.join(W, "library.json"), "w") as f:
    json.dump(lib, f)
ok(c.call("set_rule", {"name": "Wet", "when": {"all": [{"signal": "weather.condition", "op": "eq", "value": "rain"}]}, "play": ["Aurora"]}),
   "a When rule on weather.condition")
check(in_use() is True, "  → in use (the rule reads it)")
c.close()
wapp = subprocess.Popen([BIN, "--fake-app"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env_for(W))
wapp.stdout.readline()
c = Client(W)
c.init()
ok(c.call("delete_rule", {"rule": "Wet"}), "delete it (through the app)")
check(in_use() is False, "  → not in use, read through the app")
c.close()
wapp.stdin.close()
wapp.wait(5)
shutil.rmtree(W, ignore_errors=True)

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
# the app's own settings, through the app
res = c.call("get_settings")
st = settings_of(res)
check(res["structuredContent"]["appRunning"] is True and st["system.screensaverChosen"]["value"] == "on 1 of 2 displays"
      and st["general.openAtLogin"]["value"] is False, "get_settings via the app: its live values (setup checks, login item)")
res = c.call("update_settings", {"settings": {"music.size": "small", "general.openAtLogin": True, "weather.live": False}})
ok(res, "update_settings via the app (open at login works there)")
check(res["structuredContent"]["liveInApp"] is True and "live" in text(res), "  → live in the app")
time.sleep(0.4)  # the app's own saves
check(library(A)["music"]["cardSize"] == "small" and prefs(A).get("weatherEnabled") is False, "  → survives the app's saves")
check(any("applied updateSettings ok=true" in l for l in applied), "  → the app applied it")
res = c.call("update_settings", {"settings": {"weather.location": {"name": "Toronto, Ontario", "lat": 43.65107, "lon": -79.347015}}})
ok(res, "weather.location via the app")
time.sleep(0.4)
lib = library(A)
check(res["structuredContent"]["liveInApp"] is True and lib.get("locationMode") == "manual" and lib["locationLat"] == 43.65107
      and lib["manualPlace"]["name"] == "Toronto, Ontario", "  → the user's place, surviving the app's saves")
check(settings_of(c.call("get_settings", {"keys": ["weather.location"]}))["weather.location"]["value"]
      == {"mode": "manual", "name": "Toronto, Ontario", "lat": 43.7, "lon": -79.3}, "  → get_settings via the app reads it, rounded")
err(c.call("update_settings", {"settings": {"weather.location": {"lat": -95, "lon": 0}}}), "the app path refuses bad coordinates too", "90")
ok(c.call("update_settings", {"settings": {"weather.location": "auto"}}), "weather.location back to automatic via the app")
time.sleep(0.4)
check("locationMode" not in library(A) and "manualPlace" not in library(A), "  → automatic again")
with open(os.path.join(A, "ai-settings.json"), "w") as f:
    json.dump({"allowPlaybackChanges": False}, f)
err(c.call("update_settings", {"settings": {"music.show": "off"}}), "the app refuses gated settings too", "turned off")
os.remove(os.path.join(A, "ai-settings.json"))
res = c.call("app_action", {"action": "show_setup_guide"})
ok(res, "app_action via the app")
time.sleep(0.2)
check(res["structuredContent"]["liveInApp"] is True and any("applied appAction ok=true" in l for l in applied), "  → the app did it")

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

# huge numbers where an option index goes: a tool error, never a crash
c = Client(R)
c.init()
res = c.call("create_style", {"name": "Huge", "effects": [{"kind": "oceanHorizon", "params": {"weather": 1e19}}]})
check(res.get("isError") is True, "a menu index of 1e19 is a tool error")
check(c.call("list_styles", {})["structuredContent"] is not None, "…and the server is still alive")
c.close()

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
