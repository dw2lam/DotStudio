//  ChangelogViews.swift — the release notes on screen (Changelog.swift parses them):
//
//    • WhatsNewSheet        — the one-time sheet after an update, on the main window. Classic:
//                             a stock-feeling sheet (app icon, "What's New in DotStudio 1.6.9",
//                             the release name, sections under SF Symbol headers). Retro: the
//                             panel, a lowercase legend and the version as an orange tag, the
//                             release name in the display face, an orange "continue" key.
//    • ReleaseNotesSection  — Settings › Updates › Release Notes: every release, newest first,
//                             one collapsible row each; the installed one marked and open.
//    • ChangelogReleaseBody — a release's clip (if it has one) and its sections and bullets
//                             (both of the above).
//    • ChangelogClip        — a release's bundled film (WhatsNewClip, Changelog.swift).

import SwiftUI
import AppKit

// MARK: - Inline text

/// One changelog line: inline Markdown (bold lead-ins, italics, `code`, links) in a text role.
/// Retro sets bold in Hanken Grotesk SemiBold and code in Source Code Pro (a bundled face has
/// no synthesized bold); Classic leaves both to the system font.
struct ChangelogText: View {
    let markdown: String
    var role: TextRole = .body
    @Environment(\.console) private var console
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let shown = console ? role.consoleChangelogCounterpart : role
        Text(attributed(shown))
            .textRole(shown)
            .tint(console ? ConsoleInk.signalInk : .accentColor)
            .wrapping()
    }

    private func attributed(_ role: TextRole) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard var s = try? AttributedString(markdown: markdown, options: options) else { return AttributedString(markdown) }
        guard console, role.face != nil else { return s }
        var strong = role; strong.face = "HankenGrotesk-SemiBold"
        var code = role; code.face = ConsoleFace.mono
        let strongFont = strong.font(typeSize), codeFont = code.font(typeSize)
        for run in s.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            if intent.contains(.code) { s[run.range].font = codeFont }
            else if intent.contains(.stronglyEmphasized) { s[run.range].font = strongFont }
        }
        return s
    }
}

private extension TextRole {
    /// Retro's face for a changelog line: running text stays mixed case (the legends are the
    /// lowercase parts).
    var consoleChangelogCounterpart: TextRole {
        switch style {
        case .callout, .caption, .caption2: return .consoleBodySmall
        default: return .consoleBody
        }
    }
}

extension TextRole {
    /// Retro's What's New title: the display face, large and light.
    static let consoleDisplay = TextRole(style: .largeTitle, points: 30, face: ConsoleFace.display)
}

// MARK: - A release's body

