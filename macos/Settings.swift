import AppKit
import Darwin
import Foundation

enum FinderAction: String, CaseIterable {
    case newFile, favoriteApps, favoriteDirectories, folder, path, name, fileHash, copy, cut, paste, terminal, editFile
    case betterZipCompress, betterZipExtract

    static let defaultOrder: [Self] = [
        .newFile, .folder, .favoriteApps, .favoriteDirectories, .path, .name, .fileHash, .editFile,
        .copy, .cut, .paste, .terminal, .betterZipCompress, .betterZipExtract
    ]

    var symbol: String {
        switch self {
        case .newFile: return "doc.badge.plus"
        case .favoriteApps: return "square.grid.2x2"
        case .favoriteDirectories: return "folder.fill"
        case .folder: return "folder.badge.plus"
        case .path: return "link"
        case .name: return "tag"
        case .fileHash: return "number"
        case .copy: return "doc.on.doc"
        case .cut: return "scissors"
        case .paste: return "clipboard"
        case .terminal: return "terminal"
        case .editFile: return "square.and.pencil"
        case .betterZipCompress: return "doc.zipper"
        case .betterZipExtract: return "tray.and.arrow.down"
        }
    }

    func labels(in strings: AppStrings) -> (title: String, detail: String) {
        switch self {
        case .newFile: return (strings("New File"), strings("Create files from enabled templates"))
        case .favoriteApps: return (strings("Favorite Apps"), strings("Open selected items with enabled apps"))
        case .favoriteDirectories: return (strings("Favorite Folders"), strings("Open favorite folders in Finder"))
        case .folder: return (strings("New Folder"), strings("Automatically choose an available name"))
        case .path: return (strings("Copy Path"), strings("Copy paths for one or more selected items"))
        case .name: return (strings("Copy Name"), strings("Copy names for one or more selected items"))
        case .fileHash: return (strings("File Hash"), strings("Calculate and copy checksums for selected files"))
        case .copy: return (strings("Copy"), strings("Copy selected items to the Finder clipboard"))
        case .cut: return (strings("Cut"), strings("Move selected items when pasting with FastRight"))
        case .paste:
            let detail = StoreSandbox.isEnabled ? "Paste files and resolve name conflicts" : "Use Finder paste and handle name conflicts in Finder"
            return (strings("Paste"), strings(detail))
        case .terminal: return (strings("Open in Terminal"), strings("Open folders in the terminal selected in General settings"))
        case .editFile: return (strings("Edit File"), strings("Open selected files in the text editor selected in General settings"))
        case .betterZipCompress: return (strings("Compress with BetterZip"), strings("Compress selected items using BetterZip’s default preset"))
        case .betterZipExtract: return (strings("Extract with BetterZip"), strings("Extract selected archives using BetterZip’s default preset"))
        }
    }
}

enum FinderMenuEntry: Hashable {
    case action(FinderAction)
    case favoriteApplication(UUID)

    var orderKey: String {
        switch self {
        case .action(let action): return action.rawValue
        case .favoriteApplication(let id): return "favoriteApp:\(id.uuidString)"
        }
    }

    init?(orderKey: String) {
        if let action = FinderAction(rawValue: orderKey) {
            self = .action(action)
        } else if orderKey.hasPrefix("favoriteApp:"),
                  let id = UUID(uuidString: String(orderKey.dropFirst("favoriteApp:".count))) {
            self = .favoriteApplication(id)
        } else {
            return nil
        }
    }
}

enum TerminalApplication: String, Codable, CaseIterable {
    case terminal, iTerm2

    func title(in strings: AppStrings) -> String {
        switch self {
        case .terminal: return strings("System Terminal")
        case .iTerm2: return "iTerm2"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .iTerm2: return "com.googlecode.iterm2"
        }
    }
}

enum FoldedMenuPosition: String, Codable {
    case first, last
}

