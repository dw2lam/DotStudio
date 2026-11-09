//  WeatherMix.swift — the weather as the scene shaders see it: a handful of continuous values
//  (so one condition eases into the next), the fixed menu conditions, and the packing into
//  FXUniforms.weather / weather2 / weather3 (EffectUniforms.h). Shared/Weather/Weather_funcs.h
//  reads them.

import Foundation
import simd

struct WeatherMix: Equatable {
    /// Cloud cover 0…1. 0.25 is the scenes' own sky ("Clear" = as the scene always looked).
    var cover: Double = 0.25
    /// Rain/snow intensity 0…1 (drizzle ≈ 0.2, rain ≈ 0.55, heavy ≈ 0.85).
    var precip: Double = 0
    /// Share of it that is snow, 0…1 (sleet ≈ 0.5).
    var snow: Double = 0
    /// 10 m wind and gusts, m/s.
    var wind: Double = 4
    var gust: Double = 6
    /// Fog 0…1: visibility on a log scale, 0 = 20 km or more … 1 = 150 m (`visibility`).
    var fog: Double = 0
    /// Thunderstorm 0…1: towering dark cloud, rough sea, lightning.
    var storm: Double = 0

    static let clear = WeatherMix()

    /// The fixed condition a scene's Weather menu can pick (and tools/gallery --weather).
    static func preset(_ c: WeatherCondition) -> WeatherMix {
        switch c {
        case .clear: return .clear
        case .partlyCloudy: return WeatherMix(cover: 0.58, wind: 5, gust: 8, fog: 0.02)
        case .cloudy: return WeatherMix(cover: 1.0, wind: 6, gust: 9, fog: 0.12)
        case .fog: return WeatherMix(cover: 0.85, wind: 2, gust: 3, fog: 0.88)
        case .drizzle: return WeatherMix(cover: 1.0, precip: 0.22, wind: 5, gust: 8, fog: 0.30)
        case .rain: return WeatherMix(cover: 1.0, precip: 0.55, wind: 8, gust: 12, fog: 0.38)
        case .heavyRain: return WeatherMix(cover: 1.0, precip: 0.88, wind: 11, gust: 17, fog: 0.52)
        case .thunderstorm: return WeatherMix(cover: 1.0, precip: 0.7, wind: 13, gust: 22, fog: 0.3, storm: 1)
        case .snow: return WeatherMix(cover: 1.0, precip: 0.55, snow: 1, wind: 4, gust: 6, fog: 0.55)
        case .sleet: return WeatherMix(cover: 1.0, precip: 0.5, snow: 0.5, wind: 7, gust: 10, fog: 0.40)
        }
    }

    /// The scene's Weather menu ("weather" param): 0 = Live, then these fixed conditions.
    static let menu = ["Live", "Clear", "Partly Cloudy", "Overcast", "Fog", "Rain", "Storm", "Snow"]
    static let menuConditions: [WeatherCondition] = [.clear, .partlyCloudy, .cloudy, .fog, .rain, .thunderstorm, .snow]

    /// Fog value for a visibility in metres (log scale: 20 km → 0, 150 m → 1).
    static func fog(visibility: Double?) -> Double {
        guard let v = visibility, v > 0 else { return 0 }
        return min(max(log(20000 / v) / log(20000 / 150), 0), 1)
    }

    /// A live reading, faded toward clear as it goes stale.
    init(_ s: WeatherState, at now: Date = Date()) {
        let c = s.condition ?? .clear
        let base = WeatherMix.preset(c)
        var m = WeatherMix()
        var cover = s.cloudCover ?? base.cover
        switch c {
        case .cloudy: cover = max(cover, 0.92)
        case .drizzle, .rain, .heavyRain, .thunderstorm, .snow, .sleet: cover = max(cover, 0.95)
        case .fog: cover = max(cover, 0.6)
        case .partlyCloudy: cover = min(max(cover, 0.4), 0.85)
        case .clear: cover = min(cover, 0.45)
        }
        m.cover = cover
        m.precip = min(max(s.precipitation ?? base.precip, 0), 1)
        m.snow = min(max(s.snowShare ?? (s.isSnow == true ? 1 : base.snow), 0), 1)
        m.wind = min(max(s.windSpeed ?? base.wind, 0), 40)
        m.gust = min(max(s.windGusts ?? m.wind * 1.5, m.wind), 50)
        var fog = s.visibility != nil ? WeatherMix.fog(visibility: s.visibility) : base.fog
        if c == .fog { fog = max(fog, 0.72) }
        m.fog = fog
        m.storm = (s.lightning == true || c == .thunderstorm) ? 1 : 0
        self = WeatherMix.lerp(.clear, m, s.freshness(at: now))
    }

    init(cover: Double = 0.25, precip: Double = 0, snow: Double = 0, wind: Double = 4, gust: Double = 6,
         fog: Double = 0, storm: Double = 0) {
        self.cover = cover; self.precip = precip; self.snow = snow
        self.wind = wind; self.gust = gust; self.fog = fog; self.storm = storm
    }

    static func lerp(_ a: WeatherMix, _ b: WeatherMix, _ k: Double) -> WeatherMix {
        let k = min(max(k, 0), 1)
        func l(_ x: Double, _ y: Double) -> Double { x + (y - x) * k }
        return WeatherMix(cover: l(a.cover, b.cover), precip: l(a.precip, b.precip), snow: l(a.snow, b.snow),
                          wind: l(a.wind, b.wind), gust: l(a.gust, b.gust), fog: l(a.fog, b.fog),
                          storm: l(a.storm, b.storm))
    }

    /// Indistinguishable from the scene's own clear sky: the shader's no-weather path draws it.
    var isClear: Bool {
        let c = WeatherMix.clear
        return abs(cover - c.cover) < 0.005 && precip < 0.002 && fog < 0.002 && storm < 0.002
            && abs(wind - c.wind) < 0.05 && abs(gust - c.gust) < 0.1
    }

    /// Cloud drift speed relative to the scene's own (1 at the clear default's 4 m/s).
    var driftRate: Double { min(max((5 + wind) / 9, 0.5), 3.0) }

    /// FXUniforms.weather / weather2 (weather3 carries the drift and the Lightning toggle).
    var packed: (simd_float4, simd_float4) {
        (simd_float4(Float(cover), Float(precip), Float(snow), Float(wind)),
         simd_float4(Float(gust), Float(fog), Float(storm), isClear ? 0 : 1))
    }
}
