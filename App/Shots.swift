//  Shots.swift — headless gallery renderer. Triggered by the DOTSTUDIO_SHOTS env
//  var (an output directory): renders every screensaver to a PNG and exits.

import AppKit

enum Shots {
    static func run(outDir: String) {
        let store = SharedStore(role: .app)
        let lib = store.load() ?? DefaultPresets.makeLibrary()
        guard let renderer = MetalRenderer(pixelFormat: .bgra8Unorm, store: store) else { exit(1) }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        for preset in lib.presets {
            guard let cg = renderer.renderThumbnail(preset: preset, source: lib.source,
                                                    width: 1600, height: 1000, time: 1.6) else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            guard let data = rep.representation(using: .png, properties: [:]) else { continue }
            let name = preset.name.replacingOccurrences(of: " ", with: "-")
            let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(name).png")
            try? data.write(to: url)
            FileHandle.standardOutput.write(Data("rendered \(preset.name)\n".utf8))
        }
        exit(0)
    }
}
