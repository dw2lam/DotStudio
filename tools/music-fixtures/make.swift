//  make.swift — writes Now Playing fixtures (MusicState JSON + artwork) for offscreen
//  renders, with no real player: point DOTSTUDIO_MUSIC_FAKE at one of the JSON files.
//  Times are "now" when written (a playing fixture goes stale after its track would have
//  ended), so run make.sh right before rendering. UIShots refreshes the times itself.
//
//  usage: swift make.swift <outDir> <photosDir>     (tools/music-fixtures/make.sh wraps it)

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let photos = URL(fileURLWithPath: CommandLine.arguments[2])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func ctx(_ n: Int) -> CGContext {
    CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func save(_ c: CGContext, _ name: String) {
    let url = out.appendingPathComponent(name)
    let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, c.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
    CGImageDestinationFinalize(d)
}
func col(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

// Synth-pop cover: pink → indigo with rings.
do {
    let n = 1000, c = ctx(n)
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                       colors: [col(1.0, 0.42, 0.62), col(0.20, 0.12, 0.52)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(g, start: CGPoint(x: 0, y: n), end: CGPoint(x: n, y: 0), options: [])
    for i in 0..<7 {
        c.setStrokeColor(col(1, 0.9, 0.7, 0.55 - Double(i) * 0.06)); c.setLineWidth(10)
        let r = CGFloat(120 + i * 55)
        c.strokeEllipse(in: CGRect(x: 640 - r, y: 380 - r, width: r * 2, height: r * 2))
    }
    c.setFillColor(col(1, 0.85, 0.35)); c.fillEllipse(in: CGRect(x: 560, y: 300, width: 160, height: 160))
    save(c, "art-synth.jpg")
}
// Podcast: orange block with bold lettering.
do {
    let n = 1000, c = ctx(n)
    c.setFillColor(col(0.96, 0.42, 0.10)); c.fill(CGRect(x: 0, y: 0, width: n, height: n))
    c.setFillColor(col(0.10, 0.06, 0.20)); c.fill(CGRect(x: 0, y: 0, width: n, height: 300))
    let s = NSAttributedString(string: "LATE\nSHOW", attributes: [
        .font: NSFont.systemFont(ofSize: 210, weight: .black), .foregroundColor: NSColor.white])
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
    s.draw(at: NSPoint(x: 60, y: 340))
    NSGraphicsContext.restoreGraphicsState()
    save(c, "art-podcast.jpg")
}
// A bright cover — the hard case for white type: near-white paper with pale pastel shapes.
do {
    let n = 1000, c = ctx(n)
    c.setFillColor(col(0.97, 0.95, 0.90)); c.fill(CGRect(x: 0, y: 0, width: n, height: n))
    c.setFillColor(col(1.0, 0.86, 0.55)); c.fillEllipse(in: CGRect(x: 420, y: 430, width: 460, height: 460))
    c.setFillColor(col(0.70, 0.86, 0.98, 0.85)); c.fill(CGRect(x: 90, y: 120, width: 420, height: 300))
    c.setFillColor(col(1.0, 0.70, 0.74, 0.8)); c.fillEllipse(in: CGRect(x: 120, y: 520, width: 260, height: 260))
    save(c, "art-bright.jpg")
}
// Photo crops from the bundled slideshow set.
func crop(_ file: String, _ name: String) {
    guard let src = CGImageSourceCreateWithURL(photos.appendingPathComponent(file) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
    let s = min(img.width, img.height)
    let sq = img.cropping(to: CGRect(x: (img.width - s) / 2, y: (img.height - s) / 2, width: s, height: s))!
    let n = 1200, c = ctx(n)
    c.interpolationQuality = .high
    c.draw(sq, in: CGRect(x: 0, y: 0, width: n, height: n))
    save(c, name)
}
crop("06-wadi-rum.jpg", "art-wadirum.jpg")
crop("05-lady-fern.jpg", "art-fern.jpg")
crop("04-budapest-night.jpg", "art-budapest.jpg")

let now = Date().timeIntervalSince1970
func write(_ name: String, _ d: [String: Any]) {
    var d = d
    d["updatedAt"] = now
    let data = try! JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: out.appendingPathComponent(name + ".json"))
}
func pal(_ cs: [[Double]]) -> [[String: Double]] { cs.map { ["r": $0[0], "g": $0[1], "b": $0[2], "a": 1] } }

// The everyday case: a normal-length title from Spotify.
write("playing", ["source": "spotify", "title": "Weightless", "artist": "Marconi Union", "album": "Ambient Transmissions",
                  "duration": 488.0, "position": 131.0, "positionAt": now, "isPlaying": true, "artwork": "art-budapest.jpg",
                  "trackID": "spotify:track:fixture-playing"])
write("long", ["source": "spotify", "title": "The Less I Know the Better (Extended Live Session Recorded at Abbey Road Studios, 2024 Remaster)",
               "artist": "Tame Impala & The Wonderful Orchestra of Unreasonably Long Names",
               "album": "Currents (Deluxe Anniversary Collector’s Edition)",
               "duration": 296.0, "position": 83.0, "positionAt": now, "isPlaying": true, "artwork": "art-wadirum.jpg",
               "trackID": "spotify:track:fixture-long"])
write("cjk", ["source": "music", "title": "夜に駆ける", "artist": "YOASOBI", "album": "THE BOOK",
              "duration": 261.0, "position": 140.0, "positionAt": now, "isPlaying": true, "artwork": "art-synth.jpg",
              "palette": pal([[1.0, 0.55, 0.70], [0.62, 0.30, 0.62], [0.20, 0.12, 0.45]]), "trackID": "music:fixture-cjk"])
write("emoji", ["source": "spotify", "title": "🌊 Waves 🌙 (feat. Ñandú & Zoë)", "artist": "Ólafur Arnalds ✨",
                "album": "Some Kind of Peace", "duration": 214.0, "position": 21.0, "positionAt": now, "isPlaying": true,
                "artwork": "art-fern.jpg", "trackID": "spotify:track:fixture-emoji"])
write("podcast", ["source": "spotify", "title": "Episode 412: How Screensavers Saved the CRT, and Why We Still Love Flying Toasters",
                  "artist": "The Late Show Podcast", "album": "The Late Show Podcast", "duration": 5_412.0,
                  "position": 1_820.0, "positionAt": now, "isPlaying": true, "isPodcast": true,
                  "artwork": "art-podcast.jpg", "trackID": "spotify:episode:fixture-412"])
write("paused", ["source": "music", "title": "Blinding Lights", "artist": "The Weeknd", "album": "After Hours",
                 "duration": 200.0, "position": 61.0, "positionAt": now - 30, "isPlaying": false, "pausedAt": now - 30,
                 "artwork": "art-budapest.jpg", "trackID": "music:fixture-paused"])
write("bright", ["source": "music", "title": "Daylight", "artist": "Harbour Lights", "album": "Paper Summer",
                 "duration": 233.0, "position": 70.0, "positionAt": now, "isPlaying": true, "artwork": "art-bright.jpg",
                 "trackID": "music:fixture-bright"])
write("noart", ["source": "music", "title": "Clair de Lune", "artist": "Claude Debussy", "album": "Suite bergamasque",
                "duration": 302.0, "position": 150.0, "positionAt": now, "isPlaying": true,
                "palette": pal([[0.55, 0.68, 0.92], [0.30, 0.38, 0.60], [0.08, 0.10, 0.20]]), "trackID": "music:fixture-noart"])
write("idle", [:])
print("fixtures written to \(out.path)")
