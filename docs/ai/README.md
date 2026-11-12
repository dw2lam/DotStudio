# Make screensavers with AI

DotStudio ships an MCP server, `dotstudio-mcp`, inside the app. Any assistant that speaks the
[Model Context Protocol](https://modelcontextprotocol.io) — Claude Desktop, Claude Code, Cursor, VS Code, Codex CLI and
others — can use it to design screensavers with you:

- it reads DotStudio's **guides** first (the house style, every scene's settings, power and burn-in rules, and any guides
  you add, such as a brand guide);
- builds a **style** from the built-in scenes and looks (or, with the scene-engine update, writes its own shader scene);
- **previews** it as images (any moment, clock time, weather, with the music card) and checks its **GPU cost** at 5K;
- and, only when you ask, sets it as your **screensaver** or **live wallpaper**. Each change shows a small notice in
  DotStudio with Undo, and Settings ▸ AI has a switch that keeps the AI from changing what plays at all.

Everything runs on your Mac. The server is a small signed helper inside DotStudio.app; it talks to your AI app over
stdin/stdout and to DotStudio through your own library folder. It doesn't use the network, except for `pull_engine`.

## Set up

The server lives at `/Applications/DotStudio.app/Contents/MacOS/dotstudio-mcp` (move DotStudio to Applications first:
your AI app remembers this path).

### Claude Desktop

DotStudio ▸ Settings ▸ AI ▸ **Add to Claude Desktop**, then quit and reopen Claude. DotStudio adds one entry to
`~/Library/Application Support/Claude/claude_desktop_config.json`, keeps everything else in it, and saves a backup next
to it first. By hand, the entry is:

```json
{
  "mcpServers": {
    "dotstudio": { "command": "/Applications/DotStudio.app/Contents/MacOS/dotstudio-mcp", "args": [] }
  }
}
```

**Desktop Extension (.mcpb).** `docs/ai/mcpb/build.sh` packs `DotStudio.mcpb`: double-click it, or drag it onto
Claude Desktop ▸ Settings ▸ Extensions. The extension is a small launcher that finds DotStudio.app and runs its server,
so it keeps working across DotStudio updates.

### Claude Code

DotStudio ▸ Settings ▸ AI ▸ **Copy Command**, or:

```sh
claude mcp add dotstudio -- "/Applications/DotStudio.app/Contents/MacOS/dotstudio-mcp"
```

### Cursor

`~/.cursor/mcp.json` (or **Settings ▸ MCP ▸ Add new MCP server**):

```json
{ "mcpServers": { "dotstudio": { "command": "/Applications/DotStudio.app/Contents/MacOS/dotstudio-mcp" } } }
```

### VS Code (Copilot agent mode)

`.vscode/mcp.json` in a workspace, or **MCP: Add Server** ▸ Command (stdio):

```json
{ "servers": { "dotstudio": { "type": "stdio", "command": "/Applications/DotStudio.app/Contents/MacOS/dotstudio-mcp" } } }
```

### Codex CLI

`~/.codex/config.toml`:

```toml
[mcp_servers.dotstudio]
command = "/Applications/DotStudio.app/Contents/MacOS/dotstudio-mcp"
```

### Any other MCP client

Launch the command above with no arguments over stdio. DotStudio ▸ Settings ▸ AI ▸ **Copy JSON** gives the usual
`mcpServers` snippet. `dotstudio-mcp --print-config` prints it too.

## Try it

Ask for what you'd like to see, the way you'd brief a designer:

- "A calm ocean at dusk, and I want to see the time big."
- "Use our brand guide and make one for the office Macs."
- "Match my wallpaper — a foggy pine forest, teal-grey and soft."
- "A little pixel cat sleeping on an LED panel."
- "Port my Shadertoy *Slow Tide* (I wrote it, MIT)."
- "Something photoreal: a café window at night in the rain."

Clients that support MCP prompts also offer **Design a screensaver**, **Match my wallpaper** and **Brand screensaver**.

[`examples/`](examples) has six recorded sessions: the prompt, every tool call and the server's real answers, the
resulting style JSON and its previews.

