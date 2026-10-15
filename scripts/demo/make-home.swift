// Builds a made-up home folder for demos and screenshots, so recordings never show anyone's real files.
//   swift scripts/demo/make-home.swift <output-folder>
// Files get realistic contents, ages, download tags, a git project and a burst of renders.
import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".demo/home")
let now = Date()
let minute = 60.0, hour = 3_600.0, day = 86_400.0
let fm = FileManager.default

try? fm.removeItem(at: root)
try fm.createDirectory(at: root, withIntermediateDirectories: true)

// MARK: - Writers

func url(_ path: String) -> URL {
    let url = root.appendingPathComponent(path)
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    return url
}

func age(_ path: String, _ seconds: Double) {
    try? fm.setAttributes([.modificationDate: now.addingTimeInterval(-seconds)], ofItemAtPath: url(path).path)
}

func text(_ path: String, _ body: String, ago: Double) {
    try? body.write(to: url(path), atomically: true, encoding: .utf8)
    age(path, ago)
}

func bytes(_ path: String, ago: Double, size: Int = 2_048) {
    try? Data((0..<size).map { _ in UInt8.random(in: 0...255) }).write(to: url(path))
    age(path, ago)
}

func styled(_ title: String, _ body: String) -> NSAttributedString {
    let result = NSMutableAttributedString(string: title + "\n\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 20)])
    result.append(NSAttributedString(string: body, attributes: [.font: NSFont.systemFont(ofSize: 12)]))
    return result
}

func docx(_ path: String, _ title: String, _ body: String, ago: Double) {
    let string = styled(title, body)
    if let data = try? string.data(from: NSRange(location: 0, length: string.length),
                                   documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]) {
        try? data.write(to: url(path))
    }
    age(path, ago)
}

/// `figures` adds pages of scanned-looking figures, for a download that's genuinely big (about 0.7 MB each).
func pdf(_ path: String, _ title: String, _ body: String, ago: Double, figures: Int = 0) {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(url(path) as CFURL, mediaBox: &box, nil) else { return }
    context.beginPDFPage(nil)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    styled(title, body).draw(in: CGRect(x: 60, y: 60, width: 492, height: 672))
    NSGraphicsContext.restoreGraphicsState()
    context.endPDFPage()
    var generator = SystemRandomNumberGenerator()
    for _ in 0..<figures {
        let (width, height) = (600, 400)
        let pixels = (0..<width * height * 4).map { _ in UInt8.random(in: 150...255, using: &generator) }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { continue }
        context.beginPDFPage(nil)
        context.draw(image, in: CGRect(x: 6, y: 196, width: 600, height: 400))
        context.endPDFPage()
    }
    context.closePDF()
    age(path, ago)
}

func png(_ path: String, hue: CGFloat, ago: Double, size: Int = 320) {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        NSGradient(colors: [NSColor(hue: hue, saturation: 0.5, brightness: 0.95, alpha: 1),
                            NSColor(hue: hue + 0.12, saturation: 0.6, brightness: 0.55, alpha: 1)])?.draw(in: rect, angle: -60)
        return true
    }
    if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
       let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: url(path))
    }
    age(path, ago)
}

/// A screenshot of some text, like a confirmation page, so on-device OCR has something to read.
func screenshot(_ path: String, _ lines: [String], ago: Double) {
    let size = NSSize(width: 1200, height: 760)
    let image = NSImage(size: size, flipped: true) { rect in
        NSColor(white: 0.97, alpha: 1).setFill(); rect.fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: 120, dy: 110), xRadius: 18, yRadius: 18).fill()
        var y: CGFloat = 170
        for (index, line) in lines.enumerated() {
            let font = index == 0 ? NSFont.boldSystemFont(ofSize: 40) : NSFont.systemFont(ofSize: 28)
            (line as NSString).draw(at: NSPoint(x: 180, y: y), withAttributes: [.font: font, .foregroundColor: NSColor(white: 0.12, alpha: 1)])
            y += index == 0 ? 80 : 50
        }
        return true
    }
    if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
       let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: url(path))
    }
    age(path, ago)
}

