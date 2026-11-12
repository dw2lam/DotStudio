//  dotstudio-mcp — DotStudio's MCP server (stdio). Ships inside the app at
//  DotStudio.app/Contents/MacOS/dotstudio-mcp: in Contents/MacOS, Bundle.main is the app
//  bundle, so the renderer finds the app's default.metallib, planet maps, the embedded saver's
//  photos and Resources/Guides exactly as the app does — no resource plumbing of its own.
//
//  usage: dotstudio-mcp                         serve MCP on stdin/stdout (what clients launch)
//         dotstudio-mcp --version
//         dotstudio-mcp --print-config          the JSON snippet / Claude Code command for this binary
//         dotstudio-mcp --install-claude-desktop [--config <path>]   merge into Claude Desktop's config
//         dotstudio-mcp --write-settings-guides <dir>                 the generated settings/*.md
//  test-only: --fake-app (a stand-in app that owns the library in memory and serves the AI
//  bridge, for tools/mcp-selftest), --test-film-worker (the fake film render).
//  Store: DOTSTUDIO_STORE_DIR, else ~/Library/Application Support/DotStudio.

import AppKit
import Foundation

func executablePath() -> String {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buf = [CChar](repeating: 0, count: Int(size) + 1)
    _NSGetExecutablePath(&buf, &size)
    return URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath().path
}

// Always an explicit store: SharedStore's real-home path would otherwise try the pre-1.3
// container migration, which macOS may answer with a privacy prompt for this helper.
if ProcessInfo.processInfo.environment["DOTSTUDIO_STORE_DIR"] == nil {
    setenv("DOTSTUDIO_STORE_DIR", SharedStore.sharedDir.path, 1)
}

var argv = Array(CommandLine.arguments.dropFirst())
let me = executablePath()

switch argv.first {
case "--version":
    print("dotstudio-mcp \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
    exit(0)
case "--print-config":
    print(ClaudeDesktopConfig.snippet(command: me))
    print("\nClaude Code:\n  " + ClaudeDesktopConfig.claudeCodeCommand(command: me))
    exit(0)
case "--install-claude-desktop":
    var url = ClaudeDesktopConfig.defaultURL
    if let i = argv.firstIndex(of: "--config"), i + 1 < argv.count { url = URL(fileURLWithPath: argv[i + 1]) }
    switch ClaudeDesktopConfig.install(command: me, at: url) {
    case .success(.unchanged): print("unchanged: \(url.path) already has mcpServers.dotstudio → \(me)")
    case .success(.added(let backup)): print("added mcpServers.dotstudio to \(url.path)" + (backup.map { " (backup: \($0.path))" } ?? ""))
    case .failure(let f): FileHandle.standardError.write(Data((f.description + "\n").utf8)); exit(1)
    }
    exit(0)
case "--write-settings-guides":
    guard argv.count > 1 else { print("usage: --write-settings-guides <dir>"); exit(2) }
    do {
        let files = try SettingsGuides.write(to: URL(fileURLWithPath: argv[1]))
        print("wrote \(files.count) guides to \(argv[1])")
        exit(0)
    } catch { print("failed: \(error)"); exit(1) }
case "--fake-app":
    FakeApp.run(Array(argv.dropFirst()))
case "--test-film-worker":
    FakeFilmToolkit.runWorker(Array(argv.dropFirst()))
default:
    break
}

// MARK: Serve

let store = SharedStore(role: .app)
let server = MCPServer()
let scenesAPI = makeCustomScenesAPI(store: store.baseDir)
let library = LibraryAccess(store: store)
let toolbox = Toolbox(lib: library, preview: PreviewRenderer(store: store),
                      guides: Guides(store: store.baseDir, scenes: scenesAPI),
                      scenes: scenesAPI, film: makeFilmToolkit(store: store.baseDir))
server.tools = toolbox.all
server.resources = { toolbox.guides.resources() }
server.readResource = { try toolbox.guides.readResource($0) }
server.prompts = { Prompts.list() }
server.getPrompt = { try Prompts.get($0, $1) }
server.instructions = """
DotStudio designs calm, living screensavers and live wallpapers for the user's Mac. Call get_started first, and \
read_guide("style/dotstudio") before designing anything. Preview (preview_style) and benchmark (benchmark_style) before \
presenting a style. set_screensaver and set_wallpaper change the user's Mac: only use them when the user asks.
"""
// The client's name (Claude, Cursor…) labels the app's notices.
library.clientName = { server.clientName }
server.log("serving \(toolbox.all.count) tools; store \(store.baseDir.path)")
server.run()
