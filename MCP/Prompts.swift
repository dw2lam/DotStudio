//  Prompts.swift — MCP prompts: ready-made starting points a client can offer the user.

import Foundation

enum Prompts {
    struct Arg { let name: String; let description: String; let required: Bool }
    struct Prompt { let name: String; let title: String; let description: String; let args: [Arg]; let text: ([String: String]) -> String }

    static let common = """
    Work like a careful designer. First call get_started, then read_guide("style/dotstudio") and any user guides it lists. \
    Pick scenes with list_scenes / describe_scene (or duplicate a close built-in from list_styles). Create the style, then \
    preview_style a still and a contact sheet (frames: 6) and judge them honestly against the style guide — iterate with \
    update_style until it's calm, premium and readable. Check benchmark_style. Show me the final preview and explain the \
    choices in two or three sentences. Don't change my screensaver or wallpaper unless I say so — ask at the end.
    """

    static let all: [Prompt] = [
        Prompt(name: "design-a-screensaver", title: "Design a screensaver",
               description: "Design a new DotStudio screensaver from a mood, colours and a subject.",
               args: [Arg(name: "mood", description: "How it should feel (e.g. calm, cosy, focused, dreamy).", required: true),
                      Arg(name: "colours", description: "Palette wishes (e.g. deep teal and warm amber).", required: false),
                      Arg(name: "subject", description: "What it shows (e.g. the sea at dusk, a big clock, flowers).", required: false)]) { a in
            var s = "Design a DotStudio screensaver that feels \(a["mood"] ?? "calm")"
            if let c = a["colours"], !c.isEmpty { s += ", in \(c)" }
            if let sub = a["subject"], !sub.isEmpty { s += ", showing \(sub)" }
            return s + ".\n\n" + common
        },
        Prompt(name: "match-my-wallpaper", title: "Match my wallpaper",
               description: "Make a screensaver whose palette and mood match the user's current desktop picture or a described image.",
               args: [Arg(name: "description", description: "Describe the wallpaper (colours, subject), or attach/paste it if your client can.", required: false)]) { a in
            let d = a["description"].flatMap { $0.isEmpty ? nil : $0 } ?? "my current desktop picture (ask me to describe or attach it if you can't see it)"
            return """
            Make a DotStudio screensaver that belongs with \(d). Pull 2–4 colours from it (keep them dark-first: the darkest \
            becomes the ground, one accent only), match its mood and level of detail, and choose a scene whose subject \
            complements it rather than copying it. It should feel like the wallpaper went to sleep.

            """ + common
        },
        Prompt(name: "brand-screensaver", title: "Brand screensaver",
               description: "A screensaver in a brand's colours and tone, following a brand guide the user added to DotStudio's guides folder.",
               args: [Arg(name: "guide", description: "The user guide id (user/<name>) from list_guides.", required: true),
                      Arg(name: "use", description: "Where it runs (office lobby display, team Macs, a booth).", required: false)]) { a in
            """
            Read the brand guide read_guide("\(a["guide"] ?? "user/brand")") and make a DotStudio screensaver in that brand's \
            colours and tone\(a["use"].map { " for \($0)" } ?? ""). The brand sets the palette and voice; DotStudio's guide \
            still sets the motion, calm and burn-in rules (no static logo at full brightness — drift or fade it). If the brand \
            has a wordmark, the Bounce scene's logo_text or a quiet clock may carry it; never a busy logo wall.

            """ + common
        },
    ]

    static func list() -> [JSONObject] {
        all.map { p in
            ["name": p.name, "title": p.title, "description": p.description,
             "arguments": p.args.map { ["name": $0.name, "description": $0.description, "required": $0.required] }]
        }
    }

    static func get(_ name: String, _ args: [String: String]) throws -> JSONObject {
        guard let p = all.first(where: { $0.name == name }) else {
            throw ToolError("Unknown prompt \(name). Prompts: \(all.map(\.name).joined(separator: ", ")).")
        }
        for a in p.args where a.required && (args[a.name] ?? "").isEmpty {
            throw ToolError("Prompt \(name) needs the argument \"\(a.name)\".")
        }
        return ["description": p.description,
                "messages": [["role": "user", "content": ["type": "text", "text": p.text(args)]]]]
    }
}
