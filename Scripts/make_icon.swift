import AppKit

let fm = FileManager.default
let sourcePath = "Scripts/Assets/OpenFindIcon.png"
let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "OpenFind.icns"
let iconsetDir = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2]
    : (outputPath as NSString).deletingPathExtension + ".iconset"

guard fm.fileExists(atPath: sourcePath) else {
    fputs("Missing icon source: \(sourcePath)\n", stderr)
    exit(1)
}

guard let sourceImage = NSImage(contentsOfFile: sourcePath) else {
    fputs("Could not load icon source: \(sourcePath)\n", stderr)
    exit(1)
}

func renderIcon(size: CGFloat) -> NSImage {
    let output = NSImage(size: NSSize(width: size, height: size))
    output.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    sourceImage.draw(
        in: NSRect(x: 0, y: 0, width: size, height: size),
        from: NSRect(origin: .zero, size: sourceImage.size),
        operation: .copy,
        fraction: 1.0
    )
    output.unlockFocus()
    return output
}

func savePNG(image: NSImage, path: String) throws {
    guard let tiffData = image.tiffRepresentation,
          let bitmapRep = NSBitmapImageRep(data: tiffData),
          let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "OpenFindIcon", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Failed to encode PNG: \(path)"
        ])
    }
    try pngData.write(to: URL(fileURLWithPath: path))
}

try? fm.removeItem(atPath: iconsetDir)
try? fm.removeItem(atPath: outputPath)
try fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true, attributes: nil)

let sizes: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, size) in sizes {
    try savePNG(image: renderIcon(size: size), path: "\(iconsetDir)/\(name)")
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetDir, "-o", outputPath]
try task.run()
task.waitUntilExit()

try? fm.removeItem(atPath: iconsetDir)

if task.terminationStatus != 0 {
    fputs("iconutil failed with status \(task.terminationStatus)\n", stderr)
    exit(Int32(task.terminationStatus))
}

print("Icon \(outputPath) generated successfully.")
