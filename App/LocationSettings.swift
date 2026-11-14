//  LocationSettings.swift — Settings ▸ Weather ▸ Location: where DotStudio thinks this Mac is
//  (the live weather, the real sun, moon and stars, the night style's sunset, Universe's marker,
//  Signals' {lat}/{lon}). Automatic = IP geolocation (AppModel.resolveLocation); or the user
//  searches for their place (PlaceSearch, Open-Meteo's geocoding) or types coordinates, and
//  AppModel.setLocation keeps it in the library.

import SwiftUI

/// "Toronto, Ontario" / "Automatic, from your internet connection" + Change… (the picker).
struct LocationRow: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var weather = WeatherService.shared
    @Environment(\.layout) private var layout
    @ScaledLength(relativeTo: .title2) private var iconBox: CGFloat = SettingsMetrics.iconBox
    @State private var picking = false

    var body: some View {
        let manual = model.library.usesManualLocation
        ReflowStack(rowAlignment: .center, columnAlignment: .trailing, spacing: layout.itemGap) {
            HStack(alignment: .center, spacing: layout.iconGap) {
                Image(systemName: manual ? "mappin.and.ellipse" : "location")
                    .foregroundStyle(.secondary)
                    .scaledFont { .scaled(.title2, $0) }
                    .frame(width: iconBox, alignment: .leading)
                VStack(alignment: .leading, spacing: layout.labelGap) {
                    Text(title).textRole(.bodyEmphasis).wrapping()
                    Text(manual ? "Set by you" : "Automatic, from your internet connection")
                        .textRole(.caption)
                        .foregroundStyle(.secondary)
                        .wrapping()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Location: \(title), \(manual ? "set by you" : "automatic")")
            Button(scaled: "Change\u{2026}") { picking = true }
                .help("Search for your city, or go back to the location from your internet connection")
                .popover(isPresented: $picking, arrowEdge: .bottom) {
                    LocationPicker(current: manual ? model.library.manualPlace : nil,
                                   pick: { model.setLocation($0); picking = false },
                                   automatic: { model.setLocation(nil); picking = false },
                                   close: { picking = false })
                        .adaptiveLayout()   // the popover is its own root
                }
        }
    }

    /// The place's name, else what's known about it.
    private var title: String {
        if let name = model.library.locationPlaceName { return name }
        if let r = weather.reading?.place { return "\(r) area" }
        if let loc = model.locationTuple { return NamedPlace.coordinateName(loc.lat, loc.lon) }
        return "Finding your location\u{2026}"
    }
}

/// The Change… popover: search Open-Meteo's places (or type coordinates) and pick one, or go
/// back to the internet connection's location.
struct LocationPicker: View {
    @Environment(\.layout) private var layout
    @StateObject private var search: PlaceSearchModel
    @FocusState private var fieldFocused: Bool
    @Environment(\.dismiss) private var dismiss
    /// The result Return picks: the first, moved with ↑ ↓ (or the pointer) while typing.
    @State private var highlighted: Int
    /// When ↑ ↓ last moved it: rows the list then scrolls under a resting pointer don't take it.
    @State private var keyMovedAt = Date.distantPast
    @ScaledLength(relativeTo: .body) private var width: CGFloat = Space.grid(85)          // 340
    @ScaledLength(relativeTo: .body) private var listMaxHeight: CGFloat = Space.grid(80)  // 320
    /// The user's own place now (nil = automatic).
    let current: NamedPlace?
    let pick: (NamedPlace) -> Void
    let automatic: () -> Void
    /// Escape: closes the popover (else the presentation's dismiss).
    let close: (() -> Void)?

    /// `highlighted`: the result highlighted at first (UI shots; else the first).
    init(current: NamedPlace?, search: PlaceSearchModel? = nil, highlighted: Int = 0,
         pick: @escaping (NamedPlace) -> Void, automatic: @escaping () -> Void, close: (() -> Void)? = nil) {
        self.current = current
        self.close = close
        self.pick = pick
        self.automatic = automatic
        _search = StateObject(wrappedValue: search ?? PlaceSearchModel())
        _highlighted = State(initialValue: highlighted)
    }

    private var items: [PlaceResult] {
        if case .results(let r) = search.state { return r }
        return []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: layout.controlGap) {
                Text("Set Your Location").textRole(.headline).wrapping()
                    .accessibilityAddTraits(.isHeader)
                TextField("Search", text: $search.query, prompt: Text("City or town"))
                    .textFieldStyle(.roundedBorder)
                    .textRole(.body)
                    .focused($fieldFocused)
                    // Keys while typing: ↑ ↓ move through the results, Return picks the
                    // highlighted one, Escape closes (in a text field it would otherwise only
                    // ask for completions).
                    .onSubmit { if items.indices.contains(highlighted) { pick(items[highlighted].place) } }
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.upArrow) { move(-1) }
                    .onKeyPress(.escape) { if let close { close() } else { dismiss() }; return .handled }
                    .accessibilityLabel("Search for a place")
                    .accessibilityHint(items.isEmpty ? "" : "Up and down arrows choose a result; Return uses it")
            }
            .padding(layout.cardPadding)
            Divider()
            results
            Divider()
            VStack(alignment: .leading, spacing: layout.controlGap) {
                if current != nil {
                    Button(scaled: "Use My Internet Connection", action: automatic)
                        .help("Go back to the approximate location from your internet connection")
                } else {
                    Label("Using your internet connection", systemImage: "checkmark")
                        .textRole(.body)
                        .foregroundStyle(.secondary)
                }
                Text("That location is approximate, from your IP address. Places by Open-Meteo (GeoNames).")
                    .textRole(.caption).foregroundStyle(.secondary).wrapping()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(layout.cardPadding)
        }
        .frame(width: width)
        // Ready to type (a reopened picker keeps nothing, so this is always an empty field).
        .onAppear { if search.query.isEmpty { fieldFocused = true } }
        // New results: Return picks the first again.
        .onChange(of: items.map(\.id)) { highlighted = 0 }
    }

    private func move(_ by: Int) -> KeyPress.Result {
        guard !items.isEmpty else { return .ignored }
        highlighted = min(max(highlighted + by, 0), items.count - 1)
        keyMovedAt = Date()
        return .handled
    }

    @ViewBuilder private var results: some View {
        switch search.state {
        case .idle:
            message("Type a city or town \u{2014} or coordinates, like 43.65, -79.38.")
        case .searching:
            HStack(spacing: layout.controlGap) {
                ProgressView().controlSize(.small)
                Text("Searching\u{2026}").textRole(.caption).foregroundStyle(.secondary)
            }
            .padding(layout.cardPadding)
        case .noMatch:
            message("No places match \u{201C}\(search.query.trimmingCharacters(in: .whitespaces))\u{201D}.")
        case .failed(let why):
            VStack(alignment: .leading, spacing: layout.controlGap) {
                Text("Couldn't search: \(why)").textRole(.caption).foregroundStyle(.orange).wrapping()
                Button(scaled: "Retry") { search.retry() }
            }
            .padding(layout.cardPadding)
        case .results(let items):
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, r in row(r, index: i).id(r.id) }
                    }
                    .padding(.vertical, layout.labelGap)
                }
                .onChange(of: highlighted) {
                    if items.indices.contains(highlighted) { proxy.scrollTo(items[highlighted].id) }
                }
            }
            .frame(maxHeight: listMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func message(_ text: String) -> some View {
        Text(text).textRole(.caption).foregroundStyle(.secondary).wrapping()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(layout.cardPadding)
    }

    private func row(_ r: PlaceResult, index: Int) -> some View {
        let isCurrent = current.map { abs($0.lat - r.lat) < 1e-4 && abs($0.lon - r.lon) < 1e-4 } ?? false
        return Button { pick(r.place) } label: {
            HStack(alignment: .center, spacing: layout.controlGap) {
                VStack(alignment: .leading, spacing: layout.labelGap / 2) {
                    Text(r.name).textRole(.bodyEmphasis).wrapping()
                    if !r.detail.isEmpty {
                        Text(r.detail).textRole(.caption).foregroundStyle(.secondary).wrapping()
                    }
                }
                Spacer(minLength: 0)
                if isCurrent {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        .accessibilityLabel("In use")
                }
            }
            .padding(.horizontal, layout.cardPadding)
            .padding(.vertical, layout.controlGap)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlaceRowStyle(highlighted: index == highlighted))
        // The pointer moves the highlight too: one highlighted row, whichever moved it last.
        .onHover { if $0 && Date().timeIntervalSince(keyMovedAt) > 0.5 { highlighted = index } }
        .help("Use \(r.place.name)")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(index == highlighted ? .isSelected : [])
    }
}

/// A list row: highlighted (the one Return picks — the keyboard's or the pointer's), darker
/// while pressed.
private struct PlaceRowStyle: ButtonStyle {
    let highlighted: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : highlighted ? 0.07 : 0))
    }
}
