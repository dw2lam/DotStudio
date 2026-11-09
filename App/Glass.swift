//  Glass.swift — Liquid Glass on macOS 26+, tasteful materials on macOS 14–15,
//  and the app's motion vocabulary. Call sites use these wrappers only, so the
//  availability checks live in one place.

import SwiftUI

// MARK: - Surfaces

enum GlassStyle {
    /// Default glass: cards, bars, inspector.
    case regular
    /// Barely-there glass for controls floating over imagery (tile action bars, badges).
    case clear
}

extension View {
    /// A glass surface in `shape`. `tint` colors it; `interactive` makes it react to the pointer.
    @ViewBuilder
    func glassSurface<S: Shape>(_ style: GlassStyle = .regular, in shape: S,
                                tint: Color? = nil, interactive: Bool = false) -> some View {
        // Offscreen UI shots (Shots.swift): Liquid Glass draws nothing in a never-ordered-in
        // window, so cards and capsules vanished from the renders and their edges couldn't be
        // judged. There the material fallback stands in, so the shapes are visible.
        if #available(macOS 26, *), !OffscreenCapture.isActive {
            self.glassEffect(makeGlass(style, tint: tint, interactive: interactive), in: shape)
        } else {
            self.background {
                ZStack {
                    shape.fill(style == .clear ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(.regularMaterial))
                    if let tint { shape.fill(tint.opacity(0.85)) }
                }
            }
            .overlay(shape.strokeBorderCompat(Color.white.opacity(style == .clear ? 0.22 : 0.14)))
            .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
        }
    }

    /// Glass card: the large, softly rounded panels (destination cards, inspector).
    func glassCard(cornerRadius: CGFloat = 22, tint: Color? = nil) -> some View {
        glassSurface(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), tint: tint)
    }

    /// Ties sibling glass shapes together so they blend and morph (macOS 26).
    @ViewBuilder
    func glassID<ID: Hashable>(_ id: ID, in ns: Namespace.ID) -> some View {
        if #available(macOS 26, *) { self.glassEffectID(id, in: ns) } else { self }
    }
}

@available(macOS 26, *)
private func makeGlass(_ style: GlassStyle, tint: Color?, interactive: Bool) -> Glass {
    var g: Glass = style == .clear ? .clear : .regular
    if let tint { g = g.tint(tint) }
    if interactive { g = g.interactive() }
    return g
}

private extension Shape {
    /// `strokeBorder` needs InsettableShape; a plain stroke is fine for a hairline.
    func strokeBorderCompat(_ color: Color) -> some View {
        self.stroke(color, lineWidth: 0.75)
    }
}

/// Groups glass shapes so they render together and morph into each other (macOS 26).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - Buttons

enum GlassButtonKind { case normal, prominent }

extension View {
    /// `.glass` / `.glassProminent` on macOS 26, bordered styles before.
    @ViewBuilder
    func glassButton(_ kind: GlassButtonKind = .normal) -> some View {
        if #available(macOS 26, *), !OffscreenCapture.isActive {
            switch kind {
            case .normal: self.buttonStyle(.glass)
            case .prominent: self.buttonStyle(.glassProminent)
            }
        } else {
            switch kind {
            case .normal: self.buttonStyle(.bordered)
            case .prominent: self.buttonStyle(.borderedProminent)
            }
        }
    }

    /// Lets an edge-to-edge image bleed softly under adjacent glass (macOS 26).
    @ViewBuilder
    func extendsUnderGlass() -> some View {
        if #available(macOS 26, *) { self.backgroundExtensionEffect() } else { self }
    }

    /// Softens where scrolling content meets the toolbar (macOS 26).
    @ViewBuilder
    func softScrollEdges() -> some View {
        if #available(macOS 26, *) { self.scrollEdgeEffectStyle(.soft, for: .top) } else { self }
    }

    /// No edge effects on a scroll view nested in another (a sideways strip of chips): it
    /// inherits the page's soft top edge, which would draw a frosted band behind the strip.
    @ViewBuilder
    func noScrollEdgeEffects() -> some View {
        if #available(macOS 26, *) { self.scrollEdgeEffectHidden(true, for: .all) } else { self }
    }
}

/// A plain, borderless icon button sized for glass bars.
struct GlassIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .frame(width: size, height: size)
            .contentShape(Circle())
            .background(Circle().fill(Color.white.opacity(hovering ? 0.22 : 0)))
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
            .animation(Motion.snappy, value: hovering)
            .onHover { hovering = $0 }
    }
}

// MARK: - Motion

enum Motion {
    /// Design-review slow motion (DOTSTUDIO_DEMO_SLOWMO=<factor>); 1 otherwise.
    static let slow: Double = ProcessInfo.processInfo.environment["DOTSTUDIO_DEMO_SLOWMO"].flatMap(Double.init) ?? 1
    /// Hover and press feedback.
    static let snappy = Animation.spring(response: 0.28 * slow, dampingFraction: 0.82)
    /// Layout changes: filters, playlist edits, reveals.
    static let smooth = Animation.spring(response: 0.42 * slow, dampingFraction: 0.86)
    /// Big moves: gallery ↔ editor.
    static let hero = Animation.spring(response: 0.5 * slow, dampingFraction: 0.86)
    /// What everything collapses to under Reduce Motion: a short cross-fade.
    static let reduced = Animation.easeInOut(duration: 0.18)

    /// `animation`, or a plain fade when the user asked for less motion.
    static func pick(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? reduced : animation
    }

    /// Reads the system setting directly — for code outside a View body.
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// withAnimation that honours Reduce Motion.
    @discardableResult
    static func run<R>(_ animation: Animation = smooth, _ body: () throws -> R) rethrows -> R {
        try withAnimation(pick(animation, reduceMotion: reduceMotion), body)
    }
}

extension View {
    /// `.animation(_:value:)` that degrades to a cross-fade under Reduce Motion.
    func motion<V: Equatable>(_ animation: Animation = Motion.smooth, value: V) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V
    func body(content: Content) -> some View {
        content.animation(Motion.pick(animation, reduceMotion: reduceMotion), value: value)
    }
}

/// Insert/remove transitions that drop scale/offset under Reduce Motion.
extension AnyTransition {
    static func lift(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94, anchor: .center))
    }

    static func reveal(reduceMotion: Bool, edge: Edge = .top) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: edge)).combined(with: .scale(scale: 0.98, anchor: .top))
    }
}
