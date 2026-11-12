import AppKit

guard CommandLine.arguments.count == 3, let pixels = Int(CommandLine.arguments[1]),
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
let scale = CGFloat(pixels) / 1024
let transform = NSAffineTransform()
transform.scale(by: scale)
transform.concat()

NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
let background = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
                              xRadius: 180, yRadius: 180)
NSGradient(starting: NSColor(srgbRed: 0.19, green: 0.195, blue: 0.20, alpha: 1),
           ending: NSColor(srgbRed: 0.087, green: 0.09, blue: 0.097, alpha: 1))?
    .draw(in: background, angle: -90)
NSColor.white.withAlphaComponent(0.12).setStroke()
background.lineWidth = 6
background.stroke()

let rows = [(NSRect(x: 287, y: 639, width: 261, height: 53), 0.89),
            (NSRect(x: 287, y: 485, width: 212, height: 53), 0.59),
            (NSRect(x: 287, y: 331, width: 237, height: 53), 0.37)]
for (rect, opacity) in rows {
    NSColor.white.withAlphaComponent(opacity).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 26.5, yRadius: 26.5).fill()
}
let edge = NSBezierPath(roundedRect: NSRect(x: 650, y: 321, width: 87, height: 382),
                        xRadius: 43.5, yRadius: 43.5)
NSColor(srgbRed: 0.64, green: 0.88, blue: 0.78, alpha: 1).setFill()
edge.fill()

NSGraphicsContext.restoreGraphicsState()
guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))