enum TextEditorApplication: String, Codable, CaseIterable {
    case textEdit = "com.apple.TextEdit"
    case zed = "dev.zed.Zed"
    case sublimeText = "com.sublimetext.4"
    case cotEditor = "com.coteditor.CotEditor"
    case bbEdit = "com.barebones.bbedit"
    case vsCode = "com.microsoft.VSCode"
    case cursor = "com.todesktop.230313mzl4w4u92"
    case nova = "com.panic.Nova"

    func title(in strings: AppStrings) -> String {
        FavoriteApplication.presetTitle(for: rawValue, in: strings) ?? rawValue
    }
}

struct FinderMenuGroup: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
}

struct FinderRequest: Codable {
    enum Action: String, Codable {
        case renameCreatedItem, goToDirectory, pasteFiles, startCutShortcut, addFavoriteDirectory, openPreferences
        case scopedFileOperation
    }

    let action: Action
    let path: String
    var openAfterRename = false
    var applicationPath: String?
    var clipboardChangeCount: Int?
    var fileOperation: ScopedFileOperation?

    private static func directory() throws -> URL {
        try StoreSandbox.dataDirectory().appendingPathComponent("Finder Requests", isDirectory: true)
    }

    func writeRequest() throws -> URL {
        let directory = try Self.directory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let request = directory.appendingPathComponent(UUID().uuidString + ".fastright-request")
        try JSONEncoder().encode(self).write(to: request, options: .atomic)
        return request
    }

    static func takeRequest(at url: URL) -> Self? {
        guard url.isFileURL, url.pathExtension == "fastright-request",
              let directory = try? directory(),
              url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
              UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
              let data = try? Data(contentsOf: url) else { return nil }
        do {
            try FileManager.default.removeItem(at: url)
            let request = try JSONDecoder().decode(Self.self, from: data)
            return request.path.hasPrefix("/") ? request : nil
        } catch {
            return nil
        }
    }
}

enum FinderClipboard {
    private static let cutType = NSPasteboard.PasteboardType("com.ynpe.fastright.cut")
    private static let oldCutType = NSPasteboard.PasteboardType("io.fastright.macos.cut")

    static func containsCutFiles(_ clipboard: NSPasteboard) -> Bool {
        guard let item = clipboard.pasteboardItems?.first else { return false }
        return item.string(forType: cutType) == "move" || item.string(forType: oldCutType) == "move"
    }

    static func containsFiles(_ clipboard: NSPasteboard) -> Bool {
        clipboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    @discardableResult
    static func writeFiles(_ urls: [URL], cut: Bool, to clipboard: NSPasteboard = .general) -> Bool {
        guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
        var items: [NSPasteboardItem] = []
        for url in urls {
            let item = NSPasteboardItem()
            guard item.setString(url.absoluteString, forType: .fileURL) else { return false }
            if cut && items.isEmpty && !item.setString("move", forType: cutType) { return false }
            items.append(item)
        }
        clipboard.clearContents()
        return clipboard.writeObjects(items)
    }
}

struct FileTemplate: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var sourcePath: String?
    var sourceBookmark: Data?
    var textContent: String?
    var applicationPath: String?
    var topLevel = false
    var enabled = true
    var presetExtension: String?

    private static let presets: [(title: String, fileExtension: String, contents: String?)] = [
        ("Markdown", "md", "# 标题\n\n"), ("Text", "txt", nil),
        ("CSV", "csv", "name,value\n"), ("TSV", "tsv", "name\tvalue\n"),
        ("JSON", "json", "{}\n"), ("YAML", "yaml", "---\n{}\n"),
        ("TOML", "toml", "# Configuration\n"),
        ("XML", "xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<root />\n"),
        ("HTML", "html", """
        <!doctype html>
        <html lang="zh-CN">
        <head>
          <meta charset="UTF-8">
          <title>标题</title>
        </head>
        <body>
        </body>
        </html>

        """),
        ("CSS", "css", "/* Styles */\n"),
        ("JavaScript", "js", "// JavaScript\n"), ("TypeScript", "ts", "// TypeScript\n"),
        ("Python", "py", "#!/usr/bin/env python3\n\n"),
        ("Shell Script", "sh", "#!/bin/bash\n\n"), ("SQL", "sql", "-- SQL\n"),
        ("Log", "log", nil)
    ]

