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
                                   automatic: { model.setLocation(nil); picking = false })
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
    @ScaledLength(relativeTo: .body) private var width: CGFloat = Space.grid(85)          // 340
    @ScaledLength(relativeTo: .body) private var listMaxHeight: CGFloat = Space.grid(80)  // 320
    /// The user's own place now (nil = automatic).
    let current: NamedPlace?
    let pick: (NamedPlace) -> Void
    let automatic: () -> Void

    init(current: NamedPlace?, search: PlaceSearchModel? = nil,
         pick: @escaping (NamedPlace) -> Void, automatic: @escaping () -> Void) {
        self.current = current
        self.pick = pick
        self.automatic = automatic
        _search = StateObject(wrappedValue: search ?? PlaceSearchModel())
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
                    .onSubmit { if case .results(let r) = search.state, let first = r.first { pick(first.place) } }
                    .accessibilityLabel("Search for a place")
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
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { r in row(r) }
                }
                .padding(.vertical, layout.labelGap)
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

    private func row(_ r: PlaceResult) -> some View {
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
        .buttonStyle(PlaceRowStyle())
        .help("Use \(r.place.name)")
        .accessibilityElement(children: .combine)
    }
}

/// A list row that highlights under the pointer and while pressed.
private struct PlaceRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PlaceRowBody(configuration: configuration)
    }
}

private struct PlaceRowBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.06 : 0))
            .onHover { hovering = $0 }
    }
}
