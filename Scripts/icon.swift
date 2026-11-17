import AppKit

// Draws the app icon: two half-lidded eyes glancing sideways on a cream tile.
//   icon <pixels> <output.png>

guard CommandLine.arguments.count == 3, let pixels = Int(CommandLine.arguments[1]),
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(1) }

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
let white = color(0xFFFFFF), ink = color(0x14141A)

func circle(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat, _ fill: NSColor) {
    fill.setFill()
    NSBezierPath(ovalIn: NSRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius)).fill()
}

func clipped(_ path: NSBezierPath, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

/// The lid cuts the top of an eye on a slant, lower toward the side it looks at. `grow` widens the
/// shape for the dark rim drawn behind the white.
func lid(_ x: CGFloat, grow: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: x - grow, y: 372 - grow))
    path.line(to: NSPoint(x: x + 270 + grow, y: 372 - grow))
    path.line(to: NSPoint(x: x + 270 + grow, y: 598 + grow))
    path.line(to: NSPoint(x: x - grow, y: 646 + grow))
    path.close()
    return path
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
// Everything is drawn on the standard 1024 grid, where the tile is 824 points wide.
let transform = NSAffineTransform()
transform.scale(by: CGFloat(pixels) / 1024)
transform.concat()

NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGradient(starting: color(0xFBF9F4), ending: color(0xE8E4D9))?.draw(in: tile, angle: -90)
// A faint edge keeps a pale tile visible on a white window.
color(0x000000, 0.10).setStroke()
tile.lineWidth = 6
tile.stroke()

for x in [222.0, 532.0] as [CGFloat] {
    let rim = NSBezierPath(roundedRect: NSRect(x: x - 16, y: 356, width: 302, height: 392), xRadius: 151, yRadius: 151)
    clipped(lid(x, grow: 16)) {
        ink.setFill()
        rim.fill()
    }
    let eye = NSBezierPath(roundedRect: NSRect(x: x, y: 372, width: 270, height: 360), xRadius: 135, yRadius: 135)
    clipped(lid(x, grow: 0)) {
        white.setFill()
        eye.fill()
        circle(x + 170, 536, 90, ink)       // the pupil, pushed to the right
        circle(x + 204, 556, 22, white)     // its highlight
    }
}

NSGraphicsContext.restoreGraphicsState()
guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
