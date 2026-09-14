import AppKit

// Generates the disk-image window background from the hero photograph.
//
// Two constraints drive the design. Finder draws item labels in dark text, so
// the area where the icons sit has to stay bright — which is why the cloud is
// positioned low and lifted further with a scrim. And the window is only ~500pt
// tall, so the composition is cropped to the part of the photo that reads at
// that size rather than scaled down whole.

let W: CGFloat = 1000, H: CGFloat = 500
let iconBaseline: CGFloat = 290   // distance from the top, matching the AppleScript

guard CommandLine.arguments.count >= 3 else {
    FileHandle.standardError.write("usage: dmg-background <photo> <out.png> [scale]\n".data(using: .utf8)!)
    exit(2)
}
let scale = CommandLine.arguments.count > 3 ? CGFloat(Double(CommandLine.arguments[3]) ?? 1) : 1
let pxW = Int(W * scale), pxH = Int(H * scale)

guard let photo = NSImage(contentsOfFile: CommandLine.arguments[1]) else {
    FileHandle.standardError.write("cannot read photo\n".data(using: .utf8)!)
    exit(1)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
ctx.scaleBy(x: scale, y: scale)

// Aspect-fill the photo, biased so the dark sky lands at the top where the
// title goes and the bright cloud fills the lower half under the icons.
let size = photo.size
let ratio = max(W / size.width, H / size.height)
let drawn = NSSize(width: size.width * ratio, height: size.height * ratio)
photo.draw(in: NSRect(x: (W - drawn.width) / 2, y: (H - drawn.height) * 0.62,
                      width: drawn.width, height: drawn.height),
           from: .zero, operation: .copy, fraction: 1)

// Deepen the sky behind the title.
let sky = NSGradient(colors: [NSColor(srgbRed: 0.031, green: 0.153, blue: 0.275, alpha: 0.88),
                              NSColor(srgbRed: 0.031, green: 0.153, blue: 0.275, alpha: 0.0)])!
sky.draw(in: NSRect(x: 0, y: H - 230, width: W, height: 230), angle: -90)

// Lift the band the icons sit on. Finder's labels are dark, so this is what
// keeps them legible over the photograph.
let lift = NSGradient(colors: [NSColor(srgbRed: 1, green: 0.996, blue: 0.965, alpha: 0.0),
                               NSColor(srgbRed: 1, green: 0.996, blue: 0.965, alpha: 0.55)])!
lift.draw(in: NSRect(x: 0, y: 0, width: W, height: 320), angle: -90)

func draw(_ text: String, _ font: NSFont, _ color: NSColor, centreY: CGFloat) {
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    shadow.shadowBlurRadius = 12
    shadow.shadowOffset = NSSize(width: 0, height: -1)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .shadow: shadow]
    let s = NSAttributedString(string: text, attributes: attrs)
    let b = s.size()
    s.draw(at: NSPoint(x: (W - b.width) / 2, y: H - centreY - b.height / 2))
}

let ivory = NSColor(srgbRed: 0.984, green: 0.980, blue: 0.965, alpha: 1)
draw("LidPlane", .systemFont(ofSize: 42, weight: .semibold), ivory, centreY: 72)
draw("Drag the app into your Applications folder",
     .systemFont(ofSize: 17, weight: .regular), ivory.withAlphaComponent(0.88), centreY: 118)

// Arrow between the two icon slots, sitting on the icon centre line.
let navy = NSColor(srgbRed: 0.055, green: 0.169, blue: 0.294, alpha: 0.55)
navy.setStroke()
let y = H - iconBaseline
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 432, y: y))
arrow.line(to: NSPoint(x: 568, y: y))
arrow.lineWidth = 3
arrow.lineCapStyle = .round
arrow.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 552, y: y + 13))
head.line(to: NSPoint(x: 570, y: y))
head.line(to: NSPoint(x: 552, y: y - 13))
head.lineWidth = 3
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.stroke()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
