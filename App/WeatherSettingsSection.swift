//  WeatherSettingsSection.swift — Settings › Weather: the live weather Ocean Horizon and Shallows
//  styles set to "Live" show (App/Weather/WeatherService.swift fetches it; Shared/Weather draws it),
//  and the Location everything place-bound uses — automatic (IP, AppModel.resolveLocation) or set
//  by the user with a search (LocationPicker, App/Weather/PlaceSearch.swift).

import SwiftUI

struct WeatherSettingsSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var weather = WeatherService.shared
    @Environment(\.layout) private var layout
    @ScaledLength(relativeTo: .title2) private var iconBox: CGFloat = SettingsMetrics.iconBox

    var body: some View {
        Section {
            Toggle("Live weather", isOn: $weather.enabled)
                .formSwitchSize()
            if weather.enabled {
                // One row when it fits; Retry drops under the status when it doesn't.
                ReflowStack(rowAlignment: .center, columnAlignment: .trailing, spacing: layout.itemGap) {
                    HStack(alignment: .center, spacing: layout.iconGap) {
                        Image(systemName: symbol)
                            .symbolRenderingMode(.multicolor)
                            .foregroundStyle(isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                            .scaledFont { .scaled(.title2, $0) }
                            .frame(width: iconBox, alignment: .leading)
                        // (Re-read every minute, so "updated 5 min ago" keeps counting.)
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            VStack(alignment: .leading, spacing: layout.labelGap) {
                                Text(headline(now: context.date))
                                    .settingsText(.bodyEmphasis)
                                    .wrapping()
                                Text(detail(now: context.date))
                                    .settingsText(.caption)
                                    .foregroundStyle(.secondary)
                                    .wrapping()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if isProblem {
                        Button(scaled: "Retry") { weather.refresh() }
                    }
                }
            }
            LocationRow()   // also with Live weather off: the sun, the sky and Universe use it too
        } header: {
            SettingsHeader("Weather")
        } footer: {
            VStack(alignment: .leading, spacing: Space.xs) {
                SettingsNote("Ocean Horizon and Shallows styles with Weather set to Live show the sky outside — cloud, fog, rain, snow and storms — and ease from one to the next. DotStudio asks Open-Meteo for the current weather at your location, rounded to about 10 km, every 20 minutes while one of those styles is in your library.")
                SettingsNote("Your location also places the real sun, moon and stars in scenes that follow the sun, and the marker on Universe's Earth. On a VPN the automatic one can be far off — Change… sets yours.")
                Link(WeatherState.attribution, destination: URL(string: "https://open-meteo.com/")!)
                    .settingsText(.caption)
                    .settingsLink()
            }
        }
    }

    private var isProblem: Bool {
        switch weather.status {
        case .failed, .noLocation: return weather.reading == nil || isStale
        default: return false
        }
    }

    private var isStale: Bool {
        guard let at = weather.reading?.fetchedAt else { return true }
        return Date().timeIntervalSince1970 - at > WeatherState.staleAfter
    }

    private var symbol: String {
        if isProblem { return "exclamationmark.triangle.fill" }
        return weather.reading?.condition?.symbol ?? "cloud.sun"
    }

    /// "Toronto area · Light rain · updated 5 min ago".
    private func headline(now: Date) -> String {
        if isProblem {
            return weather.status == .noLocation ? "Finding your location…" : "Couldn't get weather"
        }
        guard let r = weather.reading else {
            return weather.status == .fetching ? "Getting the weather…" : "No weather yet"
        }
        var parts = [r.summary]
        if let place = Self.placeName(of: r, in: model.library) { parts.insert(place, at: 0) }
        if let at = r.fetchedDate {
            let mins = Int(max(0, now.timeIntervalSince(at)) / 60)
            parts.append(mins < 1 ? "updated just now"
                         : mins < 60 ? "updated \(mins) min ago"
                         : "updated " + RelativeDateTimeFormatter().localizedString(for: at, relativeTo: now))
        }
        return parts.joined(separator: " · ")
    }

    /// Where a reading is, in words: the place in use by name — the one the user picked, or the
    /// IP lookup's city — when the reading is for it (a reading is rounded to about 10 km; one
    /// from before the location changed is still the old place's); else the weather service's
    /// reverse-geocoded name, as an area ("Toronto area").
    static func placeName(of r: WeatherState, in lib: Library) -> String? {
        if let name = lib.locationPlaceName, let lat = lib.locationLat, let lon = lib.locationLon {
            let near = (r.latitude.map { abs($0 - lat) <= 0.2 } ?? true)
                && (r.longitude.map { abs($0 - lon) <= 0.2 } ?? true)
            if near { return name }
        }
        return r.place.map { "\($0) area" }
    }

    private func detail(now: Date) -> String {
        if case .failed(let why) = weather.status, isProblem { return why }
        if weather.status == .noLocation { return "Waiting for your location." }
        guard let r = weather.reading else {
            return weather.isNeeded ? "Fetched at launch and every 20 minutes."
                                    : "No style follows the live weather right now."
        }
        var parts: [String] = []
        if let c = r.cloudCover { parts.append("\(Int((c * 100).rounded()))% cloud") }
        if let w = r.windSpeed { parts.append(String(format: "wind %.0f m/s", w)) }
        if let v = r.visibility, v < 10000 { parts.append(String(format: "visibility %.1f km", v / 1000)) }
        if isStale { parts.append("out of date — the scenes have gone back to clear") }
        return parts.isEmpty ? "" : parts.joined(separator: " · ").prefix(1).uppercased() + parts.joined(separator: " · ").dropFirst()
    }
}
