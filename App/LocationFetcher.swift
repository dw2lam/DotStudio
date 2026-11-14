//  LocationFetcher.swift — resolves the device's approximate location for the sky, the
//  Universe marker and the live weather via IP geolocation (no Location permission prompt).
//  Runs in the app (which has network); the resolved lat/lon is cached in the library so the
//  sandboxed screensaver can read it too. Never asked while the user has set their own place
//  (Library.usesManualLocation — Settings ▸ Weather ▸ Location).
//
//  Two free HTTPS lookups, no key: ipapi.co, then ipwho.is if that fails (rate-limited, down,
//  blocked). Each has 8 s; AppModel writes the attempt off after 20 s and backs off.

import Foundation

enum LocationFetcher {
    struct Provider {
        let url: URL
        /// The answer's place, or nil (an error body, a missing field, bad coordinates).
        let parse: (Data) -> NamedPlace?
    }

    static let providers: [Provider] = [
        // {"city":"Toronto","region":"Ontario","country_name":"Canada","latitude":43.6,"longitude":-79.4,…};
        // an error is {"error":true,"reason":"RateLimited",…}
        Provider(url: URL(string: "https://ipapi.co/json/")!) { data in
            place(data, ok: { ($0["error"] as? Bool) != true }, city: "city", region: "region", country: "country_name")
        },
        // {"success":true,"city":"Toronto","region":"Ontario","country":"Canada","latitude":43.6,"longitude":-79.4,…};
        // a failure is {"success":false,"message":"…"} (sometimes with HTTP 200)
        Provider(url: URL(string: "https://ipwho.is/")!) { data in
            place(data, ok: { ($0["success"] as? Bool) == true }, city: "city", region: "region", country: "country")
        },
    ]

    /// Reports only a success (on the main queue): the providers in turn until one answers.
    static func fetch(_ completion: @escaping (NamedPlace) -> Void) {
        fetch(from: providers[...], completion)
    }

    private static func fetch(from list: ArraySlice<Provider>, _ completion: @escaping (NamedPlace) -> Void) {
        guard let p = list.first else { return }
        var req = URLRequest(url: p.url)
        req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req) { data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let data, (200..<300).contains(code), let place = p.parse(data) {
                DispatchQueue.main.async { completion(place) }
            } else {
                fetch(from: list.dropFirst(), completion)
            }
        }.resume()
    }

    /// A provider's JSON → a named place ("Toronto, Ontario"), when it says it succeeded.
    static func place(_ data: Data, ok: ([String: Any]) -> Bool,
                      city: String, region: String, country: String) -> NamedPlace? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], ok(obj),
              let lat = (obj["latitude"] as? NSNumber)?.doubleValue,
              let lon = (obj["longitude"] as? NSNumber)?.doubleValue,
              NamedPlace.validCoordinates(lat, lon),
              !(lat == 0 && lon == 0) else { return nil }   // "no idea" from some lookups
        func text(_ k: String) -> String? {
            ((obj[k] as? String)?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
        }
        // "City, Region" (else the country), each once.
        var unique: [String] = []
        for p in [text(city), text(region) ?? text(country)].compactMap({ $0 }) where !unique.contains(p) { unique.append(p) }
        return NamedPlace(name: unique.joined(separator: ", "), lat: lat, lon: lon)
    }
}