/// Marks a file as downloaded the way browsers do: source URL plus a quarantine tag.
func downloaded(_ path: String, from source: String, app: String = "Safari") {
    let target = url(path).path
    if let plist = try? PropertyListSerialization.data(fromPropertyList: [source], format: .binary, options: 0) {
        _ = plist.withUnsafeBytes { setxattr(target, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, plist.count, 0, 0) }
    }
    let quarantine = "0083;\(String(Int(now.timeIntervalSince1970), radix: 16));\(app);\(UUID().uuidString)"
    _ = quarantine.withCString { setxattr(target, "com.apple.quarantine", $0, strlen($0), 0, 0) }
}

// MARK: - Thermal (a startup pitch, with versions)

bytes("Documents/Thermal/Pitch v1.key", ago: 6 * day, size: 40_000)
bytes("Documents/Thermal/Pitch v2.key", ago: 1 * day + 3 * hour, size: 52_000)
bytes("Documents/Thermal/Pitch v3.key", ago: 14 * minute, size: 61_000)
docx("Documents/Thermal/Investor memo.docx", "Thermal: investor memo",
     "Thermal makes low-cost heat-mapping sensors for commercial buildings. Pilots with three property managers cut heating costs by 18 percent. We are raising a seed round to ship 2,000 units and hire two firmware engineers.",
     ago: 2 * hour)
bytes("Documents/Thermal/Market sizing.xlsx", ago: 3 * hour, size: 9_000)
bytes("Documents/Thermal/Brand board.fig", ago: 2 * day, size: 30_000)
text("Documents/Thermal/Notes from Acme call.md", """
    # Acme call

    - They want a pilot in two office towers before Q1
    - Pricing: per-sensor lease, not purchase
    - Follow up with the updated pitch deck and the datasheet
    """, ago: 40 * minute)

// MARK: - Taxes

pdf("Documents/Taxes 2026/W-2.pdf", "Form W-2: wage and tax statement",
    "Employer: Northwind Studio. Wages, tips, other compensation: 84,200.00. Federal income tax withheld: 11,940.00.", ago: 12 * day)
pdf("Documents/Taxes 2026/1099-INT.pdf", "Form 1099-INT: interest income",
    "Payer: Harbor Savings Bank. Interest income: 412.18.", ago: 9 * day)
bytes("Documents/Taxes 2026/Receipts 2026.xlsx", ago: 8 * day, size: 12_000)
text("Documents/Taxes 2026/Deductions checklist.md", """
    # Deductions checklist

    - Home office: measure the studio
    - Equipment: new monitor, audio interface
    - Charitable: food bank receipts
    """, ago: 8 * day)

// MARK: - Lisbon trip

pdf("Documents/Lisbon trip/Itinerary.pdf", "Lisbon itinerary",
    "Day 1: Alfama walk, Miradouro de Santa Luzia at sunset. Day 2: Belem, pasteis de nata. Day 3: Sintra day trip.", ago: 3 * day)
pdf("Documents/Lisbon trip/Flights.pdf", "Flight confirmation",
    "SFO to LIS, departing November 12. Seat 14A. Return November 20.", ago: 4 * day)
text("Documents/Lisbon trip/Packing list.md", "# Packing\n\n- Walking shoes\n- Rain jacket\n- Adapter (type F)\n", ago: 2 * day)

// MARK: - Downloads

pdf("Downloads/irs-publication-17.pdf", "Publication 17: your federal income tax",
    "A guide for individuals on filing a federal income tax return, including deductions and credits.", ago: 2 * day, figures: 6)
downloaded("Downloads/irs-publication-17.pdf", from: "https://www.irs.gov/pub/irs-pdf/p17.pdf")
pdf("Downloads/Q3-bank-statement.pdf", "Harbor Savings Bank: Q3 statement",
    "Statement period July 1 to September 30. Ending balance 12,804.33.", ago: 9 * day)