    func presetTitle(in strings: AppStrings) -> String? {
        Self.presets.first { $0.fileExtension == presetExtension }.map { strings($0.title) }
    }

    func displayName(in strings: AppStrings) -> String {
        guard let ext = presetExtension, name == "未命名.\(ext)" else { return name }
        return strings("Untitled") + "." + ext
    }

    func localized(in strings: AppStrings) -> Self {
        var template = self
        template.name = displayName(in: strings)
        if strings.language != .simplifiedChinese, sourcePath == nil,
           let preset = Self.presets.first(where: { $0.fileExtension == presetExtension }),
           let contents = preset.contents, textContent == contents,
           preset.fileExtension == "md" || preset.fileExtension == "html" {
            template.textContent = contents.replacingOccurrences(of: "标题", with: strings("Title"))
                .replacingOccurrences(of: "lang=\"zh-CN\"", with: "lang=\"\(strings.language.rawValue)\"")
        }
        return template
    }

    static func defaultTemplates() -> [Self] {
        presets.map { preset in
            let ext = preset.fileExtension
            return Self(name: "未命名.\(ext)", textContent: preset.contents,
                        enabled: ext == "md" || ext == "txt", presetExtension: ext)
        }
    }

    static func migratingPresets(_ saved: [Self]) -> [Self] {
        saved.compactMap { entry in
            var template = entry
            guard let ext = template.presetExtension else { return template }
            let stockName = template.name == "未命名.\(ext)"
            let empty = template.sourcePath == nil && template.textContent == nil
            if ext == "ini" {
                if stockName && empty && template.applicationPath == nil && !template.topLevel && !template.enabled {
                    return nil
                }
                template.presetExtension = nil
            } else if stockName && empty {
                template.textContent = presets.first { $0.fileExtension == ext }?.contents
            }
            return template
        }
    }

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
            && !name.contains(":") && !name.utf8.contains(0)
    }
}

