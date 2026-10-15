import AppKit

// Pixel verification for the production-API fixture, without opening a window.
// Arguments are repeated groups of PNG path, expected red, green, blue.
let args = Array(CommandLine.arguments.dropFirst())
precondition(!args.isEmpty && args.count % 4 == 0)
var results: [[String: Any]] = []
for offset in stride(from: 0, to: args.count, by: 4) {
    let path = args[offset]
    let expected = args[(offset + 1)...(offset + 3)].map { Int($0)! }
    let bitmap = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path)))!
    precondition(bitmap.pixelsWide > 64 && bitmap.pixelsHigh > 64)
    precondition(bitmap.bitsPerSample == 8 && bitmap.samplesPerPixel == 4 && !bitmap.isPlanar
                 && !bitmap.bitmapFormat.contains(.alphaFirst))
    var samples: [[Int]] = []
    for (x, y) in [(16,16), (bitmap.pixelsWide-16,16), (16,bitmap.pixelsHigh-16), (bitmap.pixelsWide-16,bitmap.pixelsHigh-16)] {
        // Use encoded RGB samples: colorAt can return calibrated NSColor values
        // even for an sRGB PNG, making a second conversion inappropriate here.
        let pixel = bitmap.bitmapData! + y*bitmap.bytesPerRow + x*4
        let rgb = [Int(pixel[0]), Int(pixel[1]), Int(pixel[2])]
        precondition(zip(rgb,expected).allSatisfy { abs($0-$1) <= 3 }, "Stale/wrong screenshot: \(path), \(rgb) != \(expected)")
        samples.append(rgb)
    }
    results.append(["path": path, "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh, "rgbSamples": samples])
}
print(String(data: try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted,.sortedKeys]), encoding: .utf8)!)
