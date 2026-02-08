import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift render_app_icon.swift <output-png-path>\n", stderr)
    exit(1)
}

let outputPath = CommandLine.arguments[1]
let size: CGFloat = 1024
let canvasRect = NSRect(x: 0, y: 0, width: size, height: size)
let outerInset: CGFloat = 56
let cardRect = canvasRect.insetBy(dx: outerInset, dy: outerInset)

let image = NSImage(size: canvasRect.size)
image.lockFocus()

let baseGradient = NSGradient(colors: [
    NSColor(red: 0.08, green: 0.22, blue: 0.58, alpha: 1.0),
    NSColor(red: 0.12, green: 0.55, blue: 0.86, alpha: 1.0),
])!

let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: 220, yRadius: 220)
baseGradient.draw(in: cardPath, angle: 90)

let insetRect = cardRect.insetBy(dx: 34, dy: 34)
let insetPath = NSBezierPath(roundedRect: insetRect, xRadius: 170, yRadius: 170)
NSColor(white: 1.0, alpha: 0.12).setStroke()
insetPath.lineWidth = 8
insetPath.stroke()

let glowPath = NSBezierPath(ovalIn: NSRect(x: 190, y: 620, width: 640, height: 260))
NSColor(white: 1.0, alpha: 0.18).setFill()
glowPath.fill()

let glyph = "⇪" as NSString
let glyphAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 500, weight: .black),
    .foregroundColor: NSColor.white,
]
let glyphSize = glyph.size(withAttributes: glyphAttributes)
let glyphOrigin = NSPoint(
    x: (size - glyphSize.width) / 2,
    y: (size - glyphSize.height) / 2 - 22
)
glyph.draw(at: glyphOrigin, withAttributes: glyphAttributes)

image.unlockFocus()

guard
    let tiffData = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiffData),
    let pngData = bitmap.representation(using: .png, properties: [:])
else {
    fputs("Failed to render icon image.\n", stderr)
    exit(1)
}

do {
    try pngData.write(to: URL(fileURLWithPath: outputPath))
} catch {
    fputs("Failed to write PNG: \(error.localizedDescription)\n", stderr)
    exit(1)
}
