import Foundation

private final class StoreBundleMarker {}

enum StoreSandbox {
    static let applicationGroup = Bundle(for: StoreBundleMarker.self)
        .object(forInfoDictionaryKey: "FastRightApplicationGroup") as? String
    static var isEnabled: Bool { applicationGroup != nil }

    static func dataDirectory() throws -> URL {
        if let applicationGroup {
            guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: applicationGroup)
            else { throw AccessError.sharedContainer }
            return container.appendingPathComponent("FastRight", isDirectory: true)
        }
        return Settings.userHomeDirectory.appendingPathComponent("Library/Application Support/FastRight", isDirectory: true)
    }

    static func resolve(_ bookmark: Data) throws -> URL {
        var stale = false
        return try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                       relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    static func startAccess(to items: [URL], folders: [AuthorizedFolder]) throws -> [URL] {
        guard !items.isEmpty, items.allSatisfy(\.isFileURL) else { throw AccessError.folderRequired }
        var opened: [URL] = []
        for folder in folders {
            guard let url = try? resolve(folder.bookmark),
                  items.contains(where: { $0.standardizedFileURL.pathComponents.starts(with: url.standardizedFileURL.pathComponents) }),
                  url.startAccessingSecurityScopedResource() else { continue }
            opened.append(url)
            let roots = opened.map { $0.resolvingSymlinksInPath().standardizedFileURL }
            let granted = items.allSatisfy { item in
                let path = item.resolvingSymlinksInPath().standardizedFileURL.pathComponents
                return roots.contains { path.starts(with: $0.pathComponents) }
            }
            if granted { return opened }
        }
        opened.forEach { $0.stopAccessingSecurityScopedResource() }
        throw AccessError.folderRequired
    }

    enum AccessError: LocalizedError {
        case sharedContainer
        case folderRequired

        var errorDescription: String? {
            let strings = AppStrings.current
            switch self {
            case .sharedContainer: return strings("FastRight could not open the shared settings container.")
            case .folderRequired: return strings("Grant access to this folder in FastRight’s General settings and try again.")
            }
        }
    }
}

struct AuthorizedFolder: Codable, Equatable, Identifiable {
    var id: String { path }
    let path: String
    let bookmark: Data

    init(selectedURL: URL) throws {
        guard selectedURL.isFileURL,
              try selectedURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        else { throw StoreSandbox.AccessError.folderRequired }
        bookmark = try selectedURL.bookmarkData(options: .withSecurityScope)
        path = selectedURL.standardizedFileURL.path
    }
}

enum ScopedFileOperation: Codable {
    case createFolder(inContainer: Bool)
    case createFile(templateID: UUID, inContainer: Bool)
    case copyHash(algorithm: String, items: [URL])
    case open(items: [URL], application: URL)
    case betterZip(BetterZipOperation, items: [URL], preset: String?)
}
