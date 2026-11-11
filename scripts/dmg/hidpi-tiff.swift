// hidpi-tiff.swift <1x.png> <2x.png> <out.tiff> [quality 0-1]
// Writes the DMG window background as one two-representation TIFF (72 + 144 dpi, both the same
// point size) the way `tiffutil -cathidpicheck` does, but JPEG-compressed: the scene render and
// film grain don't LZW well (~1.8 MB), JPEG keeps it to a few hundred KB.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write("usage: hidpi-tiff <1x.png> <2x.png> <out.tiff> [quality]\n".data(using: .utf8)!)
    exit(2)
}
let quality = args.count > 4 ? Double(args[4]) ?? 0.86 : 0.86

func load(_ path: String) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!); exit(1)
    }
    return img
}
let one = load(args[1]), two = load(args[2])
guard two.width == one.width * 2, two.height == one.height * 2 else {
    FileHandle.standardError.write("2x must be exactly twice the 1x size (\(one.width)x\(one.height) vs \(two.width)x\(two.height))\n".data(using: .utf8)!)
    exit(1)
}
let out = URL(fileURLWithPath: args[3])
guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.tiff.identifier as CFString, 2, nil) else { exit(1) }
for (img, dpi) in [(one, 72.0), (two, 144.0)] {
    let props: [CFString: Any] = [
        kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
        kCGImageDestinationLossyCompressionQuality: quality,
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 7],   // 7 = JPEG
    ]
    CGImageDestinationAddImage(dest, img, props as CFDictionary)
}
guard CGImageDestinationFinalize(dest) else { FileHandle.standardError.write("write failed\n".data(using: .utf8)!); exit(1) }

// Check it reads back as Finder will: one NSImage, two representations, same point size.
let check = NSImage(contentsOf: out)!
let reps = check.representations.map { "\($0.pixelsWide)x\($0.pixelsHigh)px@\(Int($0.size.width))x\(Int($0.size.height))pt" }
print("wrote \(out.path): \(reps.joined(separator: ", "))")
guard reps.count == 2, Set(check.representations.map { $0.size }).count == 1 else {
    FileHandle.standardError.write("unexpected representations\n".data(using: .utf8)!); exit(1)
}