/// A release's sections and their bullets (nested bullets indented under theirs).
struct ChangelogReleaseBody: View {
    let release: Changelog.Release
    /// Smaller type and tighter spacing (Settings' rows).
    var compact = false
    @Environment(\.console) private var console

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? Space.s : Space.m) {
            ChangelogClip(release: release, compact: compact)
            ForEach(release.sections) { section in
                VStack(alignment: .leading, spacing: compact ? Space.xxs + 2 : Space.xs) {
                    if let heading = section.heading { header(heading, section) }
                    VStack(alignment: .leading, spacing: compact ? Space.xxs + 2 : Space.xs) {
                        ForEach(section.items) { item in ChangelogItemView(item: item, compact: compact, depth: 0) }
                    }
                    .padding(.leading, !console && section.heading != nil && !compact ? Space.l + 2 : 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func header(_ heading: String, _ section: Changelog.Section) -> some View {
        if console {
            // A printed legend with a short rule after it, as the decks' rows.
            HStack(spacing: Space.xs) {
                Text(heading).textRole(.legend).foregroundStyle(ConsoleInk.legend)
                Rectangle().fill(ConsoleInk.hairline).frame(height: 1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        } else {
            Label {
                Text(heading).textRole(compact ? .calloutEmphasis : .headline)
            } icon: {
                Image(systemName: section.symbol)
                    .foregroundStyle(section.tint)
                    .frame(width: compact ? 18 : Space.l, alignment: .leading)
            }
            .labelStyle(ChangelogHeaderLabelStyle())
            .accessibilityAddTraits(.isHeader)
        }
    }
}

/// A release's clip (its media line, mapped by WhatsNewClip to a bundled film) at the top of
/// its notes: muted and looping, 16:10 at the notes' width (narrower in Settings' rows), in the
/// light or dark the app wears; the poster under Reduce Motion and in renders (BundledFilm).
/// Retro: a screen set in a recessed well. Classic: rounded media with a hairline edge.
/// Nothing when the release has no clip — the media line's URL is never loaded.
private struct ChangelogClip: View {
    let release: Changelog.Release
    var compact = false
    @Environment(\.console) private var console
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let name = WhatsNewClip.filmName(for: release, dark: scheme == .dark) {
            Group {
                if console {
                    BundledFilm(name: name, fallback: ConsoleInk.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .padding(compact ? 4 : 6)
                        .consoleWell(cornerRadius: compact ? 5 : 7)
                } else {
                    let shape = RoundedRectangle(cornerRadius: compact ? Radius.s : Radius.m, style: .continuous)
                    BundledFilm(name: name, fallback: Color.primary.opacity(0.05))
                        .clipShape(shape)
                        .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                }
            }
            .frame(maxWidth: compact ? 440 : .infinity, alignment: .leading)
            .padding(.bottom, compact ? 0 : Space.xxs)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(release.media?.alt ?? "")
            .accessibilityAddTraits(.isImage)
        }
    }
}

/// Icon and title on one baseline, the icon in its own column.
private struct ChangelogHeaderLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            configuration.icon
            configuration.title
        }
    }
}

/// One item: a bullet (with its nested bullets), a paragraph or a note.
private struct ChangelogItemView: View {
    let item: Changelog.Item
    let compact: Bool
    let depth: Int
    @Environment(\.console) private var console

    private var role: TextRole { compact || depth > 0 ? .callout : .body }

    var body: some View {
        switch item.kind {
        case .paragraph:
            ChangelogText(markdown: item.text, role: role)
                .foregroundStyle(.secondary)
        case .note:
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                Image(systemName: "info.circle")
                    .foregroundStyle(console ? ConsoleInk.legend : Color.secondary)
                ChangelogText(markdown: item.text, role: .callout)
                    .foregroundStyle(.secondary)
            }
            .padding(Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: console ? 3 : Radius.xs, style: .continuous)
                .fill(console ? ConsoleInk.surface : Color.primary.opacity(0.05)))
        case .bullet:
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    marker
                    ChangelogText(markdown: item.text, role: role)
                }
                if !item.children.isEmpty {
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        ForEach(item.children) { ChangelogItemView(item: $0, compact: compact, depth: depth + 1) }
                    }
                    .padding(.leading, Space.m)
                }
            }
        }
    }

    @ViewBuilder private var marker: some View {
        if console {
            // A small square: orange at the top level, the legend grey under it.
            Rectangle()
                .fill(depth == 0 ? ConsoleInk.signal : ConsoleInk.legend)
                .frame(width: depth == 0 ? 5 : 4, height: depth == 0 ? 5 : 4)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] + 2 }
                .accessibilityHidden(true)
        } else {
            Text(depth == 0 ? "•" : "◦")
                .textRole(role)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - What's New sheet

/// The one-time sheet after an update (WhatsNew.Center decides; ContentView presents it).
struct WhatsNewSheet: View {
    /// Newest first: one release, or every release since the last one seen.
    let releases: [Changelog.Release]
    var windowSize: CGSize = CGSize(width: 1100, height: 760)
    let onContinue: () -> Void
    let onSeeAll: () -> Void
    @Environment(\.console) private var console

    /// "1.6.8", or "1.6.6 – 1.6.8" for several.
    private var versionSpan: String {
        let top = newest?.version ?? AppVersion.running
        guard multiple, let oldest = releases.last?.version else { return top }
        return "\(oldest) – \(top)"
    }

    static let width: CGFloat = 560
    static func height(for window: CGSize) -> CGFloat { max(min(640, window.height - 60), 360) }

    private var newest: Changelog.Release? { releases.first }
    private var multiple: Bool { releases.count > 1 }

    var body: some View {
        Group {
            if console { consoleBody } else { classicBody }
        }
        .frame(width: min(Self.width, max(windowSize.width - 40, 420)), height: Self.height(for: windowSize))
        // Esc closes it too (Return is Continue).
        .background {
            Button("Close", action: onContinue)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    // MARK: Classic

    private var classicBody: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    VStack(spacing: Space.xs) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 72, height: 72)
                            .accessibilityHidden(true)
                        Text("What's New in DotStudio \(newest?.version ?? AppVersion.running)")
                            .textRole(.pageTitle)
                            .wrapping(.center)
                            .accessibilityAddTraits(.isHeader)
                        if multiple {
                            Text("\(releases.count) updates since you last looked")
                                .textRole(.pageSubtitle)
                                .foregroundStyle(.secondary)
                                .wrapping(.center)
                        } else if let title = newest?.title, !title.isEmpty {
                            Text(title)
                                .textRole(.pageSubtitle)
                                .foregroundStyle(.secondary)
                                .wrapping(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, Space.xs)

                    ForEach(Array(releases.enumerated()), id: \.element.id) { i, r in
                        VStack(alignment: .leading, spacing: Space.m) {
                            if multiple {
                                if i > 0 { Divider().padding(.bottom, Space.xs) }
                                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                                    Text(r.label).textRole(.sectionTitle).monospacedDigit()
                                    if !r.title.isEmpty {
                                        Text(r.title).textRole(.sectionTitle).foregroundStyle(.secondary)
                                    }
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(.isHeader)
                            }
                            ChangelogReleaseBody(release: r)
                        }
                    }
                }
                .padding(.horizontal, Space.xl)
                .padding(.top, Space.xl)
                .padding(.bottom, Space.l)
            }
            Divider()
            HStack(spacing: Space.s) {
                Button("See All Updates", action: onSeeAll)
                    .buttonStyle(.link)
                    .help("Every release's notes, in Settings › Updates")
                Spacer(minLength: Space.s)
                Button(action: onContinue) {
                    Text("Continue").textRole(.body).frame(minWidth: 80)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.m)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Retro

    private var consoleBody: some View {
        VStack(spacing: 0) {
            // The strip: what this is, and the version as an orange tag.
            HStack(spacing: Space.xs) {
                Text("what's new").textRole(.legend).foregroundStyle(ConsoleInk.legend)
                Spacer(minLength: Space.xs)
                if multiple {
                    Text("\(releases.count) updates").textRole(.legend).foregroundStyle(ConsoleInk.legend)
                }
                ConsoleTag(text: newest?.version ?? AppVersion.running, fill: ConsoleInk.signal)
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.s)
            .background(ConsoleInk.surface)
            ConsoleHairline()

            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text("dotstudio \(versionSpan)")
                            .textRole(.legend).foregroundStyle(ConsoleInk.signalInk)
                        Text(multiple ? "Since you last looked" : (newest?.title.isEmpty == false ? newest!.title : "What's new"))
                            .textRole(.consoleDisplay)
                            .foregroundStyle(ConsoleInk.ink)
                            .wrapping()
                            .accessibilityAddTraits(.isHeader)
                    }
                    if multiple {
                        ForEach(releases) { r in
                            ConsoleModule {
                                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                                    ConsoleTag(text: r.label, fill: r.id == newest?.id ? ConsoleInk.signal : nil)
                                    if !r.title.isEmpty {
                                        Text(r.title).textRole(.consoleHeadline).foregroundStyle(ConsoleInk.ink).wrapping()
                                    }
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(.isHeader)
                                ChangelogReleaseBody(release: r)
                            }
                        }
                    } else if let r = newest {
                        ChangelogReleaseBody(release: r)
                    }
                }
                .padding(Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ConsoleHairline()
            HStack(spacing: Space.s) {
                Button(action: onSeeAll) {
                    Text("see all updates").textRole(.consoleKeySmall)
                }
                .buttonStyle(.plain)
                .foregroundStyle(ConsoleInk.signalInk)
                .underline()
                .help("Every release's notes, in Settings › Updates")
                Spacer(minLength: Space.s)
                Button(action: onContinue) {
                    Text("continue").textRole(.consoleKey)
                }
                .buttonStyle(.keycap(.signal, padding: EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20)))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.s)
        }
        .background(ConsoleInk.panel)
        .foregroundStyle(ConsoleInk.ink, ConsoleInk.legend)
    }
}

