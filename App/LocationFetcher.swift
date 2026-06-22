//  LocationFetcher.swift — resolves the device's approximate location for the
//  Universe marker via IP geolocation (no Location permission prompt). Runs in the
//  app (which has network); the resolved lat/lon is cached in the library so the
//  sandboxed screensaver can read it too.

import Foundation

enum LocationFetcher {
    static func fetch(_ completion: @escaping (Double, Double) -> Void) {
        guard let url = URL(string: "https://ipapi.co/json/") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let lat = obj["latitude"] as? Double,
                  let lon = obj["longitude"] as? Double else { return }
            DispatchQueue.main.async { completion(lat, lon) }
        }.resume()
    }
}