struct FavoriteApplication: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var path: String
    var topLevel = false
    var enabled = true
    var presetBundleIdentifier: String?

    private static let fastRemoteIdentifier = "com.ynpe.fastremote"

    static let presets: [(name: String, bundleIdentifier: String)] = [
        ("FastRemote", fastRemoteIdentifier),
        ("文本编辑", "com.apple.TextEdit"), ("CotEditor", "com.coteditor.CotEditor"),
        ("Visual Studio Code", "com.microsoft.VSCode"), ("Cursor", "com.todesktop.230313mzl4w4u92"),
        ("Zed", "dev.zed.Zed"), ("Sublime Text", "com.sublimetext.4"),
        ("BBEdit", "com.barebones.bbedit"), ("Nova", "com.panic.Nova"),
        ("Xcode", "com.apple.dt.Xcode"), ("IntelliJ IDEA", "com.jetbrains.intellij"),
        ("PyCharm", "com.jetbrains.pycharm"), ("Android Studio", "com.google.android.studio"),
        ("Typora", "abnerworks.Typora"), ("Obsidian", "md.obsidian"),
        ("终端", "com.apple.Terminal"), ("iTerm2", "com.googlecode.iterm2"),
        ("Warp", "dev.warp.Warp-Stable"), ("Ghostty", "com.mitchellh.ghostty"),
        ("预览", "com.apple.Preview"), ("快速时间播放器", "com.apple.QuickTimePlayerX"),
        ("VLC", "org.videolan.vlc"), ("IINA", "com.colliderli.iina"),
        ("Pages", "com.apple.iWork.Pages"), ("Numbers", "com.apple.iWork.Numbers"),
        ("Keynote", "com.apple.iWork.Keynote"), ("Microsoft Word", "com.microsoft.Word"),
        ("Microsoft Excel", "com.microsoft.Excel"), ("Microsoft PowerPoint", "com.microsoft.Powerpoint"),
        ("LibreOffice", "org.libreoffice.script"), ("Safari", "com.apple.Safari"),
        ("Google Chrome", "com.google.Chrome"), ("Firefox", "org.mozilla.firefox"),
        ("Microsoft Edge", "com.microsoft.edgemac"), ("Brave", "com.brave.Browser"),
        ("Pixelmator Pro", "com.pixelmatorteam.pixelmator.x"), ("GIMP", "org.gimp.gimp"),
        ("Inkscape", "org.inkscape.Inkscape"), ("Blender", "org.blenderfoundation.blender"),
        ("The Unarchiver", "com.macpaw.site.theunarchiver"), ("Keka", "com.aone.keka"),
        ("BetterZip", "com.macitbetter.betterzip"), ("Beyond Compare", "com.ScooterSoftware.BeyondCompare"),
        ("FlowVision", "netdcy.FlowVision"), ("PDF Expert", "com.readdle.PDFExpert-Mac"),
        ("Path Finder", "com.cocoatech.PathFinder"), ("HoudahSpot", "com.houdah.HoudahSpot4"),
        ("OpenCode", "ai.opencode.desktop"), ("Claude", "com.anthropic.claudefordesktop"),
        ("Microsoft Outlook", "com.microsoft.Outlook"), ("微信", "com.tencent.xinWeChat"),
        ("AnyDesk", "com.philandro.anydesk"), ("RustDesk", "com.carriez.rustdesk"),
        ("Jump Desktop", "com.p5sys.jump.mac.viewer"), ("Windows App", "com.microsoft.rdc.macos"),
        ("SecureCRT", "com.vandyke.SecureCRT"), ("FileZilla", "org.filezilla-project.filezilla"),
        ("Transmit", "com.panic.Transmit"), ("Transmission", "org.m0k.transmission"),
        ("OrbStack", "dev.kdrag0n.MacVirt"), ("UTM", "com.utmapp.UTM"),
        ("Surge", "com.nssurge.surge-mac"), ("Charles", "com.xk72.Charles"),
        ("Proxyman", "com.proxyman.NSProxy"), ("Wireshark", "org.wireshark.Wireshark"),
        ("Rectangle", "com.knollsoft.Rectangle"), ("uTools", "org.yuanli.utools")
    ]

    static func presetTitle(for identifier: String, in strings: AppStrings) -> String? {
        switch identifier {
        case "com.apple.TextEdit": return strings("TextEdit")
        case "com.apple.Terminal": return strings("Terminal")
        case "com.apple.Preview": return strings("Preview")
        case "com.apple.QuickTimePlayerX": return strings("QuickTime Player")
        case "com.tencent.xinWeChat": return strings("WeChat")
        default: return presets.first { $0.bundleIdentifier == identifier }?.name
        }
    }

    func displayName(in strings: AppStrings) -> String {
        guard let identifier = presetBundleIdentifier,
              Self.presets.contains(where: { $0.bundleIdentifier == identifier && $0.name == name }) else { return name }
        return Self.presetTitle(for: identifier, in: strings) ?? name
    }

    static func defaultApplications() -> [Self] {
        presets.map {
            Self(name: $0.name, path: "", enabled: $0.bundleIdentifier == fastRemoteIdentifier
                 || $0.bundleIdentifier == "com.apple.TextEdit",
                 presetBundleIdentifier: $0.bundleIdentifier)
        }
    }

    static func presetIdentifier(for identifier: String) -> String? {
        presets.first {
            InstalledApplications.bundleIdentifiers(for: $0.bundleIdentifier).contains(identifier)
        }?.bundleIdentifier
    }

    func installedURL(using lookup: InstalledApplications) -> URL? {
        if !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            if let identifier = InstalledApplications.identifier(at: url),
               presetBundleIdentifier == nil || Self.presetIdentifier(for: identifier) == presetBundleIdentifier {
                return url
            }
        }
        return presetBundleIdentifier.flatMap { lookup.url(for: $0) }
    }
}

