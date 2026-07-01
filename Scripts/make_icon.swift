import AppKit

func drawMagnifyingGlass(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22)
    
    let bgGradient = NSGradient(starting: NSColor(calibratedRed: 0.1, green: 0.5, blue: 0.9, alpha: 1.0),
                                ending: NSColor(calibratedRed: 0.05, green: 0.3, blue: 0.7, alpha: 1.0))
    bgGradient?.draw(in: path, angle: -90)
    
    let scale = size / 512.0
    let center = NSPoint(x: size * 0.45, y: size * 0.55)
    let radius = size * 0.2
    
    let lensPath = NSBezierPath()
    lensPath.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
    lensPath.lineWidth = 24.0 * scale
    NSColor.white.setStroke()
    lensPath.stroke()
    
    let handlePath = NSBezierPath()
    let startPoint = NSPoint(x: center.x + radius * cos(-CGFloat.pi/4), y: center.y + radius * sin(-CGFloat.pi/4))
    let endPoint = NSPoint(x: size * 0.8, y: size * 0.2)
    handlePath.move(to: startPoint)
    handlePath.line(to: endPoint)
    handlePath.lineWidth = 32.0 * scale
    handlePath.lineCapStyle = .round
    NSColor.white.setStroke()
    handlePath.stroke()
    
    let tipPath = NSBezierPath()
    tipPath.move(to: NSPoint(x: size * 0.7, y: size * 0.3))
    tipPath.line(to: endPoint)
    tipPath.lineWidth = 32.0 * scale
    tipPath.lineCapStyle = .round
    NSColor(white: 0.9, alpha: 1.0).setStroke()
    tipPath.stroke()

    image.unlockFocus()
    return image
}

func savePNG(image: NSImage, path: String) {
    guard let tiffData = image.tiffRepresentation,
          let bitmapRep = NSBitmapImageRep(data: tiffData),
          let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
        print("Failed to get PNG representation for \(path)")
        return
    }
    try? pngData.write(to: URL(fileURLWithPath: path))
}

let fm = FileManager.default
let iconsetDir = "OpenFind.iconset"
try? fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true, attributes: nil)

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
    ("icon_512x512@2x.png", 1024)
]

for (name, size) in sizes {
    let img = drawMagnifyingGlass(size: size)
    savePNG(image: img, path: "\(iconsetDir)/\(name)")
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetDir, "-o", "OpenFind.icns"]
try task.run()
task.waitUntilExit()

try? fm.removeItem(atPath: iconsetDir)
print("Icon OpenFind.icns generated successfully.")