// MARK: - Settings › Updates › Release Notes

/// Every release, newest first, each a row that opens to its notes; the installed version is
/// marked and starts open. Classic: a grouped Form's disclosure rows. Retro: ruled rows with a
/// key-like header (version tag, title, an "installed" light).
struct ReleaseNotesSection: View {
    var changelog: Changelog = .bundled
    @Environment(\.console) private var console
    @State private var expanded: Set<String>?
    /// "See All Updates" (the What's New sheet) opens Settings › Updates scrolled to here.
    @ObservedObject private var center = WhatsNew.Center.shared

    private var installed: String { AppVersion.running }
    private var installedID: String? { changelog.release(for: installed)?.id }

    private func isOpen(_ r: Changelog.Release) -> Binding<Bool> {
        Binding(get: { (expanded ?? defaultOpen).contains(r.id) },
                set: { open in
                    var s = expanded ?? defaultOpen
                    if open { s.insert(r.id) } else { s.remove(r.id) }
                    expanded = s
                })
    }

    /// The installed release, or the newest when this version isn't in the notes.
    private var defaultOpen: Set<String> {
        if let id = installedID { return [id] }
        return changelog.releases.first.map { [$0.id] } ?? []
    }

    var body: some View {
        Section {
            if changelog.releases.isEmpty {
                Text("Release notes aren't available in this copy of DotStudio.")
                    .settingsText(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(changelog.releases) { r in
                Group {
                    if console {
                        ConsoleReleaseRow(release: r, installed: r.id == installedID, isOpen: isOpen(r))
                    } else {
                        ClassicReleaseRow(release: r, installed: r.id == installedID, isOpen: isOpen(r))
                    }
                }
                .background {
                    // The first row brings the section's top into view when asked.
                    if r.id == changelog.releases.first?.id, center.scrollToReleaseNotes {
                        ScrollIntoView(above: 56) { center.scrollToReleaseNotes = false }
                    }
                }
            }
        } header: {
            SettingsHeader("Release Notes")
        } footer: {
            SettingsNote("What changed in each version of DotStudio, newest first. After an update, its notes also show once when you open DotStudio.")
        }
    }
}

private struct ClassicReleaseRow: View {
    let release: Changelog.Release
    let installed: Bool
    @Binding var isOpen: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isOpen) {
            ChangelogReleaseBody(release: release, compact: true)
                .padding(.top, Space.xs)
                .padding(.bottom, Space.xxs)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                Text(release.label).textRole(.bodyEmphasis).monospacedDigit()
                if !release.title.isEmpty {
                    Text(release.title).textRole(.body).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: Space.xs)
                if let date = release.date {
                    Text(date).textRole(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if installed {
                    Text("Installed")
                        .textRole(.captionEmphasis)
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.green.opacity(0.15)))
                        .fixedSize()
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { isOpen.toggle() } }
            .accessibilityElement(children: .combine)
            .accessibilityValue(installed ? "Installed" : "")
        }
    }
}