struct FavoriteDirectory: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var path: String
    var enabled = true

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    func displayName(in strings: AppStrings) -> String {
        let title = localizedName(in: strings).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? url.lastPathComponent : title
    }

    func localizedName(in strings: AppStrings) -> String {
        let path = url.standardizedFileURL.path
        guard let entry = Self.defaults.first(where: { $0.path == path && $0.name == name }) else { return name }
        return strings(entry.key)
    }

    private static let defaults: [(name: String, path: String, key: String)] = {
        let home = Settings.userHomeDirectory
        return [
            ("下载", home.appendingPathComponent("Downloads").path, "Downloads"),
            ("文档", home.appendingPathComponent("Documents").path, "Documents"),
            ("Application", "/Applications", "Applications")
        ]
    }()

    static func addingDefaults(to saved: [Self]) -> [Self] {
        let defaults = Self.defaults.map { Self(name: $0.name, path: $0.path) }
        var paths = Set(saved.map { $0.url.standardizedFileURL.path })
        return saved + defaults.filter { paths.insert($0.url.standardizedFileURL.path).inserted }
    }

    static func adding(_ urls: [URL], to saved: [Self]) -> [Self] {
        var paths = Set(saved.map { $0.url.resolvingSymlinksInPath().path })
        return saved + urls.compactMap { url in
            let directory = Self(name: "", path: url.standardizedFileURL.path)
            guard url.isFileURL, directory.isAvailable,
                  paths.insert(directory.url.resolvingSymlinksInPath().path).inserted else { return nil }
            return directory
        }
    }

    var isAvailable: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

final class InstalledApplications {
    private static let alternateIdentifiers = [
        "com.apple.iWork.Pages": ["com.apple.Pages"],
        "com.apple.iWork.Numbers": ["com.apple.Numbers"],
        "com.apple.iWork.Keynote": ["com.apple.Keynote"],
        "com.sublimetext.4": ["com.sublimetext.3"]
    ]

    private lazy var applicationsByIdentifier = scanApplicationDirectories()

    static func bundleIdentifiers(for identifier: String) -> [String] {
        [identifier] + alternateIdentifiers[identifier, default: []]
    }

    static func identifier(at url: URL) -> String? {
        guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              FileManager.default.fileExists(atPath: url.path),
              let bundle = Bundle(url: url),
              bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL"
        else { return nil }
        return bundle.bundleIdentifier
    }

