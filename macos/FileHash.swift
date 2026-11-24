import CryptoKit
import Foundation

enum FileHash: String, CaseIterable {
    case md5 = "MD5"
    case sha1 = "SHA-1"
    case sha256 = "SHA-256"
    case sha512 = "SHA-512"
    case crc32 = "CRC32"

    static func canHash(_ url: URL) -> Bool {
        (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    func clipboardText(for files: [URL]) throws -> String {
        try files.map { url in
            let hash = try digest(of: url)
            guard files.count > 1 else { return hash }
            return "\(hash)  \(url.lastPathComponent)"
        }.joined(separator: "\n")
    }

    func digest(of url: URL) throws -> String {
        guard Self.canHash(url) else { throw CocoaError(.fileReadUnsupportedScheme) }
        switch self {
        case .md5: return try digest(of: url, using: Insecure.MD5())
        case .sha1: return try digest(of: url, using: Insecure.SHA1())
        case .sha256: return try digest(of: url, using: SHA256())
        case .sha512: return try digest(of: url, using: SHA512())
        case .crc32:
            var crc = UInt32.max
            try readChunks(of: url) { chunk in
                for byte in chunk {
                    let index = Int(UInt8(truncatingIfNeeded: crc) ^ byte)
                    crc = Self.crc32Table[index] ^ (crc >> 8)
                }
            }
            return String(format: "%08x", crc ^ UInt32.max)
        }
    }

    private func digest<H: HashFunction>(of url: URL, using initialHasher: H) throws -> String {
        var hasher = initialHasher
        try readChunks(of: url) { hasher.update(data: $0) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func readChunks(of url: URL, update: (Data) -> Void) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
            update(chunk)
        }
    }

    private static let crc32Table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value >> 1) ^ (value & 1 == 0 ? 0 : 0xedb88320)
        }
        return value
    }
}
