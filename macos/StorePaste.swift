import AppKit

enum StorePasteError: LocalizedError {
    case clipboardChanged
    case transferInProgress
    case overlappingFolders
    case recovery(URL)

    var errorDescription: String? {
        let strings = AppStrings.current
        switch self {
        case .clipboardChanged: return strings("The clipboard changed. Choose Paste again.")
        case .transferInProgress: return strings("FastRight is already pasting files.")
        case .overlappingFolders: return strings("A folder cannot be transferred into itself or replace a folder that contains it.")
        case .recovery(let url): return strings("The original item could not be restored. It is still available at %@.", url.path)
        }
    }
}

enum StoreFileTransfer {
    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    static func location(of url: URL) -> URL {
        url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent(url.lastPathComponent)
    }

    static func transfer(_ source: URL, to destination: URL, moving: Bool, replacing: Bool) throws {
        let sourcePath = location(of: source).pathComponents
        let destinationPath = location(of: destination).pathComponents
        if sourcePath == destinationPath, moving { return }
        guard !sourcePath.starts(with: destinationPath), !destinationPath.starts(with: sourcePath) else {
            throw StorePasteError.overlappingFolders
        }

        let manager = FileManager.default
        if moving && !replacing {
            try manager.moveItem(at: source, to: destination)
            return
        }

        // Stage copies on the destination volume before making them visible.
        let staging = try FileActions.stagingFolder(in: destination.deletingLastPathComponent())
        var keepBackup = false
        defer { if !keepBackup { try? manager.removeItem(at: staging) } }

        let incoming: URL
        if moving {
            incoming = source
        } else {
            incoming = staging.appendingPathComponent("incoming")
            try manager.copyItem(at: source, to: incoming)
        }

        let backup = staging.appendingPathComponent("previous")
        if replacing { try manager.moveItem(at: destination, to: backup) }
        do {
            try manager.moveItem(at: incoming, to: destination)
        } catch {
            if replacing {
                do { try manager.moveItem(at: backup, to: destination) }
                catch {
                    keepBackup = true
                    throw StorePasteError.recovery(backup)
                }
            }
            throw error
        }
    }
}

@MainActor
enum StorePaste {
    private enum ConflictChoice { case replace, keepBoth, cancel }
    private static var isPasting = false

    static func perform(into folder: URL, expectedChangeCount: Int?, clipboard: NSPasteboard = .general) async throws {
        guard !isPasting else { throw StorePasteError.transferInProgress }
        isPasting = true
        defer { isPasting = false }

        let changeCount = clipboard.changeCount
        guard expectedChangeCount == nil || expectedChangeCount == changeCount else { throw StorePasteError.clipboardChanged }
        let moving = FinderClipboard.containsCutFiles(clipboard)
        let files = clipboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        guard let files, !files.isEmpty else { throw FileActionError.emptyClipboard }
        var seen: Set<URL> = []
        let sources = files.filter { $0.isFileURL && seen.insert($0.standardizedFileURL).inserted }
        guard !sources.isEmpty else { throw FileActionError.emptyClipboard }
        guard clipboard.changeCount == changeCount else { throw StorePasteError.clipboardChanged }

        let settings = try Settings.load()
        let folders = settings.authorizedFolders
        var accessed = try StoreSandbox.startAccess(to: [folder], folders: folders)
        defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
        if moving {
            accessed += try StoreSandbox.startAccess(to: sources, folders: folders)
        } else {
            for source in sources {
                if source.startAccessingSecurityScopedResource() { accessed.append(source) }
                if let granted = try? StoreSandbox.startAccess(to: [source], folders: folders) { accessed += granted }
            }
        }

        var completed: [URL] = []
        defer {
            if moving && !completed.isEmpty && clipboard.changeCount == changeCount {
                let remaining = Array(sources.dropFirst(completed.count))
                _ = FinderClipboard.writeFiles(remaining.isEmpty ? completed : remaining,
                                              cut: !remaining.isEmpty, to: clipboard)
            }
        }

        for source in sources {
            try Task.checkCancellation()
            let destination = folder.appendingPathComponent(source.lastPathComponent)
            let sameLocation = StoreFileTransfer.location(of: source) == StoreFileTransfer.location(of: destination)
            let choice: ConflictChoice?
            if sameLocation {
                if moving {
                    completed.append(source)
                    continue
                }
                choice = .keepBoth
            } else {
                choice = StoreFileTransfer.exists(destination)
                    ? conflictChoice(for: destination.lastPathComponent, strings: settings.strings) : nil
            }
            if choice == .cancel { return }
            try Task.checkCancellation()
            let target = choice == .keepBoth ? try FileActions.uniqueURL(in: folder, name: source.lastPathComponent) : destination
            let replacing = choice == .replace
            try await Task.detached(priority: .userInitiated) {
                try StoreFileTransfer.transfer(source, to: target, moving: moving, replacing: replacing)
            }.value
            completed.append(target)
        }
    }

    private static func conflictChoice(for name: String, strings: AppStrings) -> ConflictChoice {
        let alert = NSAlert()
        alert.messageText = strings("An item named %@ already exists.", name)
        alert.informativeText = strings("Replace the existing item or keep both items.")
        alert.addButton(withTitle: strings("Keep Both"))
        alert.addButton(withTitle: strings("Replace"))
        alert.addButton(withTitle: strings("Cancel"))
        NSApplication.shared.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .keepBoth
        case .alertSecondButtonReturn: return .replace
        default: return .cancel
        }
    }
}