    func url(for identifier: String) -> URL? {
        let identifiers = Self.bundleIdentifiers(for: identifier)
        for id in identifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
               Self.identifier(at: url) == id { return url }
        }
        return identifiers.lazy.compactMap { self.applicationsByIdentifier[$0] }.first
    }

    func legacyEditorURL(named value: String) -> URL? {
        let editor = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !editor.isEmpty else { return nil }
        if editor.hasPrefix("/") || editor.hasPrefix("~/") {
            let url = URL(fileURLWithPath: (editor as NSString).expandingTildeInPath)
            return Self.identifier(at: url) != nil ? url : nil
        }
        let name = editor.hasSuffix(".app") ? editor : editor + ".app"
        return url(for: editor) ?? applicationsByIdentifier.values.first {
            $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    private func scanApplicationDirectories() -> [String: URL] {
        let manager = FileManager.default
        let directories = [Settings.userHomeDirectory.appendingPathComponent("Applications")]
            + manager.urls(for: .applicationDirectory, in: [.localDomainMask, .systemDomainMask])
        var found: [String: URL] = [:]
        for directory in directories {
            guard let entries = manager.enumerator(at: directory, includingPropertiesForKeys: [],
                                                   options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in entries where url.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                entries.skipDescendants()
                if let identifier = Self.identifier(at: url), found[identifier] == nil {
                    found[identifier] = url
                }
            }
        }
        return found
    }
}

struct Settings: Codable, Equatable {
    static let didSaveNotification = Notification.Name(
        (StoreSandbox.applicationGroup ?? "com.ynpe.fastright") + ".settingsDidSave"
    )
    var language = AppLanguage.system
    var strings: AppStrings { AppStrings(language: language) }
    var authorizedFolders: [AuthorizedFolder] = []
    var externalVolumes = false
    var enabledActions = Set(FinderAction.allCases.map(\.rawValue))
    var copyNameExtensions = false
    var menuEnabled = true
    var showMenuBarIcon = true
    var showMainMenuIcons = true
    var showSubmenuIcons = true
    var showFoldedMenuIcon = true
    var colorfulIcons = false
    static let foldedMenuTitle = "FastRight"
    var foldedMenuPosition = FoldedMenuPosition.first
    var foldedActions = Set([FinderAction.copy, .cut, .paste, .terminal, .editFile].map(\.rawValue))
    var actionOrder = FinderAction.defaultOrder.map(\.rawValue)
    var menuGroups: [FinderMenuGroup] = []
    var actionGroups: [String: UUID] = [:]
    var fileTemplates = FileTemplate.defaultTemplates()
    private var fileTemplateContentsInitialized = true
    var favoriteApplications = FavoriteApplication.defaultApplications() {
        didSet {
            let ids = Set(favoriteApplications.map(\.id))
            actionOrder.removeAll { key in
                guard case .favoriteApplication(let id) = FinderMenuEntry(orderKey: key) else { return false }
                return !ids.contains(id)
            }
        }
    }
    var favoriteDirectories = FavoriteDirectory.addingDefaults(to: [])
    private var favoriteDirectoryDefaultsAdded = true
    var terminalApplication = TerminalApplication.terminal
    var textEditor = TextEditorApplication.textEdit
    var openCreatedFiles = false
    var hideTemplateExtensions = false

    var orderedMenuEntries: [FinderMenuEntry] {
        let applicationIDs = Set(favoriteApplications.map(\.id))
        var seen = Set<FinderMenuEntry>()
        var entries = (actionOrder.compactMap(FinderMenuEntry.init(orderKey:))
                       + FinderAction.defaultOrder.map(FinderMenuEntry.action)).filter { entry in
            if case .favoriteApplication(let id) = entry, !applicationIDs.contains(id) { return false }
            return seen.insert(entry).inserted
        }
        let newlyPinned = favoriteApplications.filter(\.topLevel).map { FinderMenuEntry.favoriteApplication($0.id) }
            .filter { seen.insert($0).inserted }
        if let index = entries.firstIndex(of: .action(.favoriteApps)) {
            entries.insert(contentsOf: newlyPinned, at: index)
        }
        return entries
    }

    func group(for action: FinderAction) -> FinderMenuGroup? {
        guard let id = actionGroups[action.rawValue] else { return nil }
        return menuGroups.first { $0.id == id }
    }

    func isInFastRightMenu(_ action: FinderAction) -> Bool {
        foldedActions.contains(action.rawValue) && group(for: action) == nil
    }

    private enum CodingKeys: String, CodingKey {
        case language
        case authorizedFolders = "authorized_folders"
        case externalVolumes = "external_volumes"
        case enabledActions = "enabled_actions"
        case copyNameExtensions = "copy_name_extensions"
        case menuEnabled = "menu_enabled"
        case showMenuBarIcon = "show_menu_bar_icon"
        case showMainMenuIcons = "show_main_menu_icons"
        case showSubmenuIcons = "show_submenu_icons"
        case showFoldedMenuIcon = "show_folded_menu_icon"
        case colorfulIcons = "colorful_icons"
        case foldedMenuPosition = "folded_menu_position"
        case foldedActions = "folded_actions"
        case actionOrder = "action_order"
        case menuGroups = "menu_groups"
        case actionGroups = "action_groups"
        case fileTemplates = "file_templates"
        case fileTemplateContentsInitialized = "file_template_contents_initialized"
        case favoriteApplications = "favorite_applications"
        case favoriteDirectories = "favorite_directories"
        case favoriteDirectoryDefaultsAdded = "favorite_directory_defaults_added"
        case terminalApplication = "terminal_application"
        case textEditor = "text_editor"
        case openCreatedFiles = "open_created_files"
        case hideTemplateExtensions = "hide_template_extensions"
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case editorApp = "editor_app"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        language = try values.decodeIfPresent(String.self, forKey: .language)
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
        authorizedFolders = try values.decodeIfPresent([AuthorizedFolder].self, forKey: .authorizedFolders) ?? []
        externalVolumes = try values.decodeIfPresent(Bool.self, forKey: .externalVolumes) ?? externalVolumes
        let savedActions = try values.decodeIfPresent(Set<String>.self, forKey: .enabledActions)
        enabledActions = savedActions ?? enabledActions
        copyNameExtensions = try values.decodeIfPresent(Bool.self, forKey: .copyNameExtensions) ?? copyNameExtensions
        menuEnabled = try values.decodeIfPresent(Bool.self, forKey: .menuEnabled) ?? menuEnabled
        showMenuBarIcon = try values.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? showMenuBarIcon
        showMainMenuIcons = try values.decodeIfPresent(Bool.self, forKey: .showMainMenuIcons) ?? showMainMenuIcons
        showSubmenuIcons = try values.decodeIfPresent(Bool.self, forKey: .showSubmenuIcons) ?? showSubmenuIcons
        showFoldedMenuIcon = try values.decodeIfPresent(Bool.self, forKey: .showFoldedMenuIcon) ?? showFoldedMenuIcon
        colorfulIcons = try values.decodeIfPresent(Bool.self, forKey: .colorfulIcons) ?? colorfulIcons
        foldedMenuPosition = try values.decodeIfPresent(FoldedMenuPosition.self, forKey: .foldedMenuPosition)
            ?? foldedMenuPosition
        foldedActions = try values.decodeIfPresent(Set<String>.self, forKey: .foldedActions) ?? foldedActions
        let savedOrder = try values.decodeIfPresent([String].self, forKey: .actionOrder)
        actionOrder = savedOrder ?? actionOrder
        let hashAction = FinderAction.fileHash.rawValue
        if savedOrder?.contains(hashAction) != true {
            enabledActions.insert(hashAction)
            if !actionOrder.contains(hashAction) {
                let index = actionOrder.firstIndex(of: FinderAction.name.rawValue).map { $0 + 1 } ?? actionOrder.endIndex
                actionOrder.insert(hashAction, at: index)
            }
        }
        let editAction = FinderAction.editFile.rawValue
        if savedOrder?.contains(editAction) != true {
            enabledActions.insert(editAction)
            foldedActions.insert(editAction)
            if !actionOrder.contains(editAction) {
                let index = actionOrder.firstIndex(of: hashAction).map { $0 + 1 } ?? actionOrder.endIndex
                actionOrder.insert(editAction, at: index)
            }
        }
        for action in [FinderAction.betterZipCompress, .betterZipExtract] where savedOrder?.contains(action.rawValue) != true {
            if !actionOrder.contains(action.rawValue) { actionOrder.append(action.rawValue) }
            enabledActions.insert(action.rawValue)
        }
        menuGroups = try values.decodeIfPresent([FinderMenuGroup].self, forKey: .menuGroups) ?? menuGroups
        actionGroups = try values.decodeIfPresent([String: UUID].self, forKey: .actionGroups) ?? actionGroups
        if let savedFavorites = try values.decodeIfPresent([FavoriteApplication].self, forKey: .favoriteApplications) {
            favoriteApplications = savedFavorites
        } else if savedActions?.contains("editor") ?? true {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            if let editor = try legacy.decodeIfPresent(String.self, forKey: .editorApp),
               let url = InstalledApplications().legacyEditorURL(named: editor),
               let identifier = InstalledApplications.identifier(at: url) {
                if let preset = FavoriteApplication.presetIdentifier(for: identifier),
                   let index = favoriteApplications.firstIndex(where: { $0.presetBundleIdentifier == preset }) {
                    favoriteApplications[index].path = url.path
                    favoriteApplications[index].enabled = true
                } else {
                    favoriteApplications.insert(FavoriteApplication(name: url.deletingPathExtension().lastPathComponent,
                                                                     path: url.path), at: 1)
                }
            }
        }
        if let directories = try values.decodeIfPresent([FavoriteDirectory].self, forKey: .favoriteDirectories) {
            let hasDefaults = try values.decodeIfPresent(Bool.self, forKey: .favoriteDirectoryDefaultsAdded) ?? false
            favoriteDirectories = hasDefaults ? directories : FavoriteDirectory.addingDefaults(to: directories)
        } else {
            enabledActions.insert(FinderAction.favoriteDirectories.rawValue)
        }
        for removed in ["editor", "zip"] {
            enabledActions.remove(removed)
            foldedActions.remove(removed)
            actionOrder.removeAll { $0 == removed }
            actionGroups.removeValue(forKey: removed)
        }
        terminalApplication = try values.decodeIfPresent(String.self, forKey: .terminalApplication)
            .flatMap(TerminalApplication.init(rawValue:)) ?? terminalApplication
        textEditor = try values.decodeIfPresent(String.self, forKey: .textEditor)
            .flatMap(TextEditorApplication.init(rawValue:)) ?? textEditor
        openCreatedFiles = try values.decodeIfPresent(Bool.self, forKey: .openCreatedFiles) ?? openCreatedFiles
        hideTemplateExtensions = try values.decodeIfPresent(Bool.self, forKey: .hideTemplateExtensions)
            ?? hideTemplateExtensions
        if let templates = try values.decodeIfPresent([FileTemplate].self, forKey: .fileTemplates) {
            let initialized = try values.decodeIfPresent(Bool.self, forKey: .fileTemplateContentsInitialized) ?? false
            fileTemplates = initialized ? templates : FileTemplate.migratingPresets(templates)
        } else {
            let oldActions = ["text", "markdown"]
            let order = actionOrder + oldActions
            var seen = Set<String>()
            let presets = fileTemplates
            let legacyTemplates = order.compactMap { action -> FileTemplate? in
                guard oldActions.contains(action), seen.insert(action).inserted,
                      var template = presets.first(where: { $0.presetExtension == (action == "text" ? "txt" : "md") })
                else { return nil }
                template.topLevel = actionOrder.contains(action) && !foldedActions.contains(action)
                template.enabled = savedActions?.contains(action) ?? true
                return template
            }
            fileTemplates = legacyTemplates + presets.filter { $0.presetExtension != "txt" && $0.presetExtension != "md" }
            actionOrder = actionOrder.map { oldActions.contains($0) ? FinderAction.newFile.rawValue : $0 }
            enabledActions.subtract(oldActions)
            enabledActions.formUnion([FinderAction.newFile.rawValue, FinderAction.favoriteApps.rawValue])
            foldedActions.subtract(oldActions)
            for action in oldActions { actionGroups.removeValue(forKey: action) }
        }
    }

    static let userHomeDirectory: URL = {
        // Finder Sync's Foundation home directory can point inside its sandbox.
        if let directory = getpwuid(getuid())?.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()
    static var desktopDirectory: URL {
        if StoreSandbox.isEnabled { return userHomeDirectory.appendingPathComponent("Desktop", isDirectory: true) }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? userHomeDirectory.appendingPathComponent("Desktop", isDirectory: true)
    }

    static func load(from url: URL? = nil, initializeIfMissing: Bool = false) throws -> Settings {
        let file = try url ?? StoreSandbox.dataDirectory().appendingPathComponent("settings.json")
        do {
            return try JSONDecoder().decode(Settings.self, from: Data(contentsOf: file))
        } catch CocoaError.fileReadNoSuchFile {
            let defaults = Settings()
            if initializeIfMissing { try defaults.save(to: url) }
            return defaults
        }
    }

    @discardableResult
    static func saveAddingFavoriteDirectories(_ directories: [URL], to url: URL? = nil) throws -> Settings {
        var settings = try load(from: url)
        let updated = FavoriteDirectory.adding(directories, to: settings.favoriteDirectories)
        if updated != settings.favoriteDirectories {
            settings.favoriteDirectories = updated
            try settings.save(to: url)
        }
        return settings
    }

    func save(to url: URL? = nil) throws {
        let file = try url ?? StoreSandbox.dataDirectory().appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: file, options: .atomic)
        if url == nil {
            DistributedNotificationCenter.default().postNotificationName(Self.didSaveNotification, object: nil,
                                                                          deliverImmediately: true)
        }
    }
}
