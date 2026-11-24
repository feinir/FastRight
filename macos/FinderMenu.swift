import AppKit
import FinderSync

enum FinderScope {
    private static let volumeKeys: Set<URLResourceKey> = [.volumeIsInternalKey, .volumeIsLocalKey, .volumeURLKey]

    static let baseRoots: Set<URL> = [
        URL(fileURLWithPath: "/", isDirectory: true),
        URL(fileURLWithPath: "/Volumes", isDirectory: true)
    ]

    static func monitoredRoots() -> Set<URL> {
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(volumeKeys), options: .skipHiddenVolumes
        ) ?? mountedRootsInVolumes()
        // Register secondary internal volumes directly. External volumes continue
        // to use /Volumes as their parent instead of individual mount roots.
        return baseRoots.union(mounted.filter(isInternalVolume))
    }

    private static func mountedRootsInVolumes() -> [URL] {
        // The extension's environment can deny the system-wide mount enumeration.
        let keys: Set<URLResourceKey> = [.isVolumeKey, .volumeIsBrowsableKey]
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Volumes", isDirectory: true),
            includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles
        )) ?? []
        return entries.filter { entry in
            guard let volume = try? entry.resourceValues(forKeys: keys) else { return false }
            return volume.isVolume == true && volume.volumeIsBrowsable == true
        }
    }

    private static func isInternalVolume(_ url: URL) -> Bool {
        guard let volume = try? url.resourceValues(forKeys: volumeKeys) else { return false }
        return volume.volume?.path == "/" || (volume.volumeIsLocal == true && volume.volumeIsInternal == true)
    }

    static func isMountedVolumePath(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        return components.count > 2 && components[1] == "Volumes"
    }

    static func visibleMountRoots() -> Set<String>? {
        FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: .skipHiddenVolumes)
            .map { volumes in
                Set(volumes.flatMap { volume in
                    [volume.standardizedFileURL.path, volume.resolvingSymlinksInPath().path]
                }.filter { $0 != "/" })
            }
    }

    static func allows(_ url: URL, externalVolumes: Bool, visibleMountRoots: Set<String>?) -> Bool {
        guard url.isFileURL else { return false }
        if isInternalVolume(url) { return true }
        let paths = [url.standardizedFileURL, url.resolvingSymlinksInPath()]
        let onListedMount = visibleMountRoots?.contains { root in
            paths.contains { $0.path == root || $0.path.hasPrefix(root + "/") }
        } ?? false
        if onListedMount { return externalVolumes }
        if paths.contains(where: isMountedVolumePath) {
            return externalVolumes && visibleMountRoots == nil
        }
        return true
    }

    static func isVolumeRoot(_ url: URL) -> Bool {
        let normalized = url.standardizedFileURL
        if normalized.path == "/" { return true }
        let components = normalized.pathComponents
        if components.count == 3 && components[1] == "Volumes" { return true }
        return (try? normalized.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true
    }
}

enum FileActionError: LocalizedError {
    case noNameAvailable, writeFailed, launchFailed, invalidTemplateName
    case unavailableMenuAction, emptyClipboard
    case terminalNotInstalled(TerminalApplication)
    case editorNotInstalled(TextEditorApplication)
    case directoryUnavailable

    var errorDescription: String? {
        let strings = AppStrings.current
        switch self {
        case .noNameAvailable: return strings("No available file name was found.")
        case .writeFailed: return strings("Could not write to the clipboard.")
        case .launchFailed: return strings("Could not open the app. Check its name and installation location.")
        case .invalidTemplateName: return strings("The template file name is invalid.")
        case .unavailableMenuAction: return strings("This menu has expired. Open the Finder context menu again.")
        case .emptyClipboard: return strings("There are no files or folders to paste from the clipboard.")
        case .terminalNotInstalled(let terminal): return strings("Could not find %@. Check that it is installed or choose another terminal in General settings.",
                           terminal.title(in: strings))
        case .editorNotInstalled(let editor): return strings("Could not find %@. Check that it is installed or choose another text editor in General settings.",
                           editor.title(in: strings))
        case .directoryUnavailable: return strings("Could not open the folder. Check that it still exists and its drive is connected.")
        }
    }
}

