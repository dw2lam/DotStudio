//  WeatherState.swift — CONTRACT between the app's WeatherService (writer, App/Weather) and every
//  renderer (screensaver, live wallpaper, in-app previews, thumbnails, tools/gallery) that shows
//  the live weather in Ocean Horizon and Shallows.
//
//  Data flows one way: the unsandboxed app asks Open-Meteo (open-meteo.com, CC BY 4.0) for the
//  current weather at the library's approximate location (rounded to ~0.1°) and writes
//    <SharedStore.baseDir>/weather.json        — this struct, atomically
//  The sandboxed saver only reads it. Live weather must NEVER go in library.json: the saver
//  re-applies the playing style whenever that file's mtime changes.
//
//  Every field is optional so older/newer writers and readers never fail to decode; an unknown
//  condition decodes as `.clear`. Readers fade a reading older than `staleAfter` back to clear
//  (WeatherMix.target), so a quit app never leaves a storm on screen for days.

import Foundation

/// What the sky is doing, coarsely — the scenes' vocabulary (WMO code → `init(wmo:)`).
enum WeatherCondition: String, Codable, CaseIterable, Equatable {
    case clear, partlyCloudy, cloudy, fog, drizzle, rain, heavyRain, thunderstorm, snow, sleet

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = WeatherCondition(rawValue: raw) ?? .clear
    }

    /// WMO weather interpretation code (Open-Meteo's `weather_code`) → condition.
    ///   0 clear · 1 mainly clear · 2 partly cloudy · 3 overcast · 45/48 fog (rime)
    ///   51/53/55 drizzle · 56/57 freezing drizzle · 61/63/65 rain · 66/67 freezing rain
    ///   71/73/75 snow · 77 snow grains · 80/81/82 rain showers · 85/86 snow showers
    ///   95 thunderstorm · 96/99 thunderstorm with hail
    init(wmo code: Int) {
        switch code {
        case 0, 1: self = .clear
        case 2: self = .partlyCloudy
        case 3: self = .cloudy
        case 45, 48: self = .fog
        case 51, 53, 55: self = .drizzle
        case 56, 57, 66, 67: self = .sleet            // freezing drizzle / rain: icy, mixed
        case 61, 63, 80, 81: self = .rain
        case 65, 82: self = .heavyRain
        case 71, 73, 75, 77, 85, 86: self = .snow
        case 95, 96, 99: self = .thunderstorm
        default: self = code > 3 ? .cloudy : .clear
        }
    }

    /// How hard it comes down for a WMO code, 0…1 (light / moderate / heavy within each kind).
    static func precipitationIntensity(wmo code: Int) -> Double {
        switch code {
        case 51, 56: return 0.14
        case 53: return 0.20
        case 55, 57: return 0.28
        case 61, 66: return 0.36
        case 63: return 0.55
        case 80: return 0.42
        case 81: return 0.62
        case 65, 67: return 0.82
        case 82: return 0.92
        case 71: return 0.30
        case 73: return 0.50
        case 75: return 0.78
        case 77: return 0.24
        case 85: return 0.45
        case 86: return 0.78
        case 95: return 0.70
        case 96, 99: return 0.85
        default: return 0
        }
    }

    /// The condition in the app's UI ("Light rain" etc. comes from `WeatherState.summary`).
    var displayName: String {
        switch self {
        case .clear: return "Clear"
        case .partlyCloudy: return "Partly cloudy"
        case .cloudy: return "Overcast"
        case .fog: return "Fog"
        case .drizzle: return "Drizzle"
        case .rain: return "Rain"
        case .heavyRain: return "Heavy rain"
        case .thunderstorm: return "Thunderstorm"
        case .snow: return "Snow"
        case .sleet: return "Sleet"
        }
    }

    var symbol: String {
        switch self {
        case .clear: return "sun.max"
        case .partlyCloudy: return "cloud.sun"
        case .cloudy: return "cloud"
        case .fog: return "cloud.fog"
        case .drizzle: return "cloud.drizzle"
        case .rain: return "cloud.rain"
        case .heavyRain: return "cloud.heavyrain"
        case .thunderstorm: return "cloud.bolt.rain"
        case .snow: return "cloud.snow"
        case .sleet: return "cloud.sleet"
        }
    }
}

struct WeatherState: Codable, Equatable {
    static let fileName = "weather.json"
    /// Older than this, readers fade the reading back to clear (over `staleFade`).
    static let staleAfter: TimeInterval = 3 * 3600
    static let staleFade: TimeInterval = 30 * 60
    static let attribution = "Weather data by Open-Meteo.com"

