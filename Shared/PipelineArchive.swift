//  PipelineArchive.swift — the screensaver's pipelines, compiled ahead of time by the app.
//
//  A Metal binary archive holds pipelines already compiled for one GPU and macOS: building a
//  pipeline from it is a lookup (~1 ms) instead of a compile (fx_fragment: ~3 s cold — see
//  FXPipelines.swift). The app (unsandboxed) harvests one for the installed saver's metallib
//  after every install or update, into the shared folder; the saver (sandboxed, read-only)
//  loads it when its manifest matches the saver's own metallib, this macOS and this GPU.
//  Anything else — no archive yet, a stale one, a different GPU, a load that fails — and
//  FXPipelines compiles as before, just without blocking the saver.
//
//  <shared folder>/PipelineCache/saver.binarchive + saver.json (the manifest, written last).

import Metal
import Foundation
import CryptoKit

enum PipelineArchive {
    /// Bump when the archived pipeline set or its descriptors change: every archive is rebuilt.
    static let version = 2
    /// The saver's drawable format (DotSaverView: MTKView.colorPixelFormat).
    static let saverFormat: MTLPixelFormat = .bgra8Unorm

    static func folder(in baseDir: URL) -> URL { baseDir.appendingPathComponent("PipelineCache", isDirectory: true) }
    static func archiveURL(in baseDir: URL) -> URL { folder(in: baseDir).appendingPathComponent("saver.binarchive") }
    static func manifestURL(in baseDir: URL) -> URL { folder(in: baseDir).appendingPathComponent("saver.json") }

    /// What an archive was built for. The saver uses one only when every field matches.
    struct Manifest: Codable, Equatable {
        var version: Int
        /// SHA-256 of the saver's default.metallib.
        var metallib: String
        /// macOS version and build (a macOS update can change the GPU compiler).
        var os: String
        var gpu: String
        var format: UInt
    }

    static func manifest(metallib: URL, device: MTLDevice, format: MTLPixelFormat) -> Manifest? {
        guard let data = try? Data(contentsOf: metallib, options: .mappedIfSafe) else { return nil }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return Manifest(version: version, metallib: hash, os: ProcessInfo.processInfo.operatingSystemVersionString,
                        gpu: device.name, format: format.rawValue)
    }

    /// The metallib in a .saver bundle.
    static func metallib(inSaver saver: URL) -> URL {
        saver.appendingPathComponent("Contents/Resources/default.metallib")
    }

    // MARK: Loading (the saver)

    /// The archive in `baseDir`, if it was built for the metallib at `metallib`, this macOS and
    /// `device`. Read-only: never writes, never repairs (the app does that).
    static func load(baseDir: URL, metallib: URL?, device: MTLDevice, format: MTLPixelFormat,
                     log: ((String) -> Void)? = nil) -> MTLBinaryArchive? {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let metallib,
              let data = try? Data(contentsOf: manifestURL(in: baseDir)),
              let saved = try? JSONDecoder().decode(Manifest.self, from: data) else {
            log?("pipeline archive: none")
            return nil
        }
        guard let want = manifest(metallib: metallib, device: device, format: format), want == saved else {
            log?("pipeline archive: stale (built for another saver build, macOS or GPU) — not used")
            return nil
        }
        let d = MTLBinaryArchiveDescriptor()
        d.url = archiveURL(in: baseDir)
        do {
            let a = try device.makeBinaryArchive(descriptor: d)
            log?(String(format: "pipeline archive: loaded in %.1f ms", (CFAbsoluteTimeGetCurrent() - t0) * 1000))
            return a
        } catch {
            log?("pipeline archive: load failed (\(error.localizedDescription))")
            return nil
        }
    }

    // MARK: Harvesting (the app)

    enum Outcome: Equatable { case upToDate, built(bytes: Int, seconds: Double), failed(String) }

    /// Builds the archive for the saver bundle at `saver` into `baseDir`, unless the one there
    /// is already for this metallib, macOS and GPU. Slow (compiles every pipeline — seconds):
    /// call it off the main thread.
    @discardableResult
    static func refresh(saver: URL, baseDir: URL, device: MTLDevice? = MTLCreateSystemDefaultDevice(),
                        format: MTLPixelFormat = saverFormat, force: Bool = false) -> Outcome {
        guard let device else { return .failed("no GPU") }
        let libURL = metallib(inSaver: saver)
        guard let want = manifest(metallib: libURL, device: device, format: format) else {
            return .failed("no metallib at \(libURL.path)")
        }
        let fm = FileManager.default
        if !force, let data = try? Data(contentsOf: manifestURL(in: baseDir)),
           let saved = try? JSONDecoder().decode(Manifest.self, from: data), saved == want,
           fm.fileExists(atPath: archiveURL(in: baseDir).path) {
            return .upToDate
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        do {
            let library = try device.makeLibrary(URL: libURL)
            let archive = try device.makeBinaryArchive(descriptor: MTLBinaryArchiveDescriptor())
            try harvest(into: archive, library: library, format: format)
            let dir = folder(in: baseDir)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let tmp = dir.appendingPathComponent("saver.binarchive.\(ProcessInfo.processInfo.processIdentifier).tmp")
            try? fm.removeItem(at: tmp)
            try archive.serialize(to: tmp)
            // Manifest out first, archive in, manifest last: a saver starting meanwhile sees no
            // manifest (and compiles) — never a manifest for an archive that isn't there yet.
            try? fm.removeItem(at: manifestURL(in: baseDir))
            if fm.fileExists(atPath: archiveURL(in: baseDir).path) {
                _ = try fm.replaceItemAt(archiveURL(in: baseDir), withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: archiveURL(in: baseDir))
            }
            try JSONEncoder().encode(want).write(to: manifestURL(in: baseDir), options: .atomic)
            let bytes = (try? fm.attributesOfItem(atPath: archiveURL(in: baseDir).path)[.size] as? Int) ?? 0
            return .built(bytes: bytes, seconds: CFAbsoluteTimeGetCurrent() - t0)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Every pipeline a saver may build before it has drawn a while: the über-shader, the scenes'
    /// own (ScenePipelines), the music veil, the error-diffusion kernels and the weather skies —
    /// with the descriptors FXPipelines and WeatherLink build, so each one is a hit.
    static func harvest(into archive: MTLBinaryArchive, library: MTLLibrary, format: MTLPixelFormat) throws {
        let fragments = [FXPipelines.uberFunction] + ScenePipelines.functionNames + FXPipelines.veilFunctions
            + WeatherLink.functionNames
        for name in fragments {
            guard let d = FXPipelines.renderDescriptor(library, fragment: name,
                                                       format: format, archive: nil) else { continue }
            try archive.addRenderPipelineFunctions(descriptor: d)
        }
        for name in FXPipelines.ditherKernels {
            guard let d = FXPipelines.computeDescriptor(library, name: name, archive: nil) else { continue }
            try archive.addComputePipelineFunctions(descriptor: d)
        }
    }
}
