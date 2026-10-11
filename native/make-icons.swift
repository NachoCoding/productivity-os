import AppKit

// Renders the extension and per-command icons into the directory given as the first argument:
// a white SF Symbol on a rounded gradient tile, 512×512, as Raycast expects.
// Run with `npm run build:icons` after changing the table below.

let icons: [(file: String, symbol: String, top: UInt32, bottom: UInt32)] = [
    ("command-health-breaks", "heart.circle.fill", 0xF2969A, 0xB45387),
    ("command-drop-shelf", "tray.and.arrow.down.fill", 0x52C7D1, 0x5468D4),
    ("command-clipboard-history", "clipboard.fill", 0x47B7B0, 0x267A8C),
    ("icon", "scope", 0x6D5DF6, 0x3B2FC9),
    ("command-screenshot-studio", "camera.viewfinder", 0x47C9E5, 0x3764D9),
    ("command-dashboard", "square.grid.2x2.fill", 0x6D5DF6, 0x3B2FC9),
    ("command-resource-guard", "shield.lefthalf.filled", 0x4FD1C5, 0x0E8F86),
    ("command-block-site", "lock.fill", 0xFF6B5E, 0xD92D20),
    ("command-unblock-site", "lock.open.fill", 0x4CD080, 0x12924A),
    ("command-blocked-sites", "list.bullet", 0xFFA94D, 0xE8590C),
    ("command-block-preset", "square.stack.3d.up.fill", 0xB37FEB, 0x7A3FD1),
    ("command-start-focus-session", "timer", 0x5AA9FF, 0x1D6FE0),
    ("command-quick-focus", "bolt.fill", 0x5AA9FF, 0x1D6FE0),
    ("command-focus-status", "hourglass", 0x4FD1C5, 0x0E8F86),
    ("command-toggle-color-filters", "circle.lefthalf.filled", 0x6B7280, 0x1F2937),
    ("command-toggle-menu-bar-icons", "menubar.rectangle", 0x64748B, 0x334155),
    ("command-lock-keep-awake", "lock.display", 0xFFC145, 0xF08C00),
    ("command-amphetamine-start", "cup.and.saucer.fill", 0xFFC145, 0xF08C00),
    ("command-amphetamine-quick-start", "hare.fill", 0xFFC145, 0xF08C00),
    ("command-amphetamine-end", "moon.zzz.fill", 0xFFC145, 0xF08C00),
    ("command-amphetamine-remaining", "clock.fill", 0xFFC145, 0xF08C00),
    ("command-amphetamine-configure", "slider.horizontal.3", 0xFFC145, 0xF08C00),
    ("command-run-setup", "wrench.and.screwdriver.fill", 0x9CA3AF, 0x4B5563),
]

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icons: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2 else { fail("usage: make-icons <output directory>") }
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let side: CGFloat = 512

for icon in icons {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fail("could not create a bitmap") }
    let configuration = NSImage.SymbolConfiguration(pointSize: 200, weight: .semibold)
    guard let symbol = NSImage(systemSymbolName: icon.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else {
        fail("unknown SF Symbol \(icon.symbol)")
    }
    // Symbols are templates: fill their shape with white.
    let glyph = NSImage(size: symbol.size, flipped: false) { rect in
        symbol.draw(in: rect)
        NSColor.white.set()
        rect.fill(using: .sourceAtop)
        return true
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let tile = NSRect(x: 0, y: 0, width: side, height: side).insetBy(dx: 16, dy: 16)
    NSGradient(starting: color(icon.top), ending: color(icon.bottom))?.draw(in: NSBezierPath(roundedRect: tile, xRadius: 112, yRadius: 112), angle: -90)
    let scale = min(280 / glyph.size.width, 280 / glyph.size.height)
    let size = NSSize(width: glyph.size.width * scale, height: glyph.size.height * scale)
    glyph.draw(in: NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fail("could not encode \(icon.file)") }
    do { try png.write(to: output.appendingPathComponent("\(icon.file).png")) } catch { fail("could not write \(icon.file): \(error.localizedDescription)") }
}
print("wrote \(icons.count) icons to \(output.path)")
