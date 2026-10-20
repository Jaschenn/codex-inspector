import AppKit

// Vector source, rendered at every native icon size during packaging. No external
// image dependency; the magnifier frames a terminal prompt and activity bars.
func icon(size: Int) throws -> Data {
  guard
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
    let context = NSGraphicsContext(bitmapImageRep: bitmap)
  else { throw NSError(domain: "Icon", code: 1) }
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = context
  context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

  let tile = NSBezierPath(
    roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 194, yRadius: 194)
  let shadow = NSShadow()
  shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
  shadow.shadowBlurRadius = 28
  shadow.shadowOffset = NSSize(width: 0, height: -12)
  NSGraphicsContext.saveGraphicsState()
  shadow.set()
  NSColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1).setFill()
  tile.fill()
  NSGraphicsContext.restoreGraphicsState()
  NSColor(red: 0.16, green: 0.16, blue: 0.17, alpha: 1).setFill()
  tile.fill()
  NSColor.white.withAlphaComponent(0.1).setStroke()
  tile.lineWidth = 3
  tile.stroke()

  let lens = NSBezierPath(ovalIn: NSRect(x: 225, y: 328, width: 450, height: 450))
  NSColor(red: 0.91, green: 0.9, blue: 0.86, alpha: 1).setStroke()
  lens.lineWidth = 42
  lens.stroke()
  let handle = NSBezierPath()
  handle.move(to: NSPoint(x: 622, y: 376))
  handle.line(to: NSPoint(x: 785, y: 213))
  handle.lineWidth = 66
  handle.lineCapStyle = .round
  NSColor(red: 0.91, green: 0.9, blue: 0.86, alpha: 1).setStroke()
  handle.stroke()

  let prompt = NSBezierPath()
  prompt.move(to: NSPoint(x: 329, y: 648))
  prompt.line(to: NSPoint(x: 385, y: 597))
  prompt.line(to: NSPoint(x: 329, y: 546))
  prompt.lineWidth = 25
  prompt.lineCapStyle = .round
  prompt.lineJoinStyle = .round
  NSColor(red: 0.91, green: 0.9, blue: 0.86, alpha: 1).setStroke()
  prompt.stroke()
  let cursor = NSBezierPath()
  cursor.move(to: NSPoint(x: 443, y: 551))
  cursor.line(to: NSPoint(x: 545, y: 551))
  cursor.lineWidth = 23
  cursor.lineCapStyle = .round
  cursor.stroke()
  for (index, height) in [40.0, 68.0, 97.0, 58.0].enumerated() {
    let bar = NSBezierPath(
      roundedRect: NSRect(x: 326 + Double(index) * 60, y: 433, width: 35, height: height),
      xRadius: 9, yRadius: 9)
    NSColor(
      red: 0.61 + Double(index) * 0.07, green: 0.6 + Double(index) * 0.07,
      blue: 0.58 + Double(index) * 0.07, alpha: 1
    ).setFill()
    bar.fill()
  }
  NSGraphicsContext.restoreGraphicsState()
  guard let data = bitmap.representation(using: .png, properties: [:]) else {
    throw NSError(domain: "Icon", code: 2)
  }
  return data
}

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
  try icon(size: size).write(to: destination.appendingPathComponent("icon_\(size)x\(size).png"))
  try icon(size: size * 2).write(
    to: destination.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