| Example | What it shows |
|---|---|
| [Calm ocean at dusk, with a big clock](examples/calm-ocean-clock.md) | Reading the guide, a dusk sea + a matching clock in rotation, contact sheet, benchmark, setting the screensaver |
| [My brand colours, from a guide](examples/brand-guide.md) | A user guide steering the palette, iterating after a preview, exporting a share file |
| [Match my wallpaper](examples/match-my-wallpaper.md) | A scene + a look, weather and time of day |
| [A pixel cat on an LED panel](examples/pixel-cat-led.md) | A custom scene on the `cells` engine (scene-engine update) |
| [Port a Shadertoy I wrote](examples/port-shadertoy.md) | Pulling the `shadertoy` engine, licence in the manifest |
| [A photoreal rainy café window](examples/rainy-cafe-film.md) | Film scenes: Blender check, a new set with CC0 assets, the look (bloom, halation, live grain), stills for approval, a background loop render, install |

## Your own guides

Put Markdown files in `~/Library/Application Support/DotStudio/guides/` (Settings ▸ AI ▸ **Open Guides Folder**): a
brand guide, colours you love, things you never want to see. The AI lists them as `user/<file name>`, reads them before
designing, and follows them — they set the palette and tone; DotStudio's own rules on motion, burn-in and power still
apply.

## What the AI can do

| Area | Tools |
|---|---|
| Orientation | `get_started`, `list_guides`, `read_guide` (guides are also MCP resources: `dotstudio://guides/<id>`) |
| Catalog | `list_scenes`, `describe_scene` |
| Your library | `list_styles`, `get_style`, `create_style`, `update_style`, `duplicate_style`, `delete_style` (only styles the AI made, unless you confirm), `export_style`, `import_style` |
| Seeing it | `preview_style` (PNG, or a contact sheet over time), `benchmark_style` (GPU ms at 5K) |
| What plays | `list_displays`, `set_screensaver`, `set_wallpaper` (per display too) — these change your Mac |
| Custom scenes | `list_engines`, `pull_engine`, `create_custom_scene`, `update_custom_scene`, `validate_custom_scene`, `list_custom_scenes` |
| Film scenes | `film_status`, `list_film_templates`, `create_film_scene` (template + params + look: bloom, halation, live grain — or a new set), `get_film_scene`, `update_film_scene`, `render_film_stills`, `render_film_loop`, `film_job_status`, `cancel_film_job` |

Custom and film scenes need DotStudio's scene-engine update and the film engine; until then those tools say so.

## How it stays out of your way

- **While DotStudio runs**, every change goes through the app itself (a private socket in its library folder), so the
  gallery updates live and nothing you're editing is overwritten. **While it doesn't**, the server edits the library
  file directly, under the same lock the app takes when it starts.
- **Previews render offscreen** with DotStudio's own renderer; nothing appears on your screen.
- **Film renders** run in the background at low priority and keep going if you close the chat; cancel them any time.
- **Never without asking:** the server's instructions tell the AI to change your screensaver or wallpaper only when you
  ask; the Settings switch enforces it.

## For developers

- Source: `MCP/` (server, tools, previews), `Shared/AI/` (bridge, lock, library edits shared with the app),
  `App/AIBridgeHost.swift`, `App/AISettingsSection.swift`, `Guides/`.
- Protocol: MCP over stdio, newline-delimited JSON-RPC 2.0; versions 2025-11-25, 2025-06-18, 2025-03-26, 2024-11-05.
  Tools return text, `structuredContent` and PNG image content; strict JSON Schemas; argument errors come back as tool
  errors the model can fix.
- Tests: `tools/mcp-selftest/run.sh` (200+ end-to-end checks against throwaway stores, including a stand-in running app
  that would overwrite direct writes). Examples: `python3 tools/mcp-selftest/examples.py <dotstudio-mcp> . <outDir>`.
- Settings guides: `tools/guides/generate.sh` regenerates `Guides/settings/*.md` from the scene catalog (the server
  also generates them live, and the self-test fails when the checked-in copies are stale).
