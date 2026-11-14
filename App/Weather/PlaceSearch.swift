//  PlaceSearch.swift — finds a place by name for Settings ▸ Weather ▸ Location, with
//  Open-Meteo's free geocoding API (no key; GeoNames data, CC BY 4.0):
//  https://geocoding-api.open-meteo.com/v1/search?name=…&count=8&language=en&format=json
//
//  Only what the user types is sent (never their location). Coordinates typed into the field
//  ("43.65, -79.38") are offered as a place of their own, without a request.
//
//  PlaceSearchModel drives the popover: debounced (0.35 s), the latest query wins, and its
//  `search` is injectable (UI shots pass a fixture; nothing here runs without the network
//  otherwise).

import Foundation
import Combine

/// One search result.
struct PlaceResult: Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    /// State / province / region ("Ontario"), when the place has one.
    var admin1: String?
    var country: String?
    var lat: Double
    var lon: Double
    /// Typed coordinates rather than a found place.
    var isCoordinates = false

    /// "Ontario, Canada" — under the name in the list.
    var detail: String {
        if isCoordinates { return "Coordinates" }
        return [admin1, country].compactMap { $0 }.filter { !$0.isEmpty && $0 != name }.joined(separator: ", ")
    }

    /// What's kept and shown once picked: "Toronto, Ontario" — the name and its region (else its
    /// country), never the name twice ("Singapore", not "Singapore, Singapore").
    var place: NamedPlace {
        if isCoordinates { return NamedPlace(name: name, lat: lat, lon: lon) }
        let second = [admin1, country].compactMap { $0 }.first { !$0.isEmpty && $0 != name }
        return NamedPlace(name: [name, second].compactMap { $0 }.joined(separator: ", "), lat: lat, lon: lon)
    }
}

enum PlaceSearch {
    static func url(_ query: String) -> URL? {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [URLQueryItem(name: "name", value: query), URLQueryItem(name: "count", value: "8"),
                        URLQueryItem(name: "language", value: "en"), URLQueryItem(name: "format", value: "json")]
        return c.url
    }

    /// {"results":[{"id":6167865,"name":"Toronto","latitude":43.70011,"longitude":-79.4163,
    /// "admin1":"Ontario","country":"Canada",…}],…}; no match has no "results"; an error is
    /// {"error":true,"reason":"…"}.
    static func parse(_ data: Data) throws -> [PlaceResult] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SearchError("The answer couldn't be read.")
        }
        if (obj["error"] as? Bool) == true { throw SearchError((obj["reason"] as? String) ?? "The search failed.") }
        let items = obj["results"] as? [[String: Any]] ?? []
        return items.compactMap { r in
            guard let name = r["name"] as? String, !name.isEmpty,
                  let lat = (r["latitude"] as? NSNumber)?.doubleValue,
                  let lon = (r["longitude"] as? NSNumber)?.doubleValue,
                  NamedPlace.validCoordinates(lat, lon) else { return nil }
            let id = (r["id"] as? NSNumber).map { "\($0)" } ?? String(format: "%@ %.4f %.4f", name, lat, lon)
            return PlaceResult(id: id, name: name, admin1: r["admin1"] as? String, country: r["country"] as? String,
                               lat: lat, lon: lon)
        }
    }

    /// "43.65, -79.38" / "43.65 -79.38" → coordinates (lat first), else nil.
    static func coordinates(_ text: String) -> PlaceResult? {
        let parts = text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }).map(String.init)
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
              NamedPlace.validCoordinates(lat, lon) else { return nil }
        return PlaceResult(id: "coords", name: NamedPlace.coordinateName(lat, lon), lat: lat, lon: lon, isCoordinates: true)
    }

    struct SearchError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// The real search: one request, 10 s; `done` on the main queue. Returns the task (to cancel).
    @discardableResult
    static func search(_ query: String, _ done: @escaping (Result<[PlaceResult], Error>) -> Void) -> URLSessionDataTask? {
        guard let url = url(query) else { done(.success([])); return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        let task = URLSession.shared.dataTask(with: req) { data, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let result: Result<[PlaceResult], Error>
            if let error { result = .failure(error) }
            else if let data, (200..<300).contains(code) { result = Result { try parse(data) } }
            else { result = .failure(SearchError(code != 0 ? "HTTP \(code)" : "No answer.")) }
            DispatchQueue.main.async { done(result) }
        }
        task.resume()
        return task
    }
}

/// The location popover's search: what's typed → results, debounced.
final class PlaceSearchModel: ObservableObject {
    enum State: Equatable {
        case idle                     // nothing (or one letter) typed
        case searching
        case results([PlaceResult])
        case noMatch
        case failed(String)
    }

    typealias Search = (String, @escaping (Result<[PlaceResult], Error>) -> Void) -> Void

    @Published var query = "" { didSet { if query != oldValue { schedule() } } }
    @Published private(set) var state: State = .idle

    private let search: Search
    private var work: DispatchWorkItem?
    private var generation = 0
    static let debounce: TimeInterval = 0.35

    /// `search`: nil = Open-Meteo.
    init(search: Search? = nil) {
        if let search { self.search = search }
        else {
            var current: URLSessionDataTask?
            self.search = { q, done in
                current?.cancel()
                current = PlaceSearch.search(q, done)
            }
        }
    }

    /// UI shots: a query with its state already in place (nothing is fetched).
    init(demoQuery: String, state: State) {
        search = { _, _ in }
        frozen = true
        query = demoQuery
        self.state = state
    }

    /// A demo's state never changes.
    private var frozen = false

    /// Search again now (the Retry after a failure).
    func retry() { run(after: 0) }

    private func schedule() { run(after: Self.debounce) }

    private func run(after delay: TimeInterval) {
        guard !frozen else { return }
        work?.cancel()
        generation += 1
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let c = PlaceSearch.coordinates(q) { state = .results([c]); return }
        guard q.count >= 2 else { state = .idle; return }
        let gen = generation
        let item = DispatchWorkItem { [weak self] in
            guard let self, gen == self.generation else { return }
            self.state = .searching
            self.search(q) { [weak self] result in
                guard let self, gen == self.generation else { return }   // a newer query is out
                switch result {
                case .success(let r): self.state = r.isEmpty ? .noMatch : .results(r)
                case .failure(let e):
                    if (e as NSError).code == NSURLErrorCancelled { return }
                    self.state = .failed(e.localizedDescription)
                }
            }
        }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
