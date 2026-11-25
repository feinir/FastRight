import AppKit

enum BetterZipOperation: String, Codable {
    case compress, extract

    private static let bundleIdentifier = "com.macitbetter.betterzip"
    private static let pathCharacters = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/"
    )
    private static let archiveExtensions: Set<String> = [
        "zip", "zipx", "7z", "rar", "tar", "tgz", "tbz", "tbz2", "txz", "tzst", "tbr",
        "gz", "bz", "bz2", "xz", "zst", "br", "dmg", "iso", "xar",
        "arj", "lha", "lzh", "chm", "cab", "cpio", "cpgz", "deb", "rpm", "sit", "sitx", "hqx",
        "epub", "jar", "war", "ear", "sar", "par", "wsr", "cbz", "cbr"
    ]

    static var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    static func forSelection(_ items: [URL]) -> Self {
        items.allSatisfy(isArchive) ? .extract : .compress
    }

    var presetNames: [String] {
        guard !StoreSandbox.isEnabled else { return [] }
        let key = self == .compress ? "MIBSavePresets" : "MIBExtractPresets"
        let domain = Self.bundleIdentifier
        let presets: [[String: Any]]?
        if let values = CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? [[String: Any]] {
            presets = values
        } else {
            let url = Settings.userHomeDirectory.appendingPathComponent("Library/Preferences/\(domain).plist")
            let preferences = (try? Data(contentsOf: url)).flatMap {
                (try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil)) as? [String: Any]
            }
            presets = preferences?[key] as? [[String: Any]]
        }
        var seen = Set<String>()
        return (presets ?? []).compactMap { $0["name"] as? String }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func isArchive(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let suffix = url.pathExtension.lowercased()
        let isFirstSplitVolume = name.hasSuffix(".zip.001") || name.hasSuffix(".7z.001")
        guard archiveExtensions.contains(suffix) || isFirstSplitVolume, !url.hasDirectoryPath else { return false }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
    }

    @MainActor
    func handOff(_ items: [URL], preset: String? = nil) async throws {
        guard let application = Self.applicationURL else { throw HandoffError.notInstalled }
        guard !items.isEmpty, items.allSatisfy(\.isFileURL) else { throw HandoffError.failed }
        let paths = items.compactMap { $0.path.addingPercentEncoding(withAllowedCharacters: Self.pathCharacters) }
        guard paths.count == items.count else { throw HandoffError.failed }

        var components = URLComponents()
        components.scheme = "btrzp"
        components.host = preset == nil ? "default-\(rawValue)" : rawValue
        if let preset {
            let allowedName = Self.pathCharacters.subtracting(CharacterSet(charactersIn: "/"))
            guard let encoded = preset.addingPercentEncoding(withAllowedCharacters: allowedName) else {
                throw HandoffError.failed
            }
            components.percentEncodedPath = "/" + encoded
        }
        // BetterZip splits the encoded query on semicolons before decoding each path.
        components.percentEncodedQuery = paths.joined(separator: ";")
        if !StoreSandbox.isEnabled {
            let tokenURL = Settings.userHomeDirectory
                .appendingPathComponent("Library/Application Support/\(Self.bundleIdentifier)/url-token")
            // BetterZip documents this token for local, user-initiated automation.
            components.fragment = (try? String(contentsOf: tokenURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let requestURL = components.url else { throw HandoffError.failed }
        do {
            _ = try await NSWorkspace.shared.open([requestURL], withApplicationAt: application, configuration: .init())
        } catch {
            // The underlying error can contain the URL, including its local-origin token.
            throw HandoffError.failed
        }
    }

    private enum HandoffError: LocalizedError {
        case notInstalled, failed

        var errorDescription: String? {
            switch self {
            case .notInstalled: return AppStrings.current("Could not find BetterZip.")
            case .failed: return AppStrings.current("Could not send the selected items to BetterZip.")
            }
        }
    }
}
