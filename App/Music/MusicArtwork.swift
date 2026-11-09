//  MusicArtwork.swift — finds the current track's cover, caches it on disk by track, and
//  extracts its palette.
//
//  Order of attempts (first hit wins):
//    1. Disk cache, keyed by track id (and, for album searches, by artist+album).
//    2. Apple Events, only when the player is running AND Automation is allowed:
//       Spotify `artwork url` (downloaded) / Music `artworks[0]` raw bytes (all-black rejected).
//    3. Prompt-free public lookups, debounced (rapid skips only look up the track that
//       stuck) and rate limited (Apple asks for ≤ ~20 requests/min):
//       Spotify  open.spotify.com/oembed?url=<spotify:track:…> → thumbnail_url with the
//                300 px prefix ab67616d00001e02 swapped for the 640 px ab67616d0000b273
//       Music    itunes.apple.com/lookup?id=<Store URL i=…>&country=<region> → artworkUrl100
//                rewritten to 1200x1200bb; local files → search?term=<artist album>&entity=album
//  Ads and Spotify local files get no artwork (renderers draw a placeholder).

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct MusicArtRequest {
    var source: MusicSource
    /// Identity of the track this art is for (the monitor drops results for stale keys).
    var trackKey: String
    var trackID: String?
    var title: String?
    var artist: String?
    var album: String?
    var storeTrackID: String?
    var storeAlbumID: String?
    var isLocal = false
    var isAd = false
    var isEpisode = false
    /// Player running + Automation allowed ⇒ try Apple Events first (addressed by `pid`).
    var useAppleEvents = false
    var pid: pid_t?
}

struct MusicArtResult {
    /// Stable hash of the cache key — also the shared file's name: "art-<key>.jpg".
    var key: String
    /// The cached JPEG (in the app's cache folder; the writer copies it into music/).
    var fileURL: URL
    var fileName: String { "art-\(key).jpg" }
    var palette: [RGBA]
    /// Decoded (≤ 512 px) for in-app UI such as the menu bar.
    var image: CGImage?
    /// Where it came from: cache, appleEvents, oembed, itunes-lookup, itunes-search.
    var origin: String
}

/// Counters for tests and the debug log.
struct MusicArtStats {
    var appleRequests: [Date] = []
    var spotifyRequests: [Date] = []
    var downloads = 0
    var cacheHits = 0
    var appleEventFetches = 0
}

// MARK: - Rate limiter

/// Sliding-window limiter that hands out reservations: `reserve()` returns how long to wait
/// before the request may go out and books that slot immediately (so concurrent callers
/// never overshoot). A cancelled waiter simply wastes its slot — conservative by design.
struct MusicRateLimiter {
    let limit: Int
    let window: TimeInterval
    private(set) var slots: [Date] = []

    init(limit: Int, per window: TimeInterval) { self.limit = max(1, limit); self.window = window }

    mutating func reserve(now: Date = Date()) -> TimeInterval {
        slots.removeAll { now.timeIntervalSince($0) >= window }
        let at: Date
        if slots.count < limit {
            at = max(now, slots.last ?? now)
        } else {
            // The slot frees when the request `limit` places back leaves the window.
            at = max(now, slots[slots.count - limit].addingTimeInterval(window))
        }
        slots.append(at)
        return at.timeIntervalSince(now)
    }
}

// MARK: - Resolver

