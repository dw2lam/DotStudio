//  MusicSelfTest.swift — headless end-to-end test of music detection, with NO real player:
//  posts synthetic distributed notifications (fake payloads, on a private name prefix so
//  other apps listening to the real Spotify/Music names never see them), then checks what
//  renderers would read — music.json + cover + palette, through the real MusicFeed.
//
//  Run:  tools/music-selftest/run.sh <outDir>      (builds a CLI from Shared + App/Music)
//  The UI stage may also wire DOTSTUDIO_MUSIC_SELFTEST=<outDir> to `MusicSelfTest.runAndExit`.
//
//  Apple Events are dry-run throughout (counted, never sent), and the "real gating" phase
//  asserts that nothing is even attempted while Spotify / Music aren't running.
//  Network: real lookups against open.spotify.com/oembed and itunes.apple.com.

import AppKit

@MainActor
enum MusicSelfTest {
    static func runAndExit(outDir: String) -> Never {
        exit(run(outDir: outDir))
    }

    // MARK: Harness state

    private static var passed = 0
    private static var failed: [String] = []
    private static var out: URL!
    private static var stepIndex = 0
    private static var prefix = ""
    private static var feed: MusicFeed!
    private static var storeDir: URL!

    private static func say(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }

    private static func check(_ ok: Bool, _ what: String) {
        if ok { passed += 1; say("  PASS  \(what)") } else { failed.append(what); say("  FAIL  \(what)") }
    }

