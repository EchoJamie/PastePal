import AppKit
import Foundation

guard CommandLine.arguments.count == 4 else {
    fputs("用法：xcrun swift scripts/render-icon-preview.swift <应用图标> <状态栏图标> <输出.png>\n", stderr)
    exit(2)
}

let appIconPath = CommandLine.arguments[1]
let statusIconPath = CommandLine.arguments[2]
let outputPath = CommandLine.arguments[3]

guard let appIcon = NSImage(contentsOfFile: appIconPath),
      let statusIcon = NSImage(contentsOfFile: statusIconPath) else {
    fatalError("无法载入图标资源")
}

statusIcon.size = NSSize(width: 18, height: 18)
statusIcon.isTemplate = true

func tintedStatusIcon(_ color: NSColor) -> NSImage {
    let image = NSImage(size: statusIcon.size)
    image.lockFocus()
    statusIcon.draw(in: NSRect(origin: .zero, size: statusIcon.size))
    color.setFill()
    NSRect(origin: .zero, size: statusIcon.size).fill(using: .sourceIn)
    image.unlockFocus()
    return image
}

let canvasSize = NSSize(width: 760, height: 360)
let canvas = NSImage(size: canvasSize)
canvas.lockFocus()

NSColor(calibratedWhite: 0.95, alpha: 1).setFill()
NSRect(origin: .zero, size: canvasSize).fill()

let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let titleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
    .foregroundColor: NSColor(calibratedWhite: 0.2, alpha: 1),
    .paragraphStyle: paragraph,
]
let labelAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
    .foregroundColor: NSColor(calibratedWhite: 0.3, alpha: 1),
    .paragraphStyle: paragraph,
]

NSAttributedString(string: "PastePal 图标资源预览", attributes: titleAttributes)
    .draw(in: NSRect(x: 20, y: 326, width: 720, height: 22))

let iconSizes: [CGFloat] = [160, 80, 40]
let iconOrigins: [NSPoint] = [
    NSPoint(x: 50, y: 116),
    NSPoint(x: 255, y: 156),
    NSPoint(x: 380, y: 176),
]
for (size, origin) in zip(iconSizes, iconOrigins) {
    appIcon.draw(
        in: NSRect(x: origin.x, y: origin.y, width: size, height: size),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )
    NSAttributedString(string: "\(Int(size)) px", attributes: labelAttributes)
        .draw(in: NSRect(x: origin.x - 10, y: 88, width: size + 20, height: 18))
}

struct MenuBarSample {
    let title: String
    let background: NSColor
    let foreground: NSColor
}

let samples = [
    MenuBarSample(title: "浅色", background: NSColor(calibratedWhite: 0.91, alpha: 1), foreground: NSColor(calibratedWhite: 0.12, alpha: 1)),
    MenuBarSample(title: "深色", background: NSColor(calibratedWhite: 0.13, alpha: 1), foreground: NSColor(calibratedWhite: 0.9, alpha: 1)),
    MenuBarSample(title: "选中", background: NSColor(calibratedRed: 0.24, green: 0.47, blue: 0.88, alpha: 1), foreground: .white),
]

let sampleX: CGFloat = 470
for (index, sample) in samples.enumerated() {
    let y = CGFloat(235 - index * 70)
    let backgroundRect = NSRect(x: sampleX, y: y, width: 230, height: 42)
    sample.background.setFill()
    NSBezierPath(roundedRect: backgroundRect, xRadius: 9, yRadius: 9).fill()
    let icon = tintedStatusIcon(sample.foreground)
    icon.draw(in: NSRect(x: sampleX + 18, y: y + 12, width: 18, height: 18))
    NSAttributedString(
        string: "\(sample.title)菜单栏 · 18 pt",
        attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: sample.foreground,
        ]
    ).draw(at: NSPoint(x: sampleX + 54, y: y + 13))
}

canvas.unlockFocus()

guard let tiff = canvas.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("无法生成预览图")
}
try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