downloaded("Downloads/Q3-bank-statement.pdf", from: "https://harborsavings.example.com/statements/q3.pdf", app: "Google Chrome")
png("Downloads/lisbon-tram-map.png", hue: 0.08, ago: 3 * day)
downloaded("Downloads/lisbon-tram-map.png", from: "https://www.visitlisboa.com/maps/tram-28.png")
pdf("Downloads/thermal-sensor-datasheet.pdf", "TS-200 thermal sensor datasheet",
    "Range -20 to 120 C, accuracy 0.2 C, battery life 3 years, LoRaWAN radio.", ago: 1 * day)
downloaded("Downloads/thermal-sensor-datasheet.pdf", from: "https://sensors.example.com/ts-200.pdf", app: "Arc")

pdf("Downloads/Acme pilot agreement.pdf", "Pilot agreement: Acme Properties and Thermal",
    "Acme Properties will install 40 Thermal sensors in two office towers for a 90-day pilot. Pricing per sensor per month.", ago: 3 * hour)
downloaded("Downloads/Acme pilot agreement.pdf", from: "https://app.docusign.com/documents/acme-pilot.pdf")
pdf("Downloads/1098-T.pdf", "Form 1098-T: tuition statement",
    "Filer: Bay Area State University. Payments received for qualified tuition and related expenses: 6,410.00. Tax year 2026.", ago: 26 * hour)
downloaded("Downloads/1098-T.pdf", from: "https://portal.bayareastate.example.edu/tax/1098t.pdf")

// MARK: - Desktop

screenshot("Desktop/Screenshot 2026-10-14 at 09.41.22.png",
           ["Tickets confirmed", "Pena Palace, Sintra", "Saturday, November 15 · 10:30", "2 adults · Order PN-58213"], ago: 5 * hour)
text("Desktop/todo.md", "# Today\n\n- [ ] Send Acme the new deck\n- [ ] Book Sintra tickets\n- [x] File the 1099\n", ago: 30 * minute)

// MARK: - A code project (git root)

try fm.createDirectory(at: url("Developer/portfolio/.git"), withIntermediateDirectories: true)
text("Developer/portfolio/.git/HEAD", "ref: refs/heads/main\n", ago: day)
text("Developer/portfolio/package.json", "{ \"name\": \"portfolio\", \"private\": true }\n", ago: 5 * day)
text("Developer/portfolio/README.md", "# Portfolio\n\nMy design and engineering portfolio.\n", ago: day)
text("Developer/portfolio/src/app/page.tsx", "export default function Home() {\n  return <main>Selected work</main>\n}\n", ago: 25 * minute)
text("Developer/portfolio/src/data/projects.ts", "export const projects = [\n  { name: \"Thermal\", year: 2026 },\n]\n", ago: 18 * minute)
png("Developer/portfolio/public/hero.png", hue: 0.7, ago: 2 * day)

// MARK: - Saved by an AI assistant

text("Documents/Claude/lisbon-food-guide.md", "# Lisbon food guide\n\nTasca do Chico for fado, Time Out Market for lunch, Manteigaria for pasteis de nata.\n", ago: 3 * day)
text("Documents/Claude/thermal-pitch-feedback.md", "# Pitch feedback\n\nLead with the 18 percent savings. Move the team slide earlier. Cut the TAM slide to one number.\n", ago: 50 * minute)

// MARK: - Music and a burst of renders

bytes("Music/Demos/Sunset idea 3.wav", ago: 6 * day, size: 20_000)
for frame in 1...48 {
    png(String(format: "Pictures/Renders/thermal-hero/frame_%04d.png", frame), hue: 0.02 + Double(frame) / 400, ago: 2 * day + Double(frame), size: 64)
}

print("Demo home ready at \(root.path)")