actor MusicArtworkResolver {
    struct Config {
        var networkEnabled = true
        /// Wait this long after a track change before any network lookup (rapid skips).
        var debounce: TimeInterval = 0.45
        var appleRequestsPerMinute = 20
        var spotifyRequestsPerMinute = 30
        /// Long edge of the stored artwork.
        var maxPixels = 1200
        /// Cached covers kept on disk (LRU by modification date).
        var cacheLimit = 300
        /// iTunes storefront; nil = the user's region.
        var country: String? = nil
    }

    let cacheDir: URL
    let config: Config
    /// Runs the Apple Events artwork read (on the AE queue) — supplied by the monitor.
    private let appleEventsFetch: (MusicArtRequest) async -> MusicArtPayload?
    private let session: URLSession

    private var appleLimiter: MusicRateLimiter
    private var spotifyLimiter: MusicRateLimiter
    private var palettes: [String: [RGBA]] = [:]
    /// Keys with no artwork anywhere (definitive "no results"), retried after 30 min.
    private var misses: [String: Date] = [:]
    private(set) var stats = MusicArtStats()
    private let log: (String) -> Void

    init(cacheDir: URL, config: Config = Config(),
         log: @escaping (String) -> Void = { _ in },
         appleEventsFetch: @escaping (MusicArtRequest) async -> MusicArtPayload?) {
        self.cacheDir = cacheDir
        self.config = config
        self.log = log
        self.appleEventsFetch = appleEventsFetch
        appleLimiter = MusicRateLimiter(limit: config.appleRequestsPerMinute, per: 60)
        spotifyLimiter = MusicRateLimiter(limit: config.spotifyRequestsPerMinute, per: 60)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 15
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpAdditionalHeaders = ["User-Agent": "DotStudio (macOS screensaver)"]
        session = URLSession(configuration: cfg)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    func currentStats() -> MusicArtStats { stats }

    /// Resolves art for `req`, or nil (placeholder). Honors Task cancellation at every step.
    func resolve(_ req: MusicArtRequest) async -> MusicArtResult? {
        let primary = Self.primaryKey(req)
        let albumKey = Self.albumKey(req)
        // 1. Disk cache.
        for key in [primary, albumKey].compactMap({ $0 }) {
            if let hit = cached(key) { stats.cacheHits += 1; return hit }
        }
        if req.isAd { return nil }
        // 2. Apple Events (local, cheap — no debounce).
        if req.useAppleEvents {
            stats.appleEventFetches += 1
            switch await appleEventsFetch(req) {
            case .data(let data)?:
                if Task.isCancelled { return nil }
                if let r = store(data, keys: [primary], origin: "appleEvents") { return r }
            case .url(let url)?:
                if Task.isCancelled { return nil }
                if let data = await download(url), let r = store(data, keys: [primary], origin: "appleEvents") { return r }
            case nil: break
            }
        }
        // 3. Public lookups, after the skip debounce.
        guard config.networkEnabled else { return nil }
        if let missed = misses[primary], Date().timeIntervalSince(missed) < 1800 { return nil }
        do { try await Task.sleep(nanoseconds: UInt64(config.debounce * 1e9)) } catch { return nil }
        // Another request may have cached it while we waited (same track re-reported).
        if let hit = cached(primary) { stats.cacheHits += 1; return hit }

        switch req.source {
        case .spotify:
            guard !req.isLocal, let uri = req.trackID, uri.hasPrefix("spotify:track:") || uri.hasPrefix("spotify:episode:") else { return nil }
            guard let url = await spotifyArtworkURL(uri: uri) else { return nil }
            guard !Task.isCancelled, let data = await download(url) else { return nil }
            return store(data, keys: [primary], origin: "oembed")
        case .music, .unknown:
            if req.storeTrackID != nil || req.storeAlbumID != nil {
                if let url = await appleLookupArtwork(trackID: req.storeTrackID, albumID: req.storeAlbumID),
                   !Task.isCancelled, let data = await download(url),
                   let r = store(data, keys: [primary], origin: "itunes-lookup") {
                    return r
                }
                if Task.isCancelled { return nil }
            }
            // Local file (or a catalog id that didn't resolve): search by artist + album.
            guard let artist = req.artist, !artist.isEmpty else { return nil }
            if let albumKey, let hit = cached(albumKey) { stats.cacheHits += 1; return hit }
            guard let url = await appleSearchArtwork(artist: artist, album: req.album, title: req.title) else {
                if !Task.isCancelled { misses[primary] = Date() }
                return nil
            }
            guard !Task.isCancelled, let data = await download(url) else { return nil }
            return store(data, keys: [primary, albumKey].compactMap { $0 }, origin: "itunes-search")
        }
    }

    // MARK: Keys

    static func primaryKey(_ req: MusicArtRequest) -> String {
        if let id = req.trackID, !id.isEmpty { return id }
        return "meta:" + [req.title, req.artist, req.album].map { ($0 ?? "").lowercased() }.joined(separator: "|")
    }

    static func albumKey(_ req: MusicArtRequest) -> String? {
        guard let artist = req.artist, !artist.isEmpty, let album = req.album, !album.isEmpty else { return nil }
        return "album:" + artist.lowercased() + "|" + album.lowercased()
    }

    /// FNV-1a 64 — stable across launches (Swift's Hasher is seeded per process).
    static func hash(_ key: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in key.utf8 { h ^= UInt64(b); h = h &* 0x100_0000_01b3 }
        return String(format: "%016llx", h)
    }

    // MARK: Cache

    private func cacheURL(_ hashKey: String) -> URL { cacheDir.appendingPathComponent(hashKey + ".jpg") }

    private func cached(_ key: String) -> MusicArtResult? {
        let h = Self.hash(key)
        let url = cacheURL(h)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)   // LRU touch
        return result(hashKey: h, url: url, origin: "cache")
    }

    private func result(hashKey: String, url: URL, origin: String) -> MusicArtResult? {
        guard let image = MusicArtImage.thumbnail(url: url, maxPixels: 512) else { return nil }
        let palette: [RGBA]
        if let p = palettes[hashKey] { palette = p } else {
            palette = MusicPalette.extract(from: image)
            if palettes.count > 256 { palettes.removeAll() }
            palettes[hashKey] = palette
        }
        return MusicArtResult(key: hashKey, fileURL: url, palette: palette, image: image, origin: origin)
    }

    /// Normalizes to JPEG ≤ maxPixels, rejects blank art, stores under every key.
    private func store(_ data: Data, keys: [String], origin: String) -> MusicArtResult? {
        guard let jpeg = MusicArtImage.normalizedJPEG(data, maxPixels: config.maxPixels) else {
            log("art: \(origin) data rejected (undecodable or blank)")
            return nil
        }
        var first: (String, URL)?
        for key in keys {
            let h = Self.hash(key)
            let url = cacheURL(h)
            do { try jpeg.write(to: url, options: .atomic) } catch { continue }
            if first == nil { first = (h, url) }
        }
        pruneCache()
        guard let (h, url) = first else { return nil }
        return result(hashKey: h, url: url, origin: origin)
    }

    private func pruneCache() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > config.cacheLimit else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (url, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - config.cacheLimit) {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: Network

    private func waitForSlot(apple: Bool) async -> Bool {
        let wait = apple ? appleLimiter.reserve() : spotifyLimiter.reserve()
        if wait > 0 {
            log("art: rate limit — waiting \(String(format: "%.1f", wait)) s")
            do { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) } catch { return false }
        }
        if apple { stats.appleRequests.append(Date()) } else { stats.spotifyRequests.append(Date()) }
        return !Task.isCancelled
    }

    private func fetchJSON(_ url: URL) async -> [String: Any]? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func download(_ url: URL) async -> Data? {
        guard url.scheme == "https" || url.scheme == "http" else { return nil }
        stats.downloads += 1
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
              !data.isEmpty else {
            log("art: download failed \(url.host ?? "")")
            return nil
        }
        return data
    }

    /// oEmbed (no account, no token) → the 640 px cover.
    private func spotifyArtworkURL(uri: String) async -> URL? {
        let parts = uri.split(separator: ":")
        var candidates = [uri]
        if parts.count == 3 { candidates.append("https://open.spotify.com/\(parts[1])/\(parts[2])") }
        for target in candidates {
            var c = URLComponents(string: "https://open.spotify.com/oembed")!
            c.queryItems = [URLQueryItem(name: "url", value: target)]
            guard let url = c.url, await waitForSlot(apple: false) else { return nil }
            if let json = await fetchJSON(url), let thumb = json["thumbnail_url"] as? String {
                return URL(string: Self.largeSpotifyImage(thumb))
            }
            if Task.isCancelled { return nil }
        }
        return nil
    }

    /// i.scdn.co / spotifycdn image ids encode the size: 00001e02 = 300 px, 0000b273 = 640 px.
    static func largeSpotifyImage(_ url: String) -> String {
        url.replacingOccurrences(of: "ab67616d00001e02", with: "ab67616d0000b273")
    }

    private var region: String {
        let r = config.country ?? Locale.current.region?.identifier ?? "US"
        return r.count == 2 ? r.uppercased() : "US"
    }

    /// One request for both ids (`lookup?id=<track>,<album>`); the user's storefront first,
    /// then the US one only if that returned nothing.
    private func appleLookupArtwork(trackID: String?, albumID: String?) async -> URL? {
        let ids = [trackID, albumID].compactMap { $0 }
        guard !ids.isEmpty else { return nil }
        for country in region == "US" ? ["US"] : [region, "US"] {
            var c = URLComponents(string: "https://itunes.apple.com/lookup")!
            c.queryItems = [URLQueryItem(name: "id", value: ids.joined(separator: ",")),
                            URLQueryItem(name: "country", value: country)]
            guard let url = c.url, await waitForSlot(apple: true) else { return nil }
            guard let json = await fetchJSON(url) else { return nil }   // network error: don't burn more requests
            let results = json["results"] as? [[String: Any]] ?? []
            func art(_ r: [String: Any]) -> String? { r["artworkUrl100"] as? String ?? r["artworkUrl60"] as? String }
            // The track's own cover first (singles/compilations can differ from the album's).
            let track = trackID.flatMap { id in results.first { ($0["trackId"] as? NSNumber)?.stringValue == id } }
            if let a = track.flatMap(art) ?? results.lazy.compactMap(art).first {
                return URL(string: Self.largeAppleImage(a))
            }
        }
        return nil
    }

    private func appleSearchArtwork(artist: String, album: String?, title: String?) async -> URL? {
        let byAlbum = !(album ?? "").isEmpty
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        let term = byAlbum ? "\(artist) \(album!)" : "\(artist) \(title ?? "")"
        c.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: byAlbum ? "album" : "song"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "country", value: region),
        ]
        guard let url = c.url, await waitForSlot(apple: true), let json = await fetchJSON(url) else { return nil }
        let results = json["results"] as? [[String: Any]] ?? []
        let wantArtist = Self.fold(artist)
        let wantName = Self.fold(byAlbum ? album! : (title ?? ""))
        func matches(_ r: [String: Any]) -> Bool {
            let a = Self.fold(r["artistName"] as? String ?? "")
            let n = Self.fold(r[byAlbum ? "collectionName" : "trackName"] as? String ?? "")
            let artistOK = !a.isEmpty && (a.contains(wantArtist) || wantArtist.contains(a))
            let nameOK = wantName.isEmpty || (!n.isEmpty && (n.contains(wantName) || wantName.contains(n)))
            return artistOK && nameOK
        }
        // Prefer the exact album over a deluxe/anniversary edition of it.
        let nameKey = byAlbum ? "collectionName" : "trackName"
        let wantRaw = (byAlbum ? album! : (title ?? "")).lowercased()
        let exact = results.first { matches($0) && ($0[nameKey] as? String)?.lowercased() == wantRaw }
        let folded = results.first { matches($0) && Self.fold($0[nameKey] as? String ?? "") == wantName }
        guard let best = exact ?? folded ?? results.first(where: matches),
              let art = best["artworkUrl100"] as? String ?? best["artworkUrl60"] as? String else { return nil }
        return URL(string: Self.largeAppleImage(art))
    }

    /// …/100x100bb.jpg → …/1200x1200bb.jpg (mzstatic serves any size up to the master).
    static func largeAppleImage(_ url: String) -> String {
        guard let r = url.range(of: #"/\d+x\d+(bb)?(-\d+)?\.(jpg|jpeg|png|webp)$"#, options: .regularExpression) else { return url }
        return url.replacingCharacters(in: r, with: "/1200x1200bb.jpg")
    }

    /// Case/diacritic-folded, trailing bracketed qualifiers and punctuation removed.
    static func fold(_ s: String) -> String {
        var t = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        // Trailing qualifiers only ("Album (Remastered)"), not a leading "(What's the Story)…".
        t = t.replacingOccurrences(of: #"\s+[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        return String(t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}

// MARK: - Image helpers

enum MusicArtImage {
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    static func thumbnail(url: URL, maxPixels: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnail(src, maxPixels: maxPixels)
    }

    static func thumbnail(_ src: CGImageSource, maxPixels: Int) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// JPEG bytes ≤ `maxPixels` on the long edge, or nil when undecodable, tiny or blank.
    /// Small-enough JPEGs are kept byte-for-byte (no generation loss).
    static func normalizedJPEG(_ data: Data, maxPixels: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let probe = thumbnail(src, maxPixels: 32), probe.width >= 8, probe.height >= 8,
              !isBlank(probe) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let type = CGImageSourceGetType(src) as String?
        if type == UTType.jpeg.identifier, max(w, h) <= maxPixels + 200, min(w, h) >= 64 { return data }
        guard let image = thumbnail(src, maxPixels: maxPixels) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return out as Data
    }

    /// All-black (or fully transparent) art — Music returns this while art is still loading.
    static func isBlank(_ image: CGImage) -> Bool {
        let side = 24
        guard let px = rgba(image, side: side) else { return true }
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 16 {
            if max(px[i], px[i + 1], px[i + 2]) > 8 { return false }
        }
        return true
    }

    /// The image squashed to side×side straight RGBA8 sRGB.
    static func rgba(_ image: CGImage, side: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: side * side * 4)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: srgb,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return ok ? buf : nil
    }
}

// MARK: - Palette

/// 3–5 dominant artwork colours, brightest-first: k-means (k = 5, k-means++ seeding with a
/// deterministic per-image seed) in Oklab on a 64 px thumbnail, tiny clusters dropped, near
/// duplicates merged; padded with lighter/darker variants when the cover is near-monochrome.
enum MusicPalette {
    struct Lab { var l: Double, a: Double, b: Double }

    static func extract(from image: CGImage, maxColors: Int = 5) -> [RGBA] {
        let side = 64
        guard let px = MusicArtImage.rgba(image, side: side) else { return [] }
        var points: [Lab] = []
        points.reserveCapacity(side * side)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for i in stride(from: 0, to: px.count, by: 4) {
            let a = Double(px[i + 3]) / 255
            guard a > 0.5 else { continue }
            // Un-premultiply.
            let r = Double(px[i]) / 255 / a, g = Double(px[i + 1]) / 255 / a, b = Double(px[i + 2]) / 255 / a
            points.append(oklab(r: min(1, r), g: min(1, g), b: min(1, b)))
            seed = (seed ^ UInt64(px[i]) ^ (UInt64(px[i + 1]) << 8) ^ (UInt64(px[i + 2]) << 16)) &* 0x100_0000_01b3
        }
        guard !points.isEmpty else { return [] }
        var clusters = kMeans(points, k: min(maxColors, points.count), seed: seed)
        let total = Double(points.count)
        // Drop specks (<2.5 %) as long as three colours remain.
        clusters.sort { $0.weight > $1.weight }
        while clusters.count > 3, let last = clusters.last, last.weight / total < 0.025 { clusters.removeLast() }
        // Merge near-duplicates (ΔE_ok < 0.06), weight-averaged.
        var merged: [(c: Lab, weight: Double)] = []
        for cl in clusters {
            if let i = merged.firstIndex(where: { distance($0.c, cl.c) < 0.06 }) {
                let w = merged[i].weight + cl.weight
                let m = merged[i]
                merged[i] = (Lab(l: (m.c.l * m.weight + cl.c.l * cl.weight) / w,
                                 a: (m.c.a * m.weight + cl.c.a * cl.weight) / w,
                                 b: (m.c.b * m.weight + cl.c.b * cl.weight) / w), w)
            } else {
                merged.append(cl)
            }
        }
        var labs = merged.map(\.c)
        // Near-monochrome cover: add lighter / darker variants of the dominant colour.
        if let base = merged.max(by: { $0.weight < $1.weight })?.c {
            var step = 1.0
            while labs.count < 3 {
                let dl = 0.16 * step * (labs.count % 2 == 1 ? 1 : -1)
                var v = base
                v.l = min(0.97, max(0.06, base.l + dl))
                if labs.contains(where: { distance($0, v) < 0.03 }) { v.l = min(0.97, max(0.06, base.l - dl)) }
                labs.append(v)
                step += 0.5
            }
        }
        return labs.sorted { $0.l > $1.l }.prefix(maxColors).map { lab in
            let (r, g, b) = srgb(lab)
            return RGBA(round4(r), round4(g), round4(b), 1)
        }
    }

    private static func kMeans(_ pts: [Lab], k: Int, seed: UInt64) -> [(c: Lab, weight: Double)] {
        var rng = seed == 0 ? 1 : seed
        func next() -> Double {   // SplitMix64
            rng &+= 0x9E37_79B9_7F4A_7C15
            var z = rng
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
        // k-means++ seeding.
        var centers = [pts[Int(next() * Double(pts.count)) % pts.count]]
        var d2 = pts.map { distance2($0, centers[0]) }
        while centers.count < k {
            let sum = d2.reduce(0, +)
            guard sum > 1e-9 else { break }   // fewer distinct colours than k
            var target = next() * sum, idx = 0
            for (i, d) in d2.enumerated() { target -= d; if target <= 0 { idx = i; break } }
            centers.append(pts[idx])
            for i in pts.indices { d2[i] = min(d2[i], distance2(pts[i], pts[idx])) }
        }
        var assign = [Int](repeating: 0, count: pts.count)
        for _ in 0..<12 {
            var moved = false
            for i in pts.indices {
                var best = 0, bestD = Double.infinity
                for (j, c) in centers.enumerated() {
                    let d = distance2(pts[i], c)
                    if d < bestD { bestD = d; best = j }
                }
                if assign[i] != best { assign[i] = best; moved = true }
            }
            var sums = [Lab](repeating: Lab(l: 0, a: 0, b: 0), count: centers.count)
            var counts = [Double](repeating: 0, count: centers.count)
            for (i, p) in pts.enumerated() {
                sums[assign[i]].l += p.l; sums[assign[i]].a += p.a; sums[assign[i]].b += p.b
                counts[assign[i]] += 1
            }
            for j in centers.indices where counts[j] > 0 {
                centers[j] = Lab(l: sums[j].l / counts[j], a: sums[j].a / counts[j], b: sums[j].b / counts[j])
            }
            if !moved { break }
        }
        var weights = [Double](repeating: 0, count: centers.count)
        for a in assign { weights[a] += 1 }
        return zip(centers, weights).filter { $0.1 > 0 }.map { ($0.0, $0.1) }
    }

    private static func distance2(_ x: Lab, _ y: Lab) -> Double {
        let dl = x.l - y.l, da = x.a - y.a, db = x.b - y.b
        return dl * dl + da * da + db * db
    }
    private static func distance(_ x: Lab, _ y: Lab) -> Double { distance2(x, y).squareRoot() }
    private static func round4(_ v: Double) -> Double { (min(1, max(0, v)) * 10000).rounded() / 10000 }

    // Oklab (Björn Ottosson) ↔ sRGB.
    private static func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    private static func gam(_ c: Double) -> Double { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055 }

    static func oklab(r: Double, g: Double, b: Double) -> Lab {
        let lr = lin(r), lg = lin(g), lb = lin(b)
        let l = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
        let m = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
        let s = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
        return Lab(l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                   a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                   b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    static func srgb(_ c: Lab) -> (Double, Double, Double) {
        let l = pow(c.l + 0.3963377774 * c.a + 0.2158037573 * c.b, 3)
        let m = pow(c.l - 0.1055613458 * c.a - 0.0638541728 * c.b, 3)
        let s = pow(c.l - 0.0894841775 * c.a - 1.2914855480 * c.b, 3)
        let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        return (gam(min(1, max(0, r))), gam(min(1, max(0, g))), gam(min(1, max(0, b))))
    }

    /// Relative luminance of an sRGB colour (for "brightest-first" checks).
    static func luminance(_ c: RGBA) -> Double { oklab(r: c.r, g: c.g, b: c.b).l }
}