    private static func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(mode: .default, before: min(end, Date().addingTimeInterval(0.02))) }
    }

    /// Sleeps in the run loop (no polling) so the CPU measurement sees only the monitor.
    private static func idle(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            let t = Date()
            RunLoop.main.run(mode: .default, before: end)
            if Date().timeIntervalSince(t) < 0.001 { usleep(50_000) }   // no input sources: don't spin
        }
    }

    @discardableResult
    private static func wait(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return cond()
    }

    /// Posted like the players do — WITHOUT the poster-side deliverImmediately override, so
    /// delivery to an inactive (suspended) app depends on the monitor's observer flag.
    private static func post(_ name: String, _ info: [String: Any]?) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(prefix + name), object: nil, userInfo: info, deliverImmediately: false)
    }
    private static func spotify(_ info: [String: Any]?) { post("com.spotify.client.PlaybackStateChanged", info) }
    private static func music(_ info: [String: Any]?) { post("com.apple.Music.playerInfo", info) }

    /// Re-reads music.json through the contract reader.
    private static var current: MusicState? { feed.poll(); return feed.state }

    private static func near(_ a: Double?, _ b: Double, _ tol: Double) -> Bool { a.map { abs($0 - b) <= tol } ?? false }

    /// Saves music.json + the cover + a palette swatch sheet for review.
    private static func snapshot(_ name: String) {
        stepIndex += 1
        let base = out.appendingPathComponent("steps", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let tag = String(format: "%02d-%@", stepIndex, name)
        let json = storeDir.appendingPathComponent(MusicState.fileName)
        try? FileManager.default.copyItem(at: json, to: base.appendingPathComponent(tag + ".json"))
        feed.poll()
        if let s = feed.state, let art = s.artwork {
            try? FileManager.default.copyItem(at: feed.artDir.appendingPathComponent(art),
                                              to: base.appendingPathComponent(tag + "-art.jpg"))
            if let image = feed.artwork { writeSwatch(image, palette: s.palette ?? [], to: base.appendingPathComponent(tag + "-palette.png")) }
        }
    }

    private static func writeSwatch(_ art: CGImage, palette: [RGBA], to url: URL) {
        let side = 256, bar = 56
        guard let ctx = CGContext(data: nil, width: side, height: side + bar, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: MusicArtImage.srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.draw(art, in: CGRect(x: 0, y: bar, width: side, height: side))
        let w = palette.isEmpty ? side : side / palette.count
        for (i, c) in palette.enumerated() {
            ctx.setFillColor(CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1))
            ctx.fill(CGRect(x: i * w, y: 0, width: i == palette.count - 1 ? side - i * w : w, height: bar))
        }
        guard let img = ctx.makeImage(),
              let dst = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dst, img, nil)
        CGImageDestinationFinalize(dst)
    }

    private static func artFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: feed.artDir.path)) ?? []).filter { $0.hasPrefix("art-") }.sorted()
    }

    private static func checkArtAndPalette(_ s: MusicState?, minPixels: Int, _ label: String) {
        check(s?.artwork != nil, "\(label): artwork named in music.json (\(s?.artwork ?? "nil"))")
        if let a = s?.artwork {
            check(FileManager.default.fileExists(atPath: feed.artDir.appendingPathComponent(a).path), "\(label): artwork file exists in music/")
        }
        let px = feed.artwork.map { max($0.width, $0.height) } ?? 0
        check(px >= minPixels, "\(label): artwork decodes via MusicFeed at \(px) px (≥ \(minPixels))")
        let p = s?.palette ?? []
        check((3...5).contains(p.count), "\(label): palette has \(p.count) colours (3–5)")
        let lum = p.map(MusicPalette.luminance)
        check(zip(lum, lum.dropFirst()).allSatisfy { $0 >= $1 - 1e-9 }, "\(label): palette brightest-first \(lum.map { String(format: "%.2f", $0) })")
        check(p.allSatisfy { (0...1).contains($0.r) && (0...1).contains($0.g) && (0...1).contains($0.b) && $0.a == 1 }, "\(label): palette values in 0…1 sRGB")
    }

    // MARK: Run

    static func run(outDir: String) -> Int32 {
        out = URL(fileURLWithPath: outDir, isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: out)
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        storeDir = out.appendingPathComponent("store", isDirectory: true)
        try? fm.createDirectory(at: storeDir, withIntermediateDirectories: true)
        setenv("DOTSTUDIO_STORE_DIR", storeDir.path, 1)
        unsetenv("DOTSTUDIO_MUSIC_FAKE")
        let store = SharedStore(role: .app)
        feed = MusicFeed(baseDir: store.baseDir)
        let realSpotifyRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty
        let realMusicRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
        say("music self-test — store \(storeDir.path)")
        say("real players running: Spotify \(realSpotifyRunning), Music \(realMusicRunning) (never contacted: Apple Events are dry-run)")

        // ── Phase A: real gating (workspace detection), dry-run Apple Events, real network ──
        prefix = "com.davidlam.DotStudio.selftest.\(getpid()).a."
        var opts = MusicMonitor.Options()
        opts.appleEvents.dryRun = true
        opts.notificationPrefix = prefix
        opts.logging = true
        opts.logToStderr = ProcessInfo.processInfo.environment["DOTSTUDIO_MUSIC_MONITOR_LOG"] == "1"
        let m = MusicMonitor(options: opts)

        say("\n[0] Payload parsing (unit)")
        let sp = MusicSpotifyAdapter(), am = MusicAppleMusicAdapter()
        check(MusicSpotifyAdapter.normalizedURI("https://open.spotify.com/intl-de/track/4cOdK2wGLETKBW3PvgPWqT?si=x") == "spotify:track:4cOdK2wGLETKBW3PvgPWqT",
              "Spotify web link → URI")
        let ad = sp.parse(["Track ID": "spotify:ad:000000012c603a6600000020316a17a1", "Name": "", "Player State": "Playing", "Duration": 30000])
        check(ad.isAd && ad.title == "Advertisement", "Spotify ad recognised (placeholder art, titled)")
        check(sp.parse(["Track ID": "spotify:local:Artist:Album:Song:215", "Name": "Song", "Player State": "Paused"]).isLocal, "Spotify local file recognised")
        check(MusicAppleMusicAdapter.persistentHex(NSNumber(value: Int64(-1))) == "FFFFFFFFFFFFFFFF", "negative PersistentID → unsigned hex")
        check(MusicAppleMusicAdapter.persistentHex("a1b2c3d4e5f60718") == "A1B2C3D4E5F60718", "hex PersistentID string normalised")
        let ids = MusicAppleMusicAdapter.storeIDs("https://music.apple.com/ca/album/whenever/1612648318?i=1612648319")
        check(ids.track == "1612648319" && ids.album == "1612648318", "music.apple.com Store URL → track + album ids")
        let p = am.parse(["Persistent ID": "1A2B", "Name": "X", "Player State": "Stopped", "Total Time": "180000"])
        check(p.state == .stopped && p.trackID == "music:1A2B" && p.duration == 180, "'Persistent ID' spelling + numeric string Total Time")
        check(am.parse(nil).state == nil && !am.parse(nil).hasTrackFields, "nil userInfo → empty report")
        check(MusicArtworkResolver.largeAppleImage("https://is1-ssl.mzstatic.com/image/thumb/a/b.jpg/100x100bb.jpg").hasSuffix("/1200x1200bb.jpg"),
              "artworkUrl100 → 1200x1200bb")
        check(MusicArtworkResolver.largeSpotifyImage("https://i.scdn.co/image/ab67616d00001e02abc") == "https://i.scdn.co/image/ab67616d0000b273abc",
              "Spotify 300 px id → 640 px id")

        say("\n[start]")
        check(m.start(store: store), "start(store:) monitors with default settings (card on by default)")
        check(m.isMonitoring, "isMonitoring")
        m.flushWrites()
        check(wait(2) { current != nil && current?.hasTrack == false }, "start clears music.json (empty state written)")

        say("\n[1] Spotify track — payload + real oEmbed lookup")
        let t0 = Date().timeIntervalSince1970
        spotify(["Name": "Never Gonna Give You Up", "Artist": "Rick Astley", "Album": "Whenever You Need Somebody",
                 "Duration": 213_573, "Track ID": "spotify:track:4cOdK2wGLETKBW3PvgPWqT",
                 "Playback Position": 12.5, "Player State": "Playing", "Disc Number": 1, "Popularity": 77])
        check(wait(15) { current?.artwork != nil && current?.title == "Never Gonna Give You Up" }, "music.json shows the Spotify track with artwork")
        var s = current
        check(s?.source == .spotify, "source = spotify")
        check(s?.artist == "Rick Astley" && s?.album == "Whenever You Need Somebody", "artist / album")
        check(near(s?.duration, 213.573, 0.001), "duration 213.573 s (from ms)")
        check(s?.isPlaying == true && s?.pausedAt == nil, "isPlaying, no pausedAt")
        check(near(s?.position, 12.5, 0.01) && near(s?.positionAt, t0, 2), "position 12.5 s measured at notification time")
        check(s?.positionIsApproximate == false, "Spotify position is exact")
        check(near(s.map { $0.elapsed() }, 12.5 + (Date().timeIntervalSince1970 - t0), 1.0), "elapsed() extrapolates while playing")
        check(s?.trackID == "spotify:track:4cOdK2wGLETKBW3PvgPWqT", "trackID = Spotify URI")
        check(s?.isPodcast == false, "not a podcast")
        check(s?.isVisible(lingerMinutes: 5) == true, "visible to renderers")
        checkArtAndPalette(s, minPixels: 600, "spotify")
        check(m.state == s.map { var x = $0; x.updatedAt = nil; return x }, "@Published state mirrors music.json")
        check(m.artwork != nil, "@Published artwork image for in-app UI")
        check(m.activeSource == .spotify && m.spotify.isPlaying && m.spotify.hasTrack, "player status: Spotify playing")
        snapshot("spotify-playing")

        say("\n[2] Spotify pause → linger fields")
        let tp = Date().timeIntervalSince1970
        spotify(["Name": "Never Gonna Give You Up", "Artist": "Rick Astley", "Album": "Whenever You Need Somebody",
                 "Duration": 213_573, "Track ID": "spotify:track:4cOdK2wGLETKBW3PvgPWqT",
                 "Playback Position": 20.0, "Player State": "Paused"])
        check(wait(3) { current?.isPlaying == false }, "isPlaying false after Paused")
        s = current
        check(near(s?.pausedAt, tp, 2), "pausedAt ≈ now")
        check(near(s?.position, 20.0, 0.01) && near(s.map { $0.elapsed() }, 20.0, 0.01), "position frozen at 20 s")
        let pausedAt = s?.pausedAt ?? 0
        check(s?.isVisible(at: Date(timeIntervalSince1970: pausedAt + 4.9 * 60), lingerMinutes: 5) == true, "still visible 4.9 min after pause")
        check(s?.isVisible(at: Date(timeIntervalSince1970: pausedAt + 5.1 * 60), lingerMinutes: 5) == false, "hidden 5.1 min after pause (5-min linger)")
        check(s?.artwork != nil, "artwork kept while paused")
        // A repeat Paused report must not extend the linger.
        pump(1.1)
        spotify(["Name": "Never Gonna Give You Up", "Track ID": "spotify:track:4cOdK2wGLETKBW3PvgPWqT", "Playback Position": 20.0, "Player State": "Paused"])
        pump(0.5)
        check(current?.pausedAt == pausedAt, "repeated Paused keeps the original pausedAt")
        snapshot("spotify-paused")

        say("\n[3] Spotify Stopped → clear")
        spotify(["Player State": "Stopped"])
        check(wait(3) { current?.hasTrack == false }, "Stopped clears the track")
        s = current
        check(s?.artwork == nil && s?.title == nil && feed.isVisible(settings: MusicSpec()) == false, "nothing visible, no artwork")
        check(m.activeSource == nil && m.spotify.hasTrack == false, "no active source")
        check(artFiles().count <= 1, "old covers pruned (\(artFiles().count) left, previous kept briefly)")
        snapshot("spotify-stopped")

        say("\n[4] Apple Music catalog track — Store URL → real iTunes lookup")
        let persistent: Int64 = -5_123_456_789_012_345_678
        let tm = Date().timeIntervalSince1970
        music(["Name": "Never Gonna Give You Up (2022 Remaster)", "Artist": "Rick Astley",
               "Album": "Whenever You Need Somebody (Deluxe Edition - 2022 Remaster)", "Total Time": 213_000,
               "Player State": "Playing", "PersistentID": NSNumber(value: persistent),
               "Store URL": "itms://itunes.com/album?p=1612648318&i=1612648319", "Genre": "Pop", "Rating": 0])
        check(wait(15) { current?.artwork != nil && current?.source == .music }, "music.json shows the Music track with artwork")
        s = current
        let hex = String(format: "%016llX", UInt64(bitPattern: persistent))
        check(s?.trackID == "music:" + hex, "trackID = music:<hex persistent id> (\(s?.trackID ?? "nil"))")
        check(s?.positionIsApproximate == true, "no Automation ⇒ position approximate")
        check(near(s?.position, 0, 0.01) && near(s?.positionAt, tm, 2), "position counted from 0 at track start")
        check(near(s?.duration, 213, 0.01), "duration from Total Time (ms)")
        checkArtAndPalette(s, minPixels: 1000, "music catalog")
        let writesBefore = m.writer?.writeCount ?? 0
        pump(2.0)
        check(near(current.map { $0.elapsed() }, Date().timeIntervalSince1970 - tm, 1.0), "approximate position advances by extrapolation")
        check((m.writer?.writeCount ?? 0) == writesBefore, "idle playback writes nothing (readers extrapolate)")
        snapshot("music-catalog")

        say("\n[5] Apple Music local file — search fallback")
        music(["Name": "Wonderwall", "Artist": "Oasis", "Album": "(What's the Story) Morning Glory?", "Total Time": 258_000,
               "Player State": "Playing", "PersistentID": NSNumber(value: Int64(0x1234_5678_9ABC_DEF0)),
               "Location": "file:///Users/test/Music/Oasis/Wonderwall.m4a"])
        check(wait(15) { current?.title == "Wonderwall" && current?.artwork != nil }, "local file gets artwork from iTunes search")
        s = current
        check(s?.trackID == "music:123456789ABCDEF0", "local file trackID")
        checkArtAndPalette(s, minPixels: 1000, "music local")
        snapshot("music-local")

        say("\n[6] Apple Music pause → resume (approximate position freezes, then continues)")
        pump(1.0)
        music(["Name": "Wonderwall", "Artist": "Oasis", "Album": "(What's the Story) Morning Glory?", "Total Time": 258_000,
               "Player State": "Paused", "PersistentID": NSNumber(value: Int64(0x1234_5678_9ABC_DEF0))])
        check(wait(3) { current?.isPlaying == false }, "Music paused")
        s = current
        let frozen = s?.position ?? -1
        check(frozen > 0.5 && near(s?.pausedAt, Date().timeIntervalSince1970, 2), "position frozen at \(String(format: "%.2f", frozen)) s, pausedAt set")
        pump(1.5)
        check(near(current.map { $0.elapsed() }, frozen, 0.001), "elapsed doesn't move while paused")
        music(["Name": "Wonderwall", "Artist": "Oasis", "Album": "(What's the Story) Morning Glory?", "Total Time": 258_000,
               "Player State": "Playing", "PersistentID": NSNumber(value: Int64(0x1234_5678_9ABC_DEF0))])
        check(wait(3) { current?.isPlaying == true }, "Music resumed")
        s = current
        check(s?.pausedAt == nil && near(s?.position, frozen, 0.01), "resume keeps the frozen position, clears pausedAt")
        snapshot("music-resumed")

        say("\n[7] Podcasts")
        spotify(["Name": "Episode 12: Long Talk", "Artist": "Some Show", "Album": "Some Show", "Duration": 3_600_000,
                 "Track ID": "spotify:episode:0000000000000000000001", "Playback Position": 600.0, "Player State": "Playing"])
        check(wait(8) { current?.source == .spotify && current?.title == "Episode 12: Long Talk" }, "auto source follows the player that most recently started (Spotify)")
        s = current
        check(s?.isPodcast == true, "Spotify episode ⇒ isPodcast")
        check(wait(8) { m.state.title == "Episode 12: Long Talk" && current?.artwork == nil && m.artwork == nil }, "unknown episode ⇒ placeholder art (artwork nil)")
        music(["Name": "Long Mix", "Artist": "DJ", "Album": "Mixes", "Total Time": 1_800_000, "Player State": "Playing",
               "PersistentID": NSNumber(value: Int64(42))])
        check(wait(8) { current?.title == "Long Mix" }, "Music long track becomes active")
        check(current?.isPodcast == true, "duration > 15 min ⇒ isPodcast (heuristic)")
        snapshot("podcast")

        say("\n[8] Rapid skips — debounce + rate limit")
        let statsBefore = awaitStats(m)
        let writes0 = m.writer?.writeCount ?? 0
        spotify(["Player State": "Stopped"])
        music(["Player State": "Stopped"])
        wait(3) { current?.hasTrack == false }
        let writes1 = m.writer?.writeCount ?? 0
        for i in 0..<8 {
            spotify(["Name": "Skip \(i)", "Artist": "Nobody", "Album": "Skips", "Duration": 200_000,
                     "Track ID": String(format: "spotify:track:FAKEFAKEFAKEFAKEFAKE%02d", i), "Playback Position": 0.0, "Player State": "Playing"])
            pump(0.12)
        }
        spotify(["Name": "Mr. Brightside", "Artist": "The Killers", "Album": "Hot Fuss", "Duration": 222_973,
                 "Track ID": "spotify:track:3n3Ppam7vgaVa1iaRUc9Lp", "Playback Position": 0.0, "Player State": "Playing"])
        check(wait(15) { current?.title == "Mr. Brightside" && current?.artwork != nil }, "settles on the last track with its artwork")
        pump(1.0)
        let statsAfter = awaitStats(m)
        let oembeds = (statsAfter?.spotifyRequests.count ?? 0) - (statsBefore?.spotifyRequests.count ?? 0)
        let skipWrites = (m.writer?.writeCount ?? 0) - writes1
        check(oembeds <= 2, "9 tracks in ~1 s → \(oembeds) oEmbed request(s) (debounced; only the settled track)")
        check(skipWrites <= 4, "9 tracks in ~1 s → \(skipWrites) music.json writes (coalesced)")
        _ = writes0
        snapshot("rapid-skips")

        // Apple: rapid Music skips with store ids — only the settled one is looked up.
        let appleBefore = statsAfter?.appleRequests.count ?? 0
        for i in 0..<6 {
            music(["Name": "Store Skip \(i)", "Artist": "Rick Astley", "Album": "Whenever You Need Somebody (Deluxe Edition - 2022 Remaster)",
                   "Total Time": 200_000, "Player State": "Playing", "PersistentID": NSNumber(value: Int64(1000 + i)),
                   "Store URL": "itms://itunes.com/album?p=1612648318&i=\(1612648319 + i)"])
            pump(0.1)
        }
        check(wait(15) { current?.title == "Store Skip 5" && m.state.artwork != nil }, "Music rapid skips settle with artwork")
        let appleStats = awaitStats(m)
        let appleDelta = (appleStats?.appleRequests.count ?? 0) - appleBefore
        check(appleDelta <= 2, "6 Music skips → \(appleDelta) iTunes request(s)")
        let times = (appleStats?.appleRequests ?? []).map(\.timeIntervalSince1970).sorted()
        let maxPerMinute = times.indices.map { i in times[i...].prefix { $0 - times[i] < 60 }.count }.max() ?? 0
        check(maxPerMinute <= 20, "iTunes requests in any 60 s window: \(maxPerMinute) (≤ 20)")

        say("\n[9] Rate limiter (unit)")
        var limiter = MusicRateLimiter(limit: 20, per: 60)
        let base = Date(timeIntervalSince1970: 1_000_000)
        let first20 = (0..<20).map { limiter.reserve(now: base.addingTimeInterval(Double($0) * 0.1)) }
        check(first20.allSatisfy { $0 == 0 }, "first 20 requests go immediately")
        let w21 = limiter.reserve(now: base.addingTimeInterval(2))
        check(abs(w21 - 58) < 0.01, "21st waits until the first leaves the window (\(String(format: "%.1f", w21)) s)")
        let w22 = limiter.reserve(now: base.addingTimeInterval(2))
        check(abs(w22 - 58.1) < 0.01, "22nd queues behind it (\(String(format: "%.1f", w22)) s)")
        check(limiter.reserve(now: base.addingTimeInterval(200)) == 0, "free again after the window")

        say("\n[10] Unknown / garbage payloads")
        spotify(nil)
        spotify(["Player State": 42])
        spotify(["Name": 42, "Artist": ["x"], "Duration": "abc", "Player State": "Banana", "Track ID": 7])
        spotify(["Duration": true, "Playback Position": -5, "Player State": "Playing"])
        music(["Total Time": "soon", "PersistentID": "zzz", "Store URL": "::not a url::"])
        pump(1.0)
        check(m.isMonitoring && current?.title == "Store Skip 5", "garbage ignored; current track unchanged")
        spotify(["Name": "", "Artist": "", "Player State": "Playing"])
        music(["Name": "", "Player State": "Playing"])
        check(wait(3) { current?.hasTrack == false }, "empty track ⇒ nothing playing")
        music(["Name": "Odd", "Artist": "X", "Total Time": -5, "Store URL": "::not a url::", "PersistentID": "zzz", "Player State": "Fast Forwarding"])
        check(wait(8) { current?.title == "Odd" && current?.isPlaying == true }, "odd-but-valid payload accepted (Fast Forwarding = playing)")
        check(current?.duration == nil, "negative duration dropped")
        music(["Player State": "Stopped"])
        check(wait(3) { current?.hasTrack == false }, "Stopped clears")
        snapshot("garbage")

        say("\n[11] Source preference")
        spotify(["Name": "Mr. Brightside", "Artist": "The Killers", "Album": "Hot Fuss", "Duration": 222_973,
                 "Track ID": "spotify:track:3n3Ppam7vgaVa1iaRUc9Lp", "Playback Position": 5.0, "Player State": "Playing"])
        pump(0.3)
        music(["Name": "Wonderwall", "Artist": "Oasis", "Album": "(What's the Story) Morning Glory?", "Total Time": 258_000,
               "Player State": "Paused", "PersistentID": NSNumber(value: Int64(0x1234_5678_9ABC_DEF0))])
        check(wait(5) { current?.title == "Mr. Brightside" }, "auto: playing Spotify beats paused Music")
        var pinned = MusicSpec(); pinned.source = .music
        m.apply(settings: pinned)
        check(wait(5) { current?.title == "Wonderwall" && current?.source == .music }, "pinned to Apple Music ⇒ Music's (paused) track")
        check(wait(5) { current?.artwork != nil }, "pinned track's cover comes from the disk cache")
        m.apply(settings: MusicSpec())
        check(wait(5) { current?.title == "Mr. Brightside" }, "back to automatic")

        say("\n[11b] Inactive app: AppKit suspends distributed delivery — .deliverImmediately still gets through")
        let dnc = DistributedNotificationCenter.default()
        var controlHits = 0
        let control = MusicNotificationReceiver { _, _ in controlHits += 1 }   // negative control
        dnc.addObserver(control, selector: #selector(MusicNotificationReceiver.received(_:)),
                        name: Notification.Name(prefix + "com.spotify.client.PlaybackStateChanged"), object: nil,
                        suspensionBehavior: .drop)
        dnc.suspended = true
        spotify(["Name": "While Suspended", "Artist": "Nobody", "Album": "Tests", "Duration": 200_000,
                 "Track ID": "spotify:track:FAKEFAKEFAKEFAKEFAKE11", "Playback Position": 1.0, "Player State": "Playing"])
        check(wait(5) { current?.title == "While Suspended" }, "monitor's .deliverImmediately observer received it while suspended")
        pump(0.5)
        check(controlHits == 0, "a .drop observer on the same name did NOT (suspension was real)")
        dnc.suspended = false
        pump(0.3)
        spotify(["Name": "While Suspended", "Track ID": "spotify:track:FAKEFAKEFAKEFAKEFAKE11", "Playback Position": 2.0, "Player State": "Playing"])
        check(wait(3) { controlHits == 1 }, "…and the control does receive once resumed (\(controlHits))")
        dnc.suspended = false
        dnc.removeObserver(control)

        say("\n[12] Apple Events gating (real workspace detection)")
        if realSpotifyRunning || realMusicRunning {
            say("  SKIP  a real player is running — dry-run counted \(m.appleEvents.totalAttempts) would-be events, none sent")
        } else {
            check(m.appleEvents.totalAttempts == 0, "players not running ⇒ 0 Apple Events attempted (incl. permission checks)")
        }
        check(m.spotify.automation == .unknown && m.music.automation == .unknown, "automation status unknown while not running (never prompted)")
        check(m.playPause() == false && m.next() == false, "controls refuse when the player isn't running (never launch)")

        say("\n[13] stop() clears")
        m.stop()
        check(current?.hasTrack == false && !m.isMonitoring, "stop() writes an empty state")
        pump(0.3)
        spotify(["Name": "After Stop", "Track ID": "spotify:track:FAKEFAKEFAKEFAKEFAKEZZ", "Player State": "Playing"])
        pump(0.5)
        check(current?.hasTrack == false, "no observers after stop()")
        var off = MusicSpec(); off.cardEnabled = false
        check(m.start(store: store, settings: off) == false && !m.isMonitoring, "start() is a no-op when nothing needs monitoring")

        // ── Phase B: Spotify "running" (fake pid), dry-run Apple Events ──
        say("\n[14] Fake-running Spotify (dry-run AE): gating, optimistic controls, position poll")
        prefix = "com.davidlam.DotStudio.selftest.\(getpid()).b."
        var optsB = opts
        optsB.notificationPrefix = prefix
        optsB.observeWorkspace = false
        optsB.pidOverride = [.spotify: getpid()]   // dry-run: never addressed
        let b = MusicMonitor(options: optsB)
        check(b.start(store: store), "start")
        check(wait(3) { b.spotify.automation == .allowed }, "permission checked for the running player only")
        check(wait(2) { b.appleEvents.attempts(.spotify) >= 1 }, "running + allowed ⇒ state-at-launch snapshot attempted (\(b.appleEvents.attempts(.spotify)), dry-run)")
        let a0 = b.appleEvents.attempts(.spotify)
        spotify(["Name": "Blinding Lights", "Artist": "The Weeknd", "Album": "After Hours",
                 "Duration": 200_040, "Track ID": "spotify:track:0VjIjW4GlUZAMYd2vXMi3b",
                 "Playback Position": 30.0, "Player State": "Playing"])
        check(wait(15) { current?.title == "Blinding Lights" && current?.artwork != nil }, "track + cover with AE dry-run (falls back to oEmbed)")
        check(b.appleEvents.attempts(.spotify) > a0, "artwork tried via Apple Events first (\(b.appleEvents.attempts(.spotify) - a0) attempt(s), dry-run)")
        check(b.appleEvents.attempts(.music) == 0 && b.appleEvents.permissionChecks(.music) == 0, "Music not running ⇒ 0 events to Music")

        let tc = Date()
        check(b.playPause(), "playPause() accepted")
        check(b.state.isPlaying == false && b.isControlPending, "optimistic: paused immediately (pending window open)")
        check(wait(2) { current?.isPlaying == false }, "optimistic pause written to music.json")
        spotify(["Name": "Blinding Lights", "Track ID": "spotify:track:0VjIjW4GlUZAMYd2vXMi3b", "Playback Position": 31.0, "Player State": "Playing"])
        pump(0.4)
        check(Date().timeIntervalSince(tc) < 1.5 && b.state.isPlaying == false, "stale 'Playing' inside 1.5 s ignored (no flicker)")
        pump(max(0, 1.6 - Date().timeIntervalSince(tc)))
        spotify(["Name": "Blinding Lights", "Track ID": "spotify:track:0VjIjW4GlUZAMYd2vXMi3b", "Playback Position": 32.0, "Player State": "Playing"])
        check(wait(2) { b.state.isPlaying == true }, "after the window the player's report wins")
        let before = b.appleEvents.attempts(.spotify)
        check(b.next(), "next() accepted")
        check(wait(2) { b.appleEvents.attempts(.spotify) > before }, "next() sent through the AE queue (dry-run)")

        b.beginPositionUpdates()
        check(b.isPollingPosition, "beginPositionUpdates starts the 1 s poll (AE allowed)")
        pump(3.3)
        check(b.pollTicks >= 3, "poll ticked \(b.pollTicks)× in 3.3 s")
        b.endPositionUpdates()
        check(!b.isPollingPosition, "endPositionUpdates stops it")

        say("\n[15] Idle CPU")
        let cpu0 = cpuSeconds()
        let ticks0 = b.pollTicks
        let top = Process()
        top.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        top.arguments = ["-l", "3", "-s", "2", "-pid", String(getpid()), "-stats", "pid,cpu,threads,command"]
        let pipe = Pipe()
        top.standardOutput = pipe
        try? top.run()
        idle(8.0)
        top.waitUntilExit()
        let cpu = cpuSeconds() - cpu0
        let topOut = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let topLines = topOut.split(separator: "\n").filter { $0.hasPrefix(String(getpid())) }
        say("  top: " + topLines.map { String($0) }.joined(separator: " | "))
        check(cpu < 0.08, "idle 8 s with monitoring on: \(String(format: "%.3f", cpu)) s CPU (\(String(format: "%.2f", cpu / 8 * 100)) %)")
        check(b.pollTicks == ticks0, "no polling while no view observes progress")

        b.playerQuit(.spotify)
        check(wait(2) { current?.hasTrack == false }, "player quit (workspace terminate) ⇒ clear")
        b.stop()

        let logText = (try? String(contentsOf: storeDir.appendingPathComponent("debug.log"), encoding: .utf8)) ?? ""
        check(logText.contains("[music") && logText.contains("track →") && logText.contains("active source →"),
              "transitions logged to the debug log (\(logText.split(separator: "\n").count) lines)")
        try? FileManager.default.copyItem(at: storeDir.appendingPathComponent("debug.log"), to: out.appendingPathComponent("debug.log"))
        say("\n\(passed) passed, \(failed.count) failed")
        for f in failed { say("  FAILED: \(f)") }
        return failed.isEmpty ? 0 : 1
    }

    private static func awaitStats(_ m: MusicMonitor) -> MusicArtStats? {
        var result: MusicArtStats?
        var done = false
        Task { @MainActor in result = await m.artStats(); done = true }
        wait(5) { done }
        return result
    }

    private static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
    }
}
