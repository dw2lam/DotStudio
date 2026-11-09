//  WeatherService.swift — the writer side of weather.json (Shared/Weather/WeatherState.swift):
//  the live weather for Ocean Horizon and Shallows styles set to "Live".
//
//  The app (it has the network; the saver doesn't) asks Open-Meteo (open-meteo.com — free, no
//  key, CC BY 4.0) for the current weather at the library's approximate location, rounded to
//  ~0.1° (about 10 km) before it leaves the Mac, and writes weather.json atomically into
//  SharedStore.baseDir, where every renderer host reads it (WeatherLink).
//
//  When: at launch and every 20 minutes while a style in the library follows the live weather
//  (WeatherLink.followsLive) and Settings › Weather has it on; after a failure it backs off
//  (1, 2, 5, 10, 20 min). Turning it off deletes weather.json, so the scenes go back to clear.
//
//      WeatherService.shared.attach(model:)   // App.init
//      WeatherService.shared.start()          // applicationDidFinishLaunching

import Foundation
import Combine
import CoreLocation

final class WeatherService: ObservableObject {
    static let shared = WeatherService()
    static let interval: TimeInterval = 20 * 60
    private static let backoff: [TimeInterval] = [60, 120, 300, 600, 1200]
    private static let enabledKey = "weatherEnabled"
    private static let placeKey = "weatherPlace"

    enum Status: Equatable {
        case idle                 // nothing asked yet (or no style needs it)
        case fetching
        case ok
        case noLocation           // the IP location hasn't resolved yet
        case failed(String)
    }

    /// The last reading written (or found on disk at launch).
    @Published private(set) var reading: WeatherState?
    @Published private(set) var status: Status = .idle
    /// Settings › Weather › Live weather.
    @Published var enabled: Bool = UserDefaults.standard.object(forKey: WeatherService.enabledKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if !enabled { clear() }
            reevaluate()
        }
    }

    private weak var model: AppModel?
    private var subs: [AnyCancellable] = []
    private var started = false
    private var next: DispatchWorkItem?
    private var failures = 0
    private var inFlight = false
    private var fileURL: URL? { model.map { $0.store.baseDir.appendingPathComponent(WeatherState.fileName) } }

    /// App.init.
    func attach(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        if let url = fileURL, let data = try? Data(contentsOf: url) {
            reading = try? JSONDecoder().decode(WeatherState.self, from: data)
        }
        // $library fires before the change: read it on the next turn.
        subs = [model.$library.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reevaluate() }]
    }

    /// applicationDidFinishLaunching.
    func start() {
        started = true
        reevaluate()
    }

    /// A style in the library follows the live weather, and the user hasn't turned it off.
    var isNeeded: Bool {
        enabled && (model?.library.presets.contains(where: WeatherLink.followsLive) ?? false)
    }

    /// Settings' Retry: fetch now, whatever the schedule says.
    func refresh() {
        failures = 0
        schedule(after: 0)
    }

    private func reevaluate() {
        guard started, DemoHooks.isActive == false else { return }
        guard isNeeded else {
            next?.cancel(); next = nil
            if status != .ok { status = .idle }
            return
        }
        guard next == nil, !inFlight else { return }
        // A fresh enough reading (a relaunch) waits out the rest of its interval.
        let age = reading?.fetchedAt.map { Date().timeIntervalSince1970 - $0 } ?? .infinity
        schedule(after: age < Self.interval ? Self.interval - age : 0)
    }

    private func schedule(after seconds: TimeInterval) {
        next?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.next = nil
            self?.fetch()
        }
        next = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(seconds, 0), execute: work)
    }

    private func fetch() {
        guard isNeeded, !inFlight else { return }
        guard let loc = model?.locationTuple else {
            status = .noLocation
            schedule(after: 60)                         // the IP lookup is usually seconds away
            return
        }
        // ~0.1° (≈ 10 km): enough for the weather, not enough to say where you are.
        let lat = (loc.lat * 10).rounded() / 10, lon = (loc.lon * 10).rounded() / 10
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.1f", lat)),
            URLQueryItem(name: "longitude", value: String(format: "%.1f", lon)),
            URLQueryItem(name: "current", value: "weather_code,cloud_cover,cloud_cover_low,precipitation,rain,showers,snowfall,wind_speed_10m,wind_gusts_10m,visibility,is_day"),
            URLQueryItem(name: "wind_speed_unit", value: "ms"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        guard let url = c.url else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        inFlight = true
        status = .fetching
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let current = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["current"] as? [String: Any]
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                guard let current, (200..<300).contains(code) else {
                    let why = error.map { ($0 as NSError).localizedDescription } ?? (code != 0 ? "HTTP \(code)" : "No data")
                    self.failed(why)
                    return
                }
                let state = WeatherState(openMeteo: current, latitude: lat, longitude: lon,
                                         place: self.cachedPlace(lat, lon), at: Date())
                self.write(state)
                self.resolvePlace(lat, lon)
            }
        }.resume()
    }

    private func failed(_ why: String) {
        status = .failed(why)
        let delay = Self.backoff[min(failures, Self.backoff.count - 1)]
        failures += 1
        schedule(after: delay)
    }

    private func write(_ state: WeatherState) {
        guard let url = fileURL else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try enc.encode(state).write(to: url, options: .atomic)
            reading = state
            status = .ok
            failures = 0
            schedule(after: Self.interval)
        } catch {
            failed("Couldn't save it: \(error.localizedDescription)")
        }
    }

    /// Turned off: the scenes go back to clear (WeatherLink reads no file as clear).
    private func clear() {
        next?.cancel(); next = nil
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        reading = nil
        status = .idle
    }

    // MARK: Place name ("Toronto area"), for Settings only

    private func placeKey(_ lat: Double, _ lon: Double) -> String { String(format: "%.1f,%.1f", lat, lon) }

    private func cachedPlace(_ lat: Double, _ lon: Double) -> String? {
        (UserDefaults.standard.dictionary(forKey: Self.placeKey) as? [String: String])?[placeKey(lat, lon)]
    }

    /// Reverse-geocodes the rounded coordinates once (Apple's geocoder: no location permission),
    /// then keeps the name with the reading.
    private func resolvePlace(_ lat: Double, _ lon: Double) {
        guard cachedPlace(lat, lon) == nil else { return }
        CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon)) { [weak self] marks, _ in
            guard let m = marks?.first, let name = m.locality ?? m.subAdministrativeArea ?? m.administrativeArea ?? m.name else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                var d = (UserDefaults.standard.dictionary(forKey: Self.placeKey) as? [String: String]) ?? [:]
                d[self.placeKey(lat, lon)] = name
                UserDefaults.standard.set(d, forKey: Self.placeKey)
                if var r = self.reading, r.latitude == lat, r.longitude == lon {
                    r.place = name
                    self.write(r)
                }
            }
        }
    }
}
