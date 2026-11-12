//  PresetShare.swift — the .dotstudiopreset share format (File ▸ Export Style…), shared by the
//  app and dotstudio-mcp's export_style / import_style.

import Foundation

/// On-disk format of a .dotstudiopreset share file.
struct PresetExport: Codable {
    var formatVersion: Int = 1
    var preset: Preset
    /// Included only for gradient sources — media files don't travel with presets.
    var source: SourceSpec?

    /// Decode a share file. Effects whose kind this build doesn't know are skipped (files from
    /// newer app versions import instead of failing outright) — and kept with the style
    /// (Preset.unknownEffects) for a newer build; a style made only of those can't import.
    static func decodeShared(_ data: Data) throws -> (Preset, skippedEffects: Int, source: SourceSpec?) {
        let doc = try JSONDecoder().decode(PresetExport.self, from: data)
        if doc.preset.isUnknownToThisBuild {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey:
                "“\(doc.preset.name)” was made with a newer version of DotStudio: none of its effects are available in this version."])
        }
        // A shared file can say anything: every param clamped to its range (SafeNumbers).
        var preset = doc.preset
        preset.sanitize()
        var source = doc.source
        if let s = source?.slideSeconds, !s.isFinite { source?.slideSeconds = nil }
        if let m = source?.motion, !m.isFinite { source?.motion = nil }
        return (preset, preset.unknownEffects.count, source)
    }

    /// The share file for a style (a gradient source travels with it; media doesn't).
    static func encode(_ preset: Preset, library: Library) throws -> Data {
        var doc = PresetExport(preset: preset)
        if library.source.kind == .gradient { doc.source = library.source }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(doc)
    }
}
