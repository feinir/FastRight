import AppKit
import Combine
import FinderSync
import SwiftUI

private struct PermissionStatus: Equatable {
    let finderExtension: Bool
    let finderAutomation: Bool
    let directDirectoryNavigation: Bool

    @MainActor static func check() -> Self {
        Self(finderExtension: FIFinderSyncController.isExtensionEnabled,
             finderAutomation: FinderAutomation.isAuthorized,
             directDirectoryNavigation: FinderAutomation.canChangeDirectory)
    }
}

@MainActor
private final class SettingsModel: ObservableObject {
    @Published private(set) var settings: Settings
    private let languageDidChange: (AppStrings) -> Void
    @Published var page: SettingsPage = .menus
    @Published var filter: MenuFilter = .all
    @Published var search = ""
    @Published private(set) var errorMessage = ""
    @Published private(set) var permissions = PermissionStatus.check()
    @Published private(set) var preferredLanguages = Locale.preferredLanguages
    let installedApplications = InstalledApplications()

    init(languageDidChange: @escaping (AppStrings) -> Void) {
        self.languageDidChange = languageDidChange
        do {
            settings = try Settings.load(initializeIfMissing: true)
        } catch {
            settings = Settings()
            errorMessage = settings.strings("Could not read settings: %@", error.localizedDescription)
        }
    }

    func refreshPermissions() {
        let current = PermissionStatus.check()
        if permissions != current { permissions = current }
    }

    func refreshLanguages() {
        let current = Locale.preferredLanguages
        guard current != preferredLanguages else { return }
        preferredLanguages = current
        languageDidChange(settings.strings)
    }

    func update(_ change: (inout Settings) -> Void) {
        var updated = settings
        change(&updated)
        guard updated != settings else { return }
        do {
            let changedLanguage = updated.language != settings.language
            try updated.save()
            settings = updated
            if changedLanguage { languageDidChange(updated.strings) }
            errorMessage = ""
        } catch {
            errorMessage = settings.strings("Could not save settings: %@", error.localizedDescription)
        }
    }

    func binding<Value>(for keyPath: WritableKeyPath<Settings, Value>) -> Binding<Value> {
        Binding { self.settings[keyPath: keyPath] } set: { value in
            self.update { $0[keyPath: keyPath] = value }
        }
    }

    func addFavoriteDirectories(_ directories: [URL]) throws {
        settings = try Settings.saveAddingFavoriteDirectories(directories)
        errorMessage = ""
    }
}

private enum SettingsPage: String, CaseIterable {
    case menus = "Context Menu"
    case templates = "New File"
    case applications = "Favorite Apps"
    case directories = "Favorite Folders"
    case preferences = "General"

    var symbol: String {
        switch self {
        case .menus: return "contextualmenu.and.cursorarrow"
        case .templates: return "doc.badge.plus"
        case .applications: return "square.grid.2x2"
        case .directories: return FinderAction.favoriteDirectories.symbol
        case .preferences: return "slider.horizontal.3"
        }
    }
}

private enum MenuFilter: Hashable {
    case all, group(UUID)
}

private struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @FocusState private var searchFocused: Bool

    private var strings: AppStrings {
        AppStrings(language: model.settings.language, preferences: model.preferredLanguages)
    }
    @StateObject private var drag = SettingsDrag<FinderMenuEntry>()

    private let accent = Color.accentColor

    var body: some View {
        VStack(spacing: 0) {
            navigation
            Divider()
            switch model.page {
            case .menus: menuSettings
            case .templates:
                FileTemplateSettings(
                    templates: model.binding(for: \.fileTemplates),
                    openCreatedFiles: model.binding(for: \.openCreatedFiles),
                    hideExtensions: model.binding(for: \.hideTemplateExtensions),
                    isInFastRightMenu: model.settings.isInFastRightMenu(.newFile)
                )
            case .applications:
                FavoriteApplicationSettings(applications: model.binding(for: \.favoriteApplications),
                                            isInFastRightMenu: model.settings.isInFastRightMenu(.favoriteApps))
            case .directories:
                FavoriteDirectorySettings(directories: model.binding(for: \.favoriteDirectories))
            case .preferences: generalSettings
            }
            if !model.errorMessage.isEmpty {
                Divider()
                Label(model.errorMessage, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .frame(minWidth: 675, minHeight: 470)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .environment(\.appStrings, strings)
        .environment(\.locale, strings.locale)
        .onAppear(perform: model.refreshPermissions)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshLanguages()
            model.refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
            model.refreshLanguages()
        }
    }

    private var navigation: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            Text("FastRight").font(.headline).padding(.trailing, 14)
            HStack(spacing: 4) {
                ForEach(SettingsPage.allCases, id: \.self) { page in
                    Button {
                        model.page = page
                    } label: {
                        Label(strings(page.rawValue), systemImage: page.symbol)
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                            .background {
                                if model.page == page {
                                    RoundedRectangle(cornerRadius: 6).fill(accent.opacity(0.18))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.page == page ? .isSelected : [])
                }
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var menuSettings: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Toggle(strings("Enable context menu"), isOn: model.binding(for: \.menuEnabled))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Spacer()
                    HStack(spacing: 6) {
                        Button {
                            searchFocused = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(strings("Search menus"))
                        .keyboardShortcut("f", modifiers: .command)
                        TextField(strings("Search menus"), text: $model.search)
                            .textFieldStyle(.plain)
                            .focused($searchFocused)
                            .frame(width: 125)
                        if !model.search.isEmpty {
                            Button {
                                model.search = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(strings("Clear search"))
                        }
                    }
                    .padding(7)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                }
                .padding(16)
                HStack(spacing: 10) {
                    Text(filterTitle)
                    let count = visibleMenuEntries.count
                    Text(strings(count == 1 ? "%lld item" : "%lld items", count))
                    Spacer()
                    Text(strings("Placement")).frame(width: 112, alignment: .leading)
                    Text(strings("In Submenu")).lineLimit(1).frame(width: 86)
                        .help(strings("Select to place this item in the FastRight submenu. Deselect to show it at the top level in Finder."))
                    Text(strings("Enabled")).frame(width: 44)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                Divider()
                ScrollView {
                    if visibleMenuEntries.isEmpty {
                        Text(strings(model.search.isEmpty ? "This group has no menu items" : "No matching menu items"))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(25)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(Array(visibleMenuEntries.enumerated()), id: \.element) { index, entry in
                            let alternate = !index.isMultiple(of: 2)
                            switch entry {
                            case .action(let action):
                                actionRow(action, alternate: alternate)
                            case .favoriteApplication(let id):
                                if let app = model.settings.favoriteApplications.first(where: { $0.id == id }) {
                                    favoriteApplicationRow(app, alternate: alternate)
                                }
                            }
                            Divider().padding(.leading, 48)
                        }
                    }
                }
                Divider()
                HStack {
                    Spacer()
                    Toggle(strings("Put all in submenu"), isOn: allFolded)
                        .toggleStyle(.checkbox)
                        .disabled(visibleActions.allSatisfy { model.settings.group(for: $0) != nil })
                }
                .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            sidebarButton(strings("All Menu Items"), symbol: "list.bullet", target: .all)

            Text(strings("Menu Groups"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 12)
                .padding(.leading, 8)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(model.settings.menuGroups) { group in
                        sidebarButton(group.name, symbol: "folder", target: .group(group.id))
                            .contextMenu {
                                Button(strings("Rename")) { editGroup(group) }
                                Button(strings("Remove Group"), role: .destructive) { removeGroup(group) }
                            }
                    }
                }
            }
            Button {
                editGroup(nil)
            } label: {
                Label(strings("Add Group"), systemImage: "plus")
            }
            .padding(.leading, 8)
        }
        .padding(12)
        .frame(width: 168)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func sidebarButton(_ title: String, symbol: String, target: MenuFilter) -> some View {
        Button {
            model.filter = target
            model.search = ""
        } label: {
            Label(title, systemImage: symbol)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(model.filter == target ? accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.filter == target ? .isSelected : [])
        .settingsDropTarget(target, drag: drag, fixedInsertion: .after) { entry in
            guard case .group(let id) = target, case .action(let action) = entry else { return false }
            return model.settings.group(for: action)?.id != id
        } move: { entry, _ in
            if case .group(let id) = target, case .action(let action) = entry { assign(action, to: id) }
        }
    }

    private func actionRow(_ action: FinderAction, alternate: Bool) -> some View {
        let settings = model.settings
        let group = settings.group(for: action)
        let labels = action.labels(in: strings)
        let folded = settings.foldedActions.contains(action.rawValue)
        let showIcon = (group != nil || folded) ? settings.showSubmenuIcons : settings.showMainMenuIcons
        return HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: action.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(settings.colorfulIcons ? accent : .secondary)
                    .opacity(showIcon ? 1 : 0)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(labels.title).fontWeight(.medium)
                    Text(labels.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 10)
            }
            .settingsDragSource(.action(action), title: labels.title, drag: drag)

            Menu {
                if group != nil {
                    Button(strings("Remove from Group")) { assign(action, to: nil) }
                }
                ForEach(settings.menuGroups) { group in
                    Button(group.name) { assign(action, to: group.id) }
                }
                if !settings.menuGroups.isEmpty { Divider() }
                sortButtons(for: .action(action))
            } label: {
                Text(group?.name ?? (folded ? Settings.foldedMenuTitle : strings("Top Level")))
                    .lineLimit(1)
            }
            .frame(width: 112)
            .accessibilityLabel(strings("Grouping and order for %@", labels.title))

            Toggle(strings("In Submenu"), isOn: membership(for: action, in: \.foldedActions))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: 86)
                .disabled(group != nil)
                .accessibilityLabel(strings("Put %@ in FastRight", labels.title))
            Toggle(strings("Enabled"), isOn: membership(for: action, in: \.enabledActions))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: 44)
                .accessibilityLabel(strings("Enable %@", labels.title))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(alternate ? Color(nsColor: .alternatingContentBackgroundColors[1]) : .clear)
        .contentShape(Rectangle())
        .settingsDropTarget(FinderMenuEntry.action(action), drag: drag) { source in
            visibleMenuEntries.contains(source)
        } move: { source, insertion in
            reorder(source, relativeTo: .action(action), insertion: insertion)
        }
    }

    private func favoriteApplicationRow(_ app: FavoriteApplication, alternate: Bool) -> some View {
        let entry = FinderMenuEntry.favoriteApplication(app.id)
        let name = app.displayName(in: strings)
        return HStack(spacing: 10) {
            HStack(spacing: 10) {
                Group {
                    if let url = app.installedURL(using: model.installedApplications) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: "app")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                }
                .opacity(model.settings.showMainMenuIcons ? 1 : 0)
                .frame(width: 22, height: 20)
                .accessibilityHidden(true)
                Text(name).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 10)
            }
            .settingsDragSource(entry, title: name, drag: drag)

            Menu {
                sortButtons(for: entry)
            } label: {
                Text(strings("Top Level"))
            }
            .frame(width: 112)
            .accessibilityLabel(strings("Order for %@", name))

            Spacer().frame(width: 86)
            Toggle(strings("Enable %@", name), isOn: Binding {
                model.settings.favoriteApplications.first { $0.id == app.id }?.enabled ?? false
            } set: { enabled in
                model.update { settings in
                    guard let index = settings.favoriteApplications.firstIndex(where: { $0.id == app.id }) else { return }
                    settings.favoriteApplications[index].enabled = enabled
                }
            })
            .toggleStyle(.checkbox)
            .labelsHidden()
            .frame(width: 44)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(alternate ? Color(nsColor: .alternatingContentBackgroundColors[1]) : .clear)
        .contentShape(Rectangle())
        .settingsDropTarget(entry, drag: drag) { source in
            visibleMenuEntries.contains(source)
        } move: { source, insertion in
            reorder(source, relativeTo: entry, insertion: insertion)
        }
    }

    @ViewBuilder
    private func sortButtons(for entry: FinderMenuEntry) -> some View {
        Button(strings("Move Up")) { move(entry, offset: -1) }
            .disabled(visibleMenuEntries.first == entry)
        Button(strings("Move Down")) { move(entry, offset: 1) }
            .disabled(visibleMenuEntries.last == entry)
    }

    private var generalSettings: some View {
        ScrollView {
            Form {
                Section(strings("Language")) {
                    Picker(strings("Language"), selection: model.binding(for: \.language)) {
                        ForEach(AppLanguage.allCases, id: \.self) { language in
                            Text(language.title(in: strings)).tag(language)
                        }
                    }
                }
                Section(strings("Permissions")) {
                    permissionRow(strings("Finder Extension"), detail: strings("Show FastRight in the Finder context menu"),
                                  ready: model.permissions.finderExtension,
                                  readyLabel: "On", missingLabel: "Disabled", button: strings("Open Extension Settings")) {
                        FIFinderSyncController.showExtensionManagementInterface()
                    }
                    permissionRow(strings("Accessibility"), detail: strings("Use ⌘X to cut, paste files, and rename new items in Finder"),
                                  ready: model.permissions.finderAutomation, button: strings("Grant Accessibility Access")) {
                        FinderAutomation.requestAccess()
                    }
                    permissionRow(strings("Finder Automation"), detail: strings("Open favorite folders in the current Finder window"),
                                  ready: model.permissions.directDirectoryNavigation, button: strings("Allow Finder Control")) {
                        FinderAutomation.requestNavigationAccess()
                        model.refreshPermissions()
                    }
                }
                Section(strings("Context Menu")) {
                    Toggle(strings("Enable context menu"), isOn: model.binding(for: \.menuEnabled))
                    Toggle(strings("Enable on external and network drives"), isOn: model.binding(for: \.externalVolumes))
                }
                Section(strings("Menu Bar")) {
                    Toggle(strings("Show icon in menu bar"), isOn: model.binding(for: \.showMenuBarIcon))
                }
                Section(strings("FastRight Menu")) {
                    Picker(strings("FastRight menu position"), selection: model.binding(for: \.foldedMenuPosition)) {
                        Text(strings("First")).tag(FoldedMenuPosition.first)
                        Text(strings("Last")).tag(FoldedMenuPosition.last)
                    }
                    .pickerStyle(.segmented)
                }
                Section(strings("Menu Appearance")) {
                    Toggle(strings("Show top-level menu icons"), isOn: model.binding(for: \.showMainMenuIcons))
                    Toggle(strings("Show submenu icons"), isOn: model.binding(for: \.showSubmenuIcons))
                    Toggle(strings("Show the FastRight menu icon"), isOn: model.binding(for: \.showFoldedMenuIcon))
                    Toggle(strings("Use colorful icons"), isOn: model.binding(for: \.colorfulIcons))
                }
                Section(strings("File Operations")) {
                    Toggle(strings("Include extensions when copying names"), isOn: model.binding(for: \.copyNameExtensions))
                    Picker(strings("Default text editor"), selection: model.binding(for: \.textEditor)) {
                        ForEach(TextEditorApplication.allCases, id: \.self) { editor in
                            Text(editor.title(in: strings)).tag(editor)
                        }
                    }
                    Picker(strings("Terminal app"), selection: model.binding(for: \.terminalApplication)) {
                        ForEach(TerminalApplication.allCases, id: \.self) { terminal in
                            Text(terminal.title(in: strings)).tag(terminal)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 670)
            .frame(maxWidth: .infinity)
        }
        .onAppear(perform: model.refreshPermissions)
    }

    private func permissionRow(_ title: String, detail: String, ready: Bool,
                               readyLabel: String = "Allowed", missingLabel: String = "Not allowed",
                               button: String, request: @escaping () -> Void) -> some View {
        LabeledContent {
            HStack(spacing: 12) {
                Label(strings(ready ? readyLabel : missingLabel),
                      systemImage: ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(nsColor: ready ? .systemGreen : .systemOrange))
                if !ready {
                    Button(button) {
                        request()
                        model.refreshPermissions()
                    }
                }
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }

    private var visibleMenuEntries: [FinderMenuEntry] {
        let query = model.search.trimmingCharacters(in: .whitespacesAndNewlines)
        let settings = model.settings
        return settings.orderedMenuEntries.filter { entry in
            switch entry {
            case .action(let action):
                if case .group(let id) = model.filter, settings.group(for: action)?.id != id { return false }
                let labels = action.labels(in: strings)
                return query.isEmpty || labels.title.localizedCaseInsensitiveContains(query)
                    || labels.detail.localizedCaseInsensitiveContains(query)
            case .favoriteApplication(let id):
                guard model.filter == .all, !settings.isInFastRightMenu(.favoriteApps),
                      let app = settings.favoriteApplications.first(where: { $0.id == id }), app.topLevel
                else { return false }
                return query.isEmpty || app.displayName(in: strings).localizedCaseInsensitiveContains(query)
            }
        }
    }

    private var visibleActions: [FinderAction] {
        visibleMenuEntries.compactMap { entry in
            guard case .action(let action) = entry else { return nil }
            return action
        }
    }

    private var filterTitle: String {
        if !model.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return strings("Search Results") }
        switch model.filter {
        case .all: return strings("All Menu Items")
        case .group(let id): return model.settings.menuGroups.first { $0.id == id }?.name ?? strings("Menu Groups")
        }
    }

    private var allFolded: Binding<Bool> {
        Binding {
            visibleActions
                .filter { model.settings.group(for: $0) == nil }
                .allSatisfy { model.settings.foldedActions.contains($0.rawValue) }
        } set: { value in
            let actions = visibleActions.filter { model.settings.group(for: $0) == nil }.map(\.rawValue)
            model.update {
                if value { $0.foldedActions.formUnion(actions) }
                else { $0.foldedActions.subtract(actions) }
            }
        }
    }

    private func membership(for action: FinderAction, in keyPath: WritableKeyPath<Settings, Set<String>>) -> Binding<Bool> {
        Binding { model.settings[keyPath: keyPath].contains(action.rawValue) } set: { value in
            model.update {
                if value { $0[keyPath: keyPath].insert(action.rawValue) }
                else { $0[keyPath: keyPath].remove(action.rawValue) }
            }
        }
    }

    private func move(_ entry: FinderMenuEntry, offset: Int) {
        let entries = visibleMenuEntries
        guard let index = entries.firstIndex(of: entry), entries.indices.contains(index + offset) else { return }
        reorder(entry, relativeTo: entries[index + offset], insertion: offset < 0 ? .before : .after)
    }

    private func reorder(_ source: FinderMenuEntry, relativeTo target: FinderMenuEntry, insertion: RowInsertion) {
        let entries = visibleMenuEntries
        var reordered = entries
        insertion.move(source, relativeTo: target, in: &reordered)
        guard reordered != entries else { return }
        model.update { settings in
            var order = settings.orderedMenuEntries
            insertion.move(source, relativeTo: target, in: &order)
            settings.actionOrder = order.map(\.orderKey)
        }
    }

    private func editGroup(_ group: FinderMenuGroup?) {
        let field = NSTextField(string: group?.name ?? "")
        field.placeholderString = strings("Group name")
        field.sizeToFit()
        field.frame.size.width = 220

        let alert = NSAlert()
        alert.messageText = group == nil ? strings("New Menu Group") : strings("Rename Group")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: strings("OK"))
        alert.addButton(withTitle: strings("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let id = group?.id ?? UUID()
        model.update { settings in
            if let index = settings.menuGroups.firstIndex(where: { $0.id == id }) {
                settings.menuGroups[index].name = name
            } else {
                settings.menuGroups.append(FinderMenuGroup(id: id, name: name))
            }
        }
        if model.settings.menuGroups.contains(where: { $0.id == id }) {
            model.filter = .group(id)
            model.search = ""
        }
    }

    private func removeGroup(_ group: FinderMenuGroup) {
        model.update { settings in
            settings.menuGroups.removeAll { $0.id == group.id }
            settings.actionGroups = settings.actionGroups.filter { $0.value != group.id }
        }
        if !model.settings.menuGroups.contains(where: { $0.id == group.id }), model.filter == .group(group.id) {
            model.filter = .all
        }
    }

    private func assign(_ action: FinderAction, to group: UUID?) {
        model.update { $0.actionGroups[action.rawValue] = group }
    }

}

@main
@MainActor
private final class FastRightApplication: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var settingsModel: SettingsModel?
    private let screenshotURL: URL?
    private var launched = false
    private var launchedForFinder = false
    private var pendingSettingsWindow = false
    private var mainMenuLanguage: AppLanguage?
    private let cutShortcut = FinderCutShortcut()
    private lazy var statusItem = FastRightStatusItem(
        openPreferences: { [weak self] in self?.openSettingsWindow() },
        sendRequest: { [weak self] request, _ in
            guard let self else { throw FileActionError.launchFailed }
            if request.action == .addFavoriteDirectory {
                try self.saveFavoriteDirectories([URL(fileURLWithPath: request.path, isDirectory: true)])
            } else {
                self.performFinderRequest(request, fromMenuBar: true)
            }
        }
    )
    private var pendingRequest: FinderRequest?
    private var pendingFavoriteDirectories: [URL] = []
    private var finderTask: Task<Void, Never>?

    init(screenshotURL: URL?) {
        self.screenshotURL = screenshotURL
        super.init()
    }

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let path = arguments.drop(while: { $0 != "--screenshot" }).dropFirst().first
        let delegate = FastRightApplication(screenshotURL: path.map { URL(fileURLWithPath: $0) })
        let app = NSApplication.shared
        app.setActivationPolicy(path == nil ? .regular : .accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launched = true
        if screenshotURL == nil {
            installMainMenu(strings: .current)
            cutShortcut.start()
            statusItem.start()
        }
        if launchedForFinder {
            NSApplication.shared.setActivationPolicy(.accessory)
            handleFinderRequests()
        } else {
            showSettings()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let requests = urls.compactMap(FinderRequest.takeRequest(at:))
        guard !requests.isEmpty else { return }
        launchedForFinder = true
        for request in requests {
            switch request.action {
            case .startCutShortcut: break
            case .openPreferences:
                pendingSettingsWindow = true
            case .addFavoriteDirectory:
                pendingFavoriteDirectories.append(URL(fileURLWithPath: request.path, isDirectory: true))
            default: pendingRequest = request
            }
        }
        if launched { handleFinderRequests() }
    }

    private func handleFinderRequests() {
        if pendingSettingsWindow {
            pendingSettingsWindow = false
            openSettingsWindow()
        }
        let directories = pendingFavoriteDirectories
        pendingFavoriteDirectories.removeAll()
        if !directories.isEmpty {
            do {
                try saveFavoriteDirectories(directories)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        if let request = pendingRequest {
            pendingRequest = nil
            performFinderRequest(request)
        }
    }

    private func saveFavoriteDirectories(_ directories: [URL]) throws {
        if let settingsModel { try settingsModel.addFavoriteDirectories(directories) }
        else { try Settings.saveAddingFavoriteDirectories(directories) }
    }

    private func performFinderRequest(_ request: FinderRequest, fromMenuBar: Bool = false) {
        if window == nil { NSApplication.shared.setActivationPolicy(.accessory) }
        finderTask?.cancel()
        finderTask = Task { [weak self] in
            do {
                switch request.action {
                case .renameCreatedItem:
                    await CreatedItemRename(action: request).perform()
                case .goToDirectory:
                    let directory = URL(fileURLWithPath: request.path, isDirectory: true)
                    if fromMenuBar { try await FinderAutomation.openFavoriteFromMenuBar(directory) }
                    else { try FinderAutomation.goToDirectory(directory) }
                case .pasteFiles:
                    if fromMenuBar, FinderAutomation.isAuthorized { try await FinderAutomation.activateFinder() }
                    try await FinderAutomation.pasteFiles(into: URL(fileURLWithPath: request.path, isDirectory: true),
                                                          clipboardChangeCount: request.clipboardChangeCount)
                case .startCutShortcut, .addFavoriteDirectory, .openPreferences:
                    break
                }
            } catch {
                if !Task.isCancelled {
                    let alert = NSAlert(error: error)
                    alert.runModal()
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.finderTask = nil
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard screenshotURL == nil else { return }
        installMainMenu(strings: settingsModel?.settings.strings ?? .current)
    }

    private func showSettings() {
        if screenshotURL == nil { NSApplication.shared.setActivationPolicy(.regular) }
        let model = SettingsModel { [weak self] strings in
            self?.installMainMenu(strings: strings)
        }
        settingsModel = model
        let content = NSHostingView(rootView: SettingsView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 790, height: 630),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "FastRight"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: 675, height: 470)
        window.contentView = content
        window.center()
        self.window = window

        if let screenshotURL {
            window.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) {
                self.capture(content, to: screenshotURL)
            }
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        cutShortcut.stop()
        if screenshotURL == nil { statusItem.stop() }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow, closed === window else { return }
        window = nil
        settingsModel = nil
        DispatchQueue.main.async { [weak self] in
            if self?.window == nil { NSApplication.shared.setActivationPolicy(.accessory) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettingsWindow()
        return true
    }

    private func openSettingsWindow() {
        if window == nil { showSettings() }
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func capture(_ view: NSView, to url: URL) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let scale = view.window?.backingScaleFactor ?? 1
        if let layer = view.layer,
           let bitmap = NSBitmapImageRep(
               bitmapDataPlanes: nil,
               pixelsWide: Int(view.bounds.width * scale),
               pixelsHigh: Int(view.bounds.height * scale),
               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
           ), let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext {
            if view.isFlipped {
                context.translateBy(x: 0, y: CGFloat(bitmap.pixelsHigh))
            }
            context.scaleBy(x: scale, y: view.isFlipped ? -scale : scale)
            layer.render(in: context)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                do {
                    try png.write(to: url, options: .atomic)
                    NSApplication.shared.terminate(nil)
                    return
                } catch {
                    fputs("Could not save \(url.path): \(error.localizedDescription)\n", stderr)
                    exit(EXIT_FAILURE)
                }
            }
        }
        fputs("Could not capture the FastRight settings window.\n", stderr)
        exit(EXIT_FAILURE)
    }

    private func installMainMenu(strings: AppStrings) {
        guard mainMenuLanguage != strings.language else { return }
        mainMenuLanguage = strings.language
        let main = NSMenu()
        let appMenu = NSMenu(title: "FastRight")
        appMenu.addItem(withTitle: strings("About FastRight"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: strings("Quit FastRight"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let edit = NSMenu(title: strings("Edit"))
        edit.addItem(withTitle: strings("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: strings("Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: strings("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: strings("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: strings("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: strings("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windows = NSMenu(title: strings("Window"))
        windows.addItem(withTitle: strings("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windows.addItem(withTitle: strings("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")

        for submenu in [appMenu, edit, windows] {
            let item = NSMenuItem()
            item.submenu = submenu
            main.addItem(item)
        }
        NSApplication.shared.mainMenu = main
        NSApplication.shared.windowsMenu = windows
    }
}
