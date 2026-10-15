import AppKit
import Foundation
import PDFKit
import Vision

/// Pulls text out of files: a short excerpt for the model to summarize, and a longer, cheaper
/// one for the search index. Never reads more than it needs.
enum TextExtractor {
    static let maxCharacters = 2_400
    static let maxBodyCharacters = 6_000

    /// Kinds whose text goes into the search index. Images need OCR, which is slow, so they're
    /// left to the model's notes; code is left to the editor.
    static let readableKinds: [FileKind] = [.document, .pdf, .text, .presentation, .spreadsheet]

    static func excerpt(path: String, kind: FileKind, accurate: Bool = false) -> String? {
        text(path: path, kind: kind, limit: maxCharacters, recognizeImages: true, accurate: accurate)
    }

    /// The beginning of a document, for full-text search.
    static func body(path: String, kind: FileKind) -> String? {
        guard readableKinds.contains(kind) else { return nil }
        return text(path: path, kind: kind, limit: maxBodyCharacters, recognizeImages: false)
    }

    private static func text(path: String, kind: FileKind, limit: Int, recognizeImages: Bool, accurate: Bool = false) -> String? {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let text: String? = switch kind {
        case .pdf: pdfText(url, limit: limit)
        case .text, .code, .data: plainText(url)
        case .document: documentText(url, ext: ext)
        case .presentation where ext == "pptx": zippedText(url, entries: "ppt/slides/slide*.xml", tag: "a:t")
        case .spreadsheet where ext == "xlsx": zippedText(url, entries: "xl/sharedStrings.xml", tag: "t")
        case .spreadsheet where ext == "csv": plainText(url)
        case .image where recognizeImages: imageText(url, accurate: accurate)
        default: nil
        }
        guard let text else { return nil }
        let squeezed = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return squeezed.count < 12 ? nil : String(squeezed.prefix(limit))
    }

    private static func plainText(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16_384) else { return nil }
        // Skip binary files that happen to have a text extension.
        if data.prefix(1024).contains(0) { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func pdfText(_ url: URL, limit: Int) -> String? {
        guard let document = PDFDocument(url: url) else { return nil }
        var text = ""
        for index in 0..<min(document.pageCount, 3) {
            text += (document.page(at: index)?.string ?? "") + "\n"
            if text.count > limit { break }
        }
        return text
    }

    private static func documentText(_ url: URL, ext: String) -> String? {
        guard ["docx", "doc", "rtf", "odt", "html", "htm", "rtfd"].contains(ext) else { return nil }
        return (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
    }

    /// Office files are zip archives of XML; read just the text runs.
    private static func zippedText(_ url: URL, entries: String, tag: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, entries]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let xml = String(decoding: data.prefix(400_000), as: UTF8.self)
        let pattern = "<\(tag)(?: [^>]*)?>([^<]*)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let runs = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)).compactMap {
            Range($0.range(at: 1), in: xml).map { String(xml[$0]) }
        }
        return runs.joined(separator: " ")
    }

    /// Text in screenshots and scans, via on-device OCR. Photos usually have none and return nil.
    /// Large images are scaled down first: text stays readable and Vision needs far less memory.
    private static func imageText(_ url: URL, accurate: Bool) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 25_000_000 else { return nil }
        return autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 2_048,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                  ] as CFDictionary) else { return nil }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = accurate ? .accurate : .fast
            request.usesLanguageCorrection = accurate
            guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return nil }
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return lines.count < 2 ? nil : lines.joined(separator: " ")
        }
    }
}