private struct ConsoleReleaseRow: View {
    let release: Changelog.Release
    let installed: Bool
    @Binding var isOpen: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Button {
                withAnimation(Motion.pick(Motion.snappy, reduceMotion: reduceMotion)) { isOpen.toggle() }
            } label: {
                HStack(alignment: .center, spacing: Space.xs) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(hovering ? ConsoleInk.signalInk : ConsoleInk.legend)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 12)
                    ConsoleTag(text: release.label, fill: installed ? ConsoleInk.signal : nil)
                    if !release.title.isEmpty {
                        Text(release.title).textRole(.consoleTitle).foregroundStyle(ConsoleInk.ink).lineLimit(1)
                    }
                    Spacer(minLength: Space.xs)
                    if let date = release.date {
                        Text(date).textRole(.consoleMono).foregroundStyle(ConsoleInk.legend)
                    }
                    if installed {
                        ConsoleLED(on: true, color: ConsoleInk.green, label: "installed")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityLabel("\(release.label)\(release.title.isEmpty ? "" : ", \(release.title)")\(installed ? ", installed" : "")")
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")

            if isOpen {
                ChangelogReleaseBody(release: release, compact: true)
                    .padding(.leading, Space.l - 4)
                    .padding(.bottom, Space.xxs)
                    .transition(.opacity)
            }
        }
    }
}

/// Scrolls the enclosing scroll view (a grouped Form's, or Retro's ScrollView) so this view's
/// top sits `above` points below the top of the visible area, once, after layout. AppKit
/// rather than ScrollViewReader: a grouped Form on macOS ignores scrollTo for its rows.
private struct ScrollIntoView: NSViewRepresentable {
    var above: CGFloat = 0
    let done: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak v] in
            defer { done() }
            guard let v, let scroll = v.enclosingScrollView, let doc = scroll.documentView else { return }
            let clip = scroll.contentView
            let rect = v.convert(v.bounds, to: doc)
            let maxY = max(doc.frame.height - clip.bounds.height, 0)
            let fromTop = min(max((doc.isFlipped ? rect.minY : doc.frame.height - rect.maxY) - above, 0), maxY)
            let origin = NSPoint(x: clip.bounds.minX, y: doc.isFlipped ? fromTop : maxY - fromTop)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                clip.animator().setBoundsOrigin(origin)
            } completionHandler: {
                scroll.reflectScrolledClipView(clip)
            }
        }
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {}
}