    var version: Int?
    var condition: WeatherCondition?
    /// The raw WMO code the condition came from.
    var weatherCode: Int?
    /// Total cloud cover 0…1, and the low deck's share (stratus, the clouds that hide the sun).
    var cloudCover: Double?
    var cloudCoverLow: Double?
    /// How hard it rains or snows, 0…1 (from the WMO code and the measured rate).
    var precipitation: Double?
    /// Measured precipitation, mm (Open-Meteo's `precipitation`, the preceding interval).
    var precipitationMM: Double?
    /// The precipitation is frozen (snow, snow grains, snow showers); sleet is half.
    var isSnow: Bool?
    var snowShare: Double?
    /// 10 m wind and gusts, m/s.
    var windSpeed: Double?
    var windGusts: Double?
    /// Horizontal visibility, metres.
    var visibility: Double?
    /// A thunderstorm: lightning in the scene.
    var lightning: Bool?
    var isDay: Bool?
    /// Unix epoch seconds of the fetch.
    var fetchedAt: Double?
    /// Where it's for: the rounded coordinates sent, and a place name for the app's UI.
    var latitude: Double?
    var longitude: Double?
    var place: String?
    /// Data attribution (Open-Meteo, CC BY 4.0).
    var source: String?
}

extension WeatherState {
    var fetchedDate: Date? { fetchedAt.map { Date(timeIntervalSince1970: $0) } }

    /// 1 while fresh, fading to 0 between `staleAfter` and `staleAfter + staleFade`.
    func freshness(at now: Date = Date()) -> Double {
        guard let at = fetchedAt else { return 0 }
        let age = now.timeIntervalSince1970 - at
        if age < -3600 { return 0 }                 // from the future: a broken clock, ignore it
        let x = (age - Self.staleAfter) / Self.staleFade
        return x <= 0 ? 1 : (x >= 1 ? 0 : 1 - x * x * (3 - 2 * x))
    }

    /// "Light rain", "Overcast", "Thunderstorm" — the condition, with the WMO code's intensity.
    var summary: String {
        let c = condition ?? .clear
        switch weatherCode ?? -1 {
        case 1: return "Mainly clear"
        case 51, 61, 71, 80, 85: return "Light " + c.displayName.lowercased()
        case 55, 65, 75, 82, 86: return c == .heavyRain ? "Heavy rain" : "Heavy " + c.displayName.lowercased()
        case 48: return "Freezing fog"
        case 56, 57: return "Freezing drizzle"
        case 66, 67: return "Freezing rain"
        case 77: return "Snow grains"
        case 96, 99: return "Thunderstorm with hail"
        default: return c.displayName
        }
    }

    /// Builds the reading from Open-Meteo's `current` block (see WeatherService for the query).
    init(openMeteo cur: [String: Any], latitude: Double?, longitude: Double?, place: String?, at date: Date) {
        func num(_ k: String) -> Double? {
            if let d = cur[k] as? Double { return d }
            if let i = cur[k] as? Int { return Double(i) }
            if let n = cur[k] as? NSNumber { return n.doubleValue }
            return nil
        }
        let code = num("weather_code").map { Int(saturating: $0) } ?? 0
        var cond = WeatherCondition(wmo: code)
        let cover = num("cloud_cover").map { min(max($0 / 100, 0), 1) }
        // A "mainly clear" code under a sky the model calls mostly covered reads as partly cloudy.
        if cond == .clear, let cover, cover > 0.45 { cond = cover > 0.85 ? .cloudy : .partlyCloudy }
        let mm = num("precipitation") ?? 0
        let snowMM = (num("snowfall") ?? 0) / 0.7          // cm of snow ≈ mm water × 0.7 → mm
        let codeI = WeatherCondition.precipitationIntensity(wmo: code)
        // Rate → intensity: 0.5 mm per 15 min (2 mm/h) reads as moderate.
        let rateI = 1 - exp(-max(mm, snowMM) / 1.2)
        let wet = [.drizzle, .rain, .heavyRain, .thunderstorm, .snow, .sleet].contains(cond)
        let precip = wet ? min(1, max(codeI * 0.85, rateI, 0.12)) : 0
        let snowShare: Double = cond == .snow ? 1 : (cond == .sleet ? 0.5 : 0)

        version = 1
        condition = cond
        weatherCode = code
        cloudCover = cover
        cloudCoverLow = num("cloud_cover_low").map { min(max($0 / 100, 0), 1) }
        precipitation = precip
        precipitationMM = mm
        isSnow = snowShare > 0.75
        self.snowShare = snowShare
        windSpeed = num("wind_speed_10m")
        windGusts = num("wind_gusts_10m")
        visibility = num("visibility")
        lightning = cond == .thunderstorm
        isDay = num("is_day").map { $0 > 0.5 }
        fetchedAt = date.timeIntervalSince1970
        self.latitude = latitude
        self.longitude = longitude
        self.place = place
        source = Self.attribution + " (CC BY 4.0)"
    }
}
