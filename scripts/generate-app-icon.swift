import AppKit
import Foundation

// Render the same SF Symbol as the idle menu-bar item into a macOS iconset.
// Regenerate with:
//   swift scripts/generate-app-icon.swift .build/AppIcon.iconset
//   iconutil -c icns .build/AppIcon.iconset -o Resources/AppIcon.icns
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".build/AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let symbolName = "waveform.badge.mic"
guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
    .withSymbolConfiguration(.init(pointSize: 640, weight: .regular))?
    .withSymbolConfiguration(.init(paletteColors: [NSColor(calibratedWhite: 0.19, alpha: 1)])) else {
    fatalError("Cannot load \(symbolName)")
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        context.imageInterpolation = .high
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

        let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.17)
        shadow.shadowBlurRadius = 20; shadow.shadowOffset = NSSize(width: 0, height: -10); shadow.set()
        NSColor(calibratedWhite: 0.95, alpha: 1).setFill(); tile.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: NSColor(calibratedWhite: 0.99, alpha: 1), ending: NSColor(calibratedWhite: 0.90, alpha: 1))!.draw(in: tile, angle: -90)
        NSColor(calibratedWhite: 0.75, alpha: 0.35).setStroke(); tile.lineWidth = 2; tile.stroke()

        let factor = 660 / max(symbol.size.width, symbol.size.height)
        let size = NSSize(width: symbol.size.width * factor, height: symbol.size.height * factor)
        symbol.draw(in: NSRect(x: (1024-size.width)/2, y: (1024-size.height)/2, width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
print("Generated \(output.path) from \(symbolName)")
