// Draws the 1280×640 card GitHub shows when the repo is shared (Settings → Social preview).
//   swift scripts/make-social-preview.swift <panel-screenshot.png> docs/media/social-preview.png
// The screenshot should come from the demo home (scripts/demo), never from real files.
import AppKit

let args = CommandLine.arguments.dropFirst().map { $0 }
guard args.count == 2, let panel = NSImage(contentsOfFile: args[0]) else {
    print("usage: make-social-preview.swift <panel.png> <out.png>"); exit(2)
}
let icon = NSImage(contentsOfFile: "App/Trail/Assets.xcassets/AppIcon.appiconset/icon-256.png")
let size = NSSize(width: 1280, height: 640)

let image = NSImage(size: size, flipped: true) { rect in
    // The same soft blue-to-rose wash as the demo stage.
    let colors = [NSColor(red: 0.11, green: 0.16, blue: 0.42, alpha: 1), NSColor(red: 0.30, green: 0.48, blue: 0.80, alpha: 1),
                  NSColor(red: 0.62, green: 0.70, blue: 0.90, alpha: 1), NSColor(red: 0.88, green: 0.72, blue: 0.80, alpha: 1)]
    NSGradient(colors: colors)?.draw(in: rect, angle: -28)

    if let icon { icon.draw(in: NSRect(x: 84, y: 150, width: 96, height: 96)) }
    let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 76, weight: .bold), .foregroundColor: NSColor.white]
    ("Trail" as NSString).draw(at: NSPoint(x: 80, y: 262), withAttributes: title)
    let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 27, weight: .medium),
                                               .foregroundColor: NSColor.white.withAlphaComponent(0.88)]
    for (index, line) in ["Your Mac as a private", "knowledge graph.", "Ask for any file. Sort what piles up."].enumerated() {
        (line as NSString).draw(at: NSPoint(x: 84, y: 364 + CGFloat(index) * 38), withAttributes: body)
    }
    let small: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 17, weight: .regular),
                                                .foregroundColor: NSColor.white.withAlphaComponent(0.7)]
    ("on-device AI · macOS · open source" as NSString).draw(at: NSPoint(x: 86, y: 500), withAttributes: small)

    // The panel, cropped to its card, with a soft shadow.
    let frame = NSRect(x: 610, y: 92, width: 620, height: 456)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 30
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor.black.withAlphaComponent(0.2).setFill()
    NSBezierPath(roundedRect: frame, xRadius: 22, yRadius: 22).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: frame, xRadius: 22, yRadius: 22).addClip()
    let source = panel.size
    // The card sits at roughly 15.5%–84.5% across and 11%–88% down the demo screenshot.
    let crop = NSRect(x: source.width * 0.155, y: source.height * 0.12, width: source.width * 0.69, height: source.height * 0.76)
    panel.draw(in: frame, from: crop, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
    return true
}

guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: URL(fileURLWithPath: args[1]))
print("Wrote \(args[1])")