enum FileActions {
    static let manager = FileManager.default

    static func destinationFolder(for item: URL) -> URL {
        if FinderScope.isVolumeRoot(item) || item.hasDirectoryPath
            || (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return item
        }
        return item.deletingLastPathComponent()
    }

    static func clipboardText(for items: [URL], namesOnly: Bool, includeExtensions: Bool = false) -> String {
        items.map { item in
            guard namesOnly else { return item.path }
            let name = item.lastPathComponent
            if includeExtensions || destinationFolder(for: item) == item { return name }
            return (name as NSString).deletingPathExtension
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func uniqueURL(in folder: URL, name: String) throws -> URL {
        let original = folder.appendingPathComponent(name)
        let stem = (name as NSString).deletingPathExtension
        let suffix = (name as NSString).pathExtension
        let available: (URL) -> Bool = { url in
            !manager.fileExists(atPath: url.path) && (try? manager.destinationOfSymbolicLink(atPath: url.path)) == nil
        }
        if available(original) { return original }
        for count in 1...10_000 {
            let base = "\(stem)-\(count)"
            let candidate = folder.appendingPathComponent(suffix.isEmpty ? base : "\(base).\(suffix)")
            if available(candidate) { return candidate }
        }
        throw FileActionError.noNameAvailable
    }

    @discardableResult
    static func create(_ name: String, in folder: URL, directory: Bool = false, contents: Data = Data()) throws -> URL {
        let target = try uniqueURL(in: folder, name: name)
        if directory {
            try manager.createDirectory(at: target, withIntermediateDirectories: false)
        } else {
            try contents.write(to: target, options: .withoutOverwriting)
        }
        return target
    }

    static func create(from template: FileTemplate, in folder: URL) throws -> URL {
        guard FileTemplate.isValidName(template.name) else { throw FileActionError.invalidTemplateName }
        guard let path = template.sourcePath else {
            return try create(template.name, in: folder, contents: Data((template.textContent ?? "").utf8))
        }
        let target = try uniqueURL(in: folder, name: template.name)
        let staging = try stagingFolder(in: folder)
        defer { try? manager.removeItem(at: staging) }
        let copy = staging.appendingPathComponent("template")
        try manager.copyItem(at: URL(fileURLWithPath: path), to: copy)
        try manager.moveItem(at: copy, to: target)
        return target
    }

    static func stagingFolder(in folder: URL) throws -> URL {
        let staging = folder.appendingPathComponent(".fastright-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        return staging
    }
}

final class FastRightMenu: NSObject {
    private typealias MenuAction = (FastRightMenu) throws -> Void
    typealias RequestHandler = (FinderRequest, @escaping (Error) -> Void) throws -> Void
    private static let menuBarActions: Set<FinderAction> = [.newFile, .folder, .terminal, .favoriteApps, .favoriteDirectories]

    private struct ApplicationEntry {
        let favorite: FavoriteApplication
        let url: URL
        let icon: NSImage?
    }

    private struct ApplicationAssets {
        let favorites: [FavoriteApplication]
        let loadedAt = ContinuousClock.now
        let entries: [UUID: ApplicationEntry]

        init(favorites: [FavoriteApplication]) {
            self.favorites = favorites
            let lookup = InstalledApplications()
            var entries: [UUID: ApplicationEntry] = [:]
            var icons: [URL: NSImage] = [:]
            for app in favorites {
                guard let url = app.installedURL(using: lookup) else { continue }
                if icons[url] == nil {
                    icons[url] = autoreleasepool { FinderMenuIcons.render(NSWorkspace.shared.icon(forFile: url.path)) }
                }
                entries[app.id] = ApplicationEntry(favorite: app, url: url, icon: icons[url])
            }
            self.entries = entries
        }
    }

    private let isMenuBar: Bool
    private let openPreferences: () throws -> Void
    private let sendRequest: RequestHandler
    private let preparationQueue = DispatchQueue(label: "com.ynpe.fastright.menu.preparation", qos: .userInitiated)
    private let icons: FinderMenuIcons
    private weak var actionTarget: NSObject?
    private var applicationAssets: ApplicationAssets?
    private var requestedFavorites: [FavoriteApplication]?
    private var applicationAssetWork: DispatchWorkItem?
    private var applicationAssetGeneration = 0
    private var recentMenuActions: [[Int: MenuAction]] = []
    private var hashRequestID: UUID?
    private var nextActionTag = 0

    init(archiveURL: URL?, isMenuBar: Bool = false, actionTarget: NSObject? = nil,
         openPreferences: @escaping () throws -> Void, sendRequest: @escaping RequestHandler) {
        self.isMenuBar = isMenuBar
        self.openPreferences = openPreferences
        self.sendRequest = sendRequest
        self.icons = FinderMenuIcons(archiveURL: archiveURL)
        self.actionTarget = actionTarget
        super.init()
        if let settings = try? Settings.load() {
            let favorites = enabledFavorites(for: settings)
            applicationAssets = ApplicationAssets(favorites: favorites)
            requestedFavorites = favorites
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(settingsDidSave(_:)),
                                                            name: Settings.didSaveNotification, object: nil)
    }

    deinit {
        applicationAssetWork?.cancel()
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func settingsDidSave(_ notification: Notification) {
        if let settings = try? Settings.load() { prepareApplications(for: settings) }
    }

    private func prepareApplications(for settings: Settings) {
        let favorites = enabledFavorites(for: settings)
        let cacheExpired = applicationAssets.map {
            $0.favorites == favorites && ContinuousClock.now - $0.loadedAt > .seconds(60)
        } ?? false
        guard requestedFavorites != favorites || (cacheExpired && applicationAssetWork == nil) else { return }
        requestedFavorites = favorites
        applicationAssetGeneration += 1
        let generation = applicationAssetGeneration
        applicationAssetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            let assets = ApplicationAssets(favorites: favorites)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.applicationAssetGeneration == generation else { return }
                self.applicationAssets = assets
                self.applicationAssetWork = nil
            }
        }
        applicationAssetWork = work
        preparationQueue.async(execute: work)
    }

    private func enabledFavorites(for settings: Settings) -> [FavoriteApplication] {
        guard isMenuBar || settings.menuEnabled,
              settings.enabledActions.contains(FinderAction.favoriteApps.rawValue) else { return [] }
        return settings.favoriteApplications.filter(\.enabled)
    }

    func contextMenu(for menu: FIMenuKind, target: URL, selection: [URL], settings: Settings) -> NSMenu? {
        guard isMenuBar || settings.menuEnabled else { return nil }
        prepareApplications(for: settings)
        let selectedItems = selection.filter { $0.standardizedFileURL.path != "/" }
        let items = selectedItems.isEmpty ? [target] : selectedItems
        if !isMenuBar {
            let mountRoots = FinderScope.visibleMountRoots()
            let allowed: (URL) -> Bool = {
                FinderScope.allows($0, externalVolumes: settings.externalVolumes, visibleMountRoots: mountRoots)
            }
            guard allowed(target), items.allSatisfy(allowed) else { return nil }
        }
        let folder = menu == .contextualMenuForContainer ? target : FileActions.destinationFolder(for: items[0])
        let strings = settings.strings
        var actions: [FinderAction: NSMenuItem] = [:]
        var topLevelTemplates: [NSMenuItem] = []
        var pinnedApplications: [UUID: NSMenuItem] = [:]
        var handlers: [Int: MenuAction] = [:]
        func isEnabled(_ action: FinderAction) -> Bool {
            settings.enabledActions.contains(action.rawValue) && (!isMenuBar || Self.menuBarActions.contains(action))
        }
        func command(_ title: String, _ callback: @escaping MenuAction) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: "")
            item.target = actionTarget ?? self
            // Finder reconstructs the sender across processes and preserves its tag.
            nextActionTag += 1
            item.tag = nextActionTag
            handlers[item.tag] = callback
            return item
        }
        func add(_ action: FinderAction, available: @autoclosure () -> Bool = true, _ callback: @escaping MenuAction) {
            guard isEnabled(action) else { return }
            if available() {
                actions[action] = command(action.labels(in: strings).title, callback)
            } else if settings.isInFastRightMenu(action) {
                let item = NSMenuItem(title: action.labels(in: strings).title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                actions[action] = item
            }
        }
        func addCollection(_ action: FinderAction, items: [NSMenuItem]) {
            guard !items.isEmpty else { return }
            let menu = NSMenu(title: action.labels(in: strings).title)
            menu.autoenablesItems = false
            items.forEach(menu.addItem)
            let item = NSMenuItem(title: action.labels(in: strings).title, action: nil, keyEquivalent: "")
            item.submenu = menu
            actions[action] = item
        }

        if isEnabled(.newFile) {
            let pinTemplates = !settings.isInFastRightMenu(.newFile)
            var foldedTemplates: [NSMenuItem] = []
            for saved in settings.fileTemplates where saved.enabled {
                let template = saved.localized(in: strings)
                let basename = (template.name as NSString).deletingPathExtension
                let title = settings.hideTemplateExtensions && !basename.isEmpty ? basename : template.name
                let item = command(title) { extensionInstance in
                    let url = try FileActions.create(from: template, in: folder)
                    extensionInstance.renameCreatedItem(url, openAfterRename: settings.openCreatedFiles,
                                                        applicationPath: template.applicationPath)
                }
                let isTopLevel = template.topLevel && pinTemplates
                if isTopLevel ? settings.showMainMenuIcons : settings.showSubmenuIcons {
                    item.image = icons.image("doc", colorful: settings.colorfulIcons)
                }
                if isTopLevel { topLevelTemplates.append(item) }
                else { foldedTemplates.append(item) }
            }
            addCollection(.newFile, items: foldedTemplates)
        }
        if isEnabled(.favoriteApps) {
            let favorites = settings.favoriteApplications.filter(\.enabled)
            let pinApplications = !settings.isInFastRightMenu(.favoriteApps)
            var foldedApplications: [NSMenuItem] = []
            for app in favorites {
                guard let entry = applicationAssets?.entries[app.id], entry.favorite.path == app.path,
                      entry.favorite.presetBundleIdentifier == app.presetBundleIdentifier else { continue }
                let item = command(app.displayName(in: strings)) { $0.open(items: items, application: entry.url) }
                let isTopLevel = app.topLevel && pinApplications
                if isTopLevel ? settings.showMainMenuIcons : settings.showSubmenuIcons {
                    item.image = entry.icon ?? icons.image("app", colorful: settings.colorfulIcons)
                }
                if isTopLevel { pinnedApplications[app.id] = item }
                else { foldedApplications.append(item) }
            }
            addCollection(.favoriteApps, items: foldedApplications)
        }
        if isEnabled(.favoriteDirectories) {
            var directories = settings.favoriteDirectories.filter(\.enabled).map { directory -> NSMenuItem in
                let item: NSMenuItem
                if directory.isAvailable {
                    item = command(directory.displayName(in: strings)) { extensionInstance in
                        guard directory.isAvailable else { throw FileActionError.directoryUnavailable }
                        try extensionInstance.sendRequest(FinderRequest(action: .goToDirectory, path: directory.path)) { error in
                            extensionInstance.showError(error.localizedDescription)
                        }
                    }
                } else {
                    item = NSMenuItem(title: directory.displayName(in: strings), action: nil, keyEquivalent: "")
                    item.isEnabled = false
                }
                if settings.showSubmenuIcons {
                    item.image = icons.image("folder", colorful: settings.colorfulIcons)
                }
                return item
            }
            let targetDirectory = FavoriteDirectory(name: "", path: target.path)
            let alreadySaved = settings.favoriteDirectories.contains {
                $0.url.standardizedFileURL.path == target.standardizedFileURL.path
            }
            let addTitle = strings("Add to Favorite Folders")
            let addDirectory: NSMenuItem
            if target.isFileURL, !alreadySaved, isMenuBar || targetDirectory.isAvailable {
                addDirectory = command(addTitle) { extensionInstance in
                    guard targetDirectory.isAvailable else { throw FileActionError.directoryUnavailable }
                    try extensionInstance.sendRequest(FinderRequest(action: .addFavoriteDirectory, path: targetDirectory.path)) { error in
                        extensionInstance.showError(error.localizedDescription)
                    }
                }
            } else {
                addDirectory = NSMenuItem(title: addTitle, action: nil, keyEquivalent: "")
                addDirectory.isEnabled = false
            }
            if settings.showSubmenuIcons {
                addDirectory.image = icons.image("folder.badge.plus", colorful: settings.colorfulIcons)
            }
            if !directories.isEmpty { directories.append(.separator()) }
            directories.append(addDirectory)
            addCollection(.favoriteDirectories, items: directories)
        }
        add(.folder) {
            let url = try FileActions.create(strings("Untitled"), in: folder, directory: true)
            $0.renameCreatedItem(url)
        }
        add(.path) {
            try $0.copyText(FileActions.clipboardText(for: items, namesOnly: false))
        }
        add(.name) {
            try $0.copyText(FileActions.clipboardText(
                for: items, namesOnly: true, includeExtensions: settings.copyNameExtensions
            ))
        }
        if isEnabled(.fileHash), menu == .contextualMenuForItems, items.allSatisfy(FileHash.canHash) {
            addCollection(.fileHash, items: FileHash.allCases.map { algorithm in
                command(strings("Copy %@", algorithm.rawValue)) { $0.copyHashes(algorithm, for: items) }
            })
        }
        let editableFiles = menu == .contextualMenuForItems && items.allSatisfy { item in
            (try? item.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        add(.editFile, available: editableFiles) {
            guard let application = InstalledApplications().url(for: settings.textEditor.rawValue) else {
                throw FileActionError.editorNotInstalled(settings.textEditor)
            }
            $0.open(items: items, application: application)
        }
        let canTransferSelection = menu != .contextualMenuForContainer && !items.contains(where: FinderScope.isVolumeRoot)
        add(.copy, available: canTransferSelection) { try $0.copyItems(items, cut: false) }
        add(.cut, available: canTransferSelection) { try $0.copyItems(items, cut: true) }
        add(.paste, available: FinderClipboard.containsFiles(.general)) { try $0.paste(into: folder) }
        add(.terminal) {
            let choice = settings.terminalApplication
            guard let application = InstalledApplications().url(for: choice.bundleIdentifier) else {
                throw FileActionError.terminalNotInstalled(choice)
            }
            $0.open(items: [folder], application: application)
        }
        let preferences = command(strings("FastRight Settings")) { try $0.openPreferences() }
        let result = FinderMenuLayout.make(settings: settings, icons: icons, actions: actions, preferences: preferences,
                                           topLevelTemplates: topLevelTemplates, pinnedApplications: pinnedApplications,
                                           flattenFastRight: isMenuBar)
        // Finder can ask for another menu before delivering an earlier menu's click.
        recentMenuActions.append(handlers)
        if recentMenuActions.count > 8 { recentMenuActions.removeFirst() }
        return result
    }

    private func renameCreatedItem(_ item: URL, openAfterRename: Bool = false, applicationPath: String? = nil) {
        do {
            let request = FinderRequest(action: .renameCreatedItem, path: item.path,
                                        openAfterRename: openAfterRename, applicationPath: applicationPath)
            try sendRequest(request) { _ in NSWorkspace.shared.activateFileViewerSelecting([item]) }
        } catch {
            NSWorkspace.shared.activateFileViewerSelecting([item])
        }
    }

    @objc func runAction(_ sender: NSMenuItem) {
        do {
            guard let action = recentMenuActions.reversed().lazy.compactMap({ $0[sender.tag] }).first else {
                throw FileActionError.unavailableMenuAction
            }
            try action(self)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func copyText(_ text: String) throws {
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        guard clipboard.setString(text, forType: .string) else {
            throw FileActionError.writeFailed
        }
    }

    private func copyHashes(_ algorithm: FileHash, for items: [URL]) {
        let request = UUID()
        hashRequestID = request
        let changeCount = NSPasteboard.general.changeCount
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try algorithm.clipboardText(for: items) }
            DispatchQueue.main.async {
                guard self.hashRequestID == request else { return }
                do {
                    let text = try result.get()
                    if NSPasteboard.general.changeCount == changeCount { try self.copyText(text) }
                } catch {
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    private func copyItems(_ urls: [URL], cut: Bool) throws {
        guard FinderClipboard.writeFiles(urls, cut: cut) else { throw FileActionError.writeFailed }
    }

    private func paste(into folder: URL) throws {
        let clipboard = NSPasteboard.general
        guard FinderClipboard.containsFiles(clipboard) else { throw FileActionError.emptyClipboard }
        let request = FinderRequest(action: .pasteFiles, path: folder.path, clipboardChangeCount: clipboard.changeCount)
        try sendRequest(request) { error in
            self.showError(error.localizedDescription)
        }
    }

    private func open(items: [URL], application: URL) {
        NSWorkspace.shared.open(items, withApplicationAt: application, configuration: .init()) { _, error in
            guard let error else { return }
            DispatchQueue.main.async { self.showError(error.localizedDescription) }
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "FastRight"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: AppStrings.current("OK"))
        alert.runModal()
    }
}

enum FinderMenuLayout {
    static func make(settings: Settings, icons: FinderMenuIcons, actions: [FinderAction: NSMenuItem], preferences: NSMenuItem,
                     topLevelTemplates: [NSMenuItem] = [], pinnedApplications: [UUID: NSMenuItem] = [:],
                     flattenFastRight: Bool = false) -> NSMenu {
        let root = NSMenu()
        root.autoenablesItems = false
        var groups: [UUID: NSMenu] = [:]
        let foldedMenu = NSMenu(title: Settings.foldedMenuTitle)
        foldedMenu.autoenablesItems = false

        func submenuEntry(_ submenu: NSMenu, symbol: String, showIcon: Bool) -> NSMenuItem {
            let entry = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            entry.submenu = submenu
            if showIcon { entry.image = icons.image(symbol, colorful: settings.colorfulIcons) }
            return entry
        }

        for entry in settings.orderedMenuEntries {
            if case .favoriteApplication(let id) = entry {
                if let item = pinnedApplications[id] { root.addItem(item) }
                continue
            }
            guard case .action(let action) = entry else { continue }
            if action == .newFile { topLevelTemplates.forEach(root.addItem) }
            guard let item = actions[action] else { continue }
            let destination: NSMenu
            if let group = settings.group(for: action) {
                if let existing = groups[group.id] {
                    destination = existing
                } else {
                    let submenu = NSMenu(title: group.name)
                    submenu.autoenablesItems = false
                    root.addItem(submenuEntry(submenu, symbol: "folder", showIcon: settings.showMainMenuIcons))
                    groups[group.id] = submenu
                    destination = submenu
                }
            } else if settings.foldedActions.contains(action.rawValue) {
                destination = foldedMenu
            } else {
                destination = root
            }
            let showIcon = destination === root ? settings.showMainMenuIcons : settings.showSubmenuIcons
            item.image = showIcon ? icons.image(action.symbol, colorful: settings.colorfulIcons) : nil
            destination.addItem(item)
        }

        if settings.showSubmenuIcons { preferences.image = icons.image("gearshape", colorful: settings.colorfulIcons) }
        if !foldedMenu.items.isEmpty { foldedMenu.insertItem(.separator(), at: 0) }
        foldedMenu.insertItem(preferences, at: 0)
        if flattenFastRight {
            let items = foldedMenu.items
            foldedMenu.removeAllItems()
            if settings.foldedMenuPosition == .first {
                if !root.items.isEmpty { root.insertItem(.separator(), at: 0) }
                for (index, item) in items.enumerated() { root.insertItem(item, at: index) }
            } else {
                if !root.items.isEmpty { root.addItem(.separator()) }
                items.forEach(root.addItem)
            }
            return root
        }
        let fastRightItem = submenuEntry(foldedMenu, symbol: "gearshape", showIcon: settings.showFoldedMenuIcon)
        root.insertItem(fastRightItem, at: settings.foldedMenuPosition == .first ? 0 : root.numberOfItems)
        return root
    }

}
