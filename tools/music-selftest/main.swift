//  main.swift — entry for tools/music-selftest/run.sh: MusicSelfTest (App/Music) as a CLI.
//  No real player is involved; see App/Music/MusicSelfTest.swift.

import Foundation

let args = CommandLine.arguments
let outDir = args.count > 1 ? args[1] : NSTemporaryDirectory() + "dotstudio-music-selftest"
MainActor.assumeIsolated {
    MusicSelfTest.runAndExit(outDir: outDir)
}
