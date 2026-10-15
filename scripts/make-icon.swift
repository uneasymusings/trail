// Draws the Trail app icon: a glassy squircle with a path linking three nodes.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let context = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824pt body centered on a 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: NSColor.black.withAlphaComponent(0.35).cgColor)
context.addPath(squircle)
context.setFillColor(NSColor.black.cgColor)
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(squircle)
context.clip()
let space = CGColorSpaceCreateDeviceRGB()
let background = CGGradient(colorsSpace: space, colors: [
    NSColor(red: 0.16, green: 0.10, blue: 0.42, alpha: 1).cgColor,
    NSColor(red: 0.10, green: 0.36, blue: 0.78, alpha: 1).cgColor,
    NSColor(red: 0.20, green: 0.80, blue: 0.86, alpha: 1).cgColor,
] as CFArray, locations: [0, 0.55, 1])!
context.drawLinearGradient(background, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])

// Soft light from the top-left, like glass.
let glow = CGGradient(colorsSpace: space, colors: [
    NSColor.white.withAlphaComponent(0.35).cgColor, NSColor.white.withAlphaComponent(0).cgColor,
] as CFArray, locations: [0, 1])!
context.drawRadialGradient(glow, startCenter: CGPoint(x: 300, y: 860), startRadius: 0,
                           endCenter: CGPoint(x: 300, y: 860), endRadius: 620, options: [])

// The trail.
let a = CGPoint(x: 300, y: 330), b = CGPoint(x: 560, y: 560), c = CGPoint(x: 730, y: 730)
let path = CGMutablePath()
path.move(to: a)
path.addCurve(to: b, control1: CGPoint(x: 330, y: 520), control2: CGPoint(x: 420, y: 470))
path.addCurve(to: c, control1: CGPoint(x: 700, y: 650), control2: CGPoint(x: 600, y: 760))
context.setLineCap(.round)
context.addPath(path)
context.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor)
context.setLineWidth(70)
context.strokePath()
context.addPath(path)
context.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
context.setLineWidth(30)
context.setLineDash(phase: 0, lengths: [2, 58])
context.strokePath()
context.setLineDash(phase: 0, lengths: [])

for (point, radius) in [(a, 54.0), (b, 44.0), (c, 74.0)] {
    let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
    context.setShadow(offset: .zero, blur: 40, color: NSColor.white.withAlphaComponent(0.8).cgColor)
    context.setFillColor(NSColor.white.cgColor)
    context.fillEllipse(in: rect)
}
context.restoreGState()

// Thin bright rim.
context.addPath(squircle)
context.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor)
context.setLineWidth(3)
context.strokePath()

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
