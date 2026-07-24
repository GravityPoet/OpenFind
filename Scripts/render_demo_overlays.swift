import AppKit
import Foundation

private let canvasSize = NSSize(width: 1920, height: 1080)
private let fileManager = FileManager.default

guard CommandLine.arguments.count == 3 else {
    fputs(
        "Usage: swift Scripts/render_demo_overlays.swift <output-directory> <app-icon.png>\n",
        stderr
    )
    exit(64)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let appIcon = NSImage(contentsOf: iconURL) else {
    fputs("Could not load app icon: \(iconURL.path)\n", stderr)
    exit(66)
}

try fileManager.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true,
    attributes: nil
)

private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha
        )
    }
}

private func renderImage(_ drawing: () -> Void) -> NSImage {
    let image = NSImage(size: canvasSize)
    image.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    NSGraphicsContext.current?.compositingOperation = .copy
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: canvasSize).fill()
    NSGraphicsContext.current?.compositingOperation = .sourceOver
    drawing()
    image.unlockFocus()
    return image
}

private func savePNG(_ image: NSImage, named name: String) throws {
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(
            domain: "OpenFindDemo",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not encode \(name)"]
        )
    }
    try pngData.write(to: outputDirectory.appendingPathComponent(name), options: .atomic)
}

private func drawText(
    _ text: String,
    in rect: NSRect,
    font: NSFont,
    color: NSColor,
    alignment: NSTextAlignment = .center
) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineBreakMode = .byTruncatingTail
    (text as NSString).draw(
        in: rect,
        withAttributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
    )
}

private func drawBackground() {
    NSColor(hex: 0x08090B).setFill()
    NSRect(origin: .zero, size: canvasSize).fill()

    let glow = NSGradient(colors: [
        NSColor(hex: 0x0071E3, alpha: 0.24),
        NSColor(hex: 0x0071E3, alpha: 0),
    ])
    glow?.draw(
        fromCenter: NSPoint(x: 960, y: 570),
        radius: 30,
        toCenter: NSPoint(x: 960, y: 570),
        radius: 520,
        options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation]
    )
}

private func drawIcon(size: CGFloat, y: CGFloat) {
    let rect = NSRect(x: (canvasSize.width - size) / 2, y: y, width: size, height: size)
    appIcon.draw(
        in: rect,
        from: NSRect(origin: .zero, size: appIcon.size),
        operation: .sourceOver,
        fraction: 1
    )
}

private func makeTitleCard(outro: Bool) -> NSImage {
    renderImage {
        drawBackground()
        drawIcon(size: outro ? 154 : 184, y: outro ? 660 : 668)

        drawText(
            outro ? "OpenFind v1.1.0" : "OpenFind",
            in: NSRect(x: 240, y: 516, width: 1440, height: 104),
            font: .systemFont(ofSize: outro ? 66 : 78, weight: .semibold),
            color: .white
        )

        drawText(
            outro ? "5 个工具，一处完成" : "5 个 Mac 工具，一处完成",
            in: NSRect(x: 300, y: 443, width: 1320, height: 58),
            font: .systemFont(ofSize: 34, weight: .medium),
            color: NSColor(hex: 0xD5D8DE)
        )

        NSColor(hex: 0x0071E3).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 884, y: 409, width: 152, height: 8),
            xRadius: 4,
            yRadius: 4
        ).fill()

        drawText(
            outro
                ? "macOS Universal · Apple silicon + Intel"
                : "搜索 · 保持唤醒 · 硬盘防休眠 · 键盘清洁 · 统一设置",
            in: NSRect(x: 280, y: 334, width: 1360, height: 48),
            font: .systemFont(ofSize: 25, weight: .regular),
            color: NSColor(hex: 0x9096A1)
        )
    }
}

private func makeCaption(title: String, subtitle: String) -> NSImage {
    renderImage {
        let panelRect = NSRect(x: 126, y: 56, width: 1668, height: 168)
        NSColor(hex: 0x0B0C0F, alpha: 0.88).setFill()
        NSBezierPath(roundedRect: panelRect, xRadius: 28, yRadius: 28).fill()

        NSColor(hex: 0x0071E3).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 162, y: 88, width: 7, height: 104),
            xRadius: 3.5,
            yRadius: 3.5
        ).fill()

        drawText(
            title,
            in: NSRect(x: 204, y: 133, width: 1518, height: 48),
            font: .systemFont(ofSize: 36, weight: .semibold),
            color: .white,
            alignment: .left
        )
        drawText(
            subtitle,
            in: NSRect(x: 204, y: 91, width: 1518, height: 38),
            font: .systemFont(ofSize: 24, weight: .regular),
            color: NSColor(hex: 0xC5C9D0),
            alignment: .left
        )
    }
}

try savePNG(makeTitleCard(outro: false), named: "intro.png")
try savePNG(makeTitleCard(outro: true), named: "outro.png")

let captions: [(String, String, String)] = [
    (
        "caption-welcome.png",
        "五项能力，一眼看懂",
        "首次启动直接看到入口与快捷键"
    ),
    (
        "caption-search-typing.png",
        "输入即搜索",
        "先限定目录，再输入关键词"
    ),
    (
        "caption-search-results.png",
        "只留下相关结果",
        "名称、路径和内容随时切换"
    ),
    (
        "caption-settings.png",
        "一套设置，覆盖全部工具",
        "紧凑、默认、大号，随窗口一起响应"
    ),
    (
        "caption-minimum.png",
        "最小窗口也不拥挤",
        "搜索、筛选与状态信息仍然清晰"
    ),
    (
        "caption-scale.png",
        "统一界面缩放",
        "紧凑 · 默认 · 大号"
    ),
    (
        "caption-overview.png",
        "五项能力 + 快捷键",
        "第一次打开就知道从哪里开始"
    ),
]

for (name, title, subtitle) in captions {
    try savePNG(makeCaption(title: title, subtitle: subtitle), named: name)
}

print("Rendered \(captions.count + 2) demo overlays in \(outputDirectory.path)")
