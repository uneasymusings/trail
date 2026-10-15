import Foundation

/// Whether a word is ordinary English, from the system word list (/usr/share/dict/words).
/// Typo correction leaves real words alone: "blender" in a search for files you don't have
/// shouldn't turn into "blended". The list is memory-mapped and binary-searched, so it costs
/// nothing until it's used and little after.
enum EnglishWords {
    private static let data: Data? = try? Data(contentsOf: URL(fileURLWithPath: "/usr/share/dict/words"), options: .alwaysMapped)

    static func contains(_ word: String) -> Bool {
        guard let data, !word.isEmpty else { return false }
        let target = Array(word.lowercased().utf8)
        return data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
            let bytes = buffer.bindMemory(to: UInt8.self)
            var low = 0, high = bytes.count
            while low < high {
                // Find the start of the line at or before the midpoint.
                var start = (low + high) / 2
                while start > low, bytes[start - 1] != 10 { start -= 1 }
                var end = start
                while end < bytes.count, bytes[end] != 10 { end += 1 }
                let order = compare(bytes, start..<end, target)
                if order == 0 { return true }
                if order < 0 { low = end + 1 } else { high = start }
            }
            return false
        }
    }

    /// Compares a line to `target`, ignoring ASCII case, the way the list is sorted.
    private static func compare(_ bytes: UnsafeBufferPointer<UInt8>, _ line: Range<Int>, _ target: [UInt8]) -> Int {
        for (offset, index) in line.enumerated() {
            guard offset < target.count else { return 1 }
            var byte = bytes[index]
            if byte >= 65 && byte <= 90 { byte |= 0x20 }
            if byte != target[offset] { return byte < target[offset] ? -1 : 1 }
        }
        return line.count == target.count ? 0 : -1
    }
}
