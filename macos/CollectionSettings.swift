import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

private struct AppStringsKey: EnvironmentKey {
    static let defaultValue = AppStrings()
}

extension EnvironmentValues {
    var appStrings: AppStrings {
        get { self[AppStringsKey.self] }
        set { self[AppStringsKey.self] = newValue }
    }
}

private final class EditingValue<Value>: ObservableObject {
    @Published var value: Value

    init(_ value: Value) { self.value = value }
}

struct FileTemplateSettings: View {
    @Environment(\.appStrings) private var strings
    @Binding var templates: [FileTemplate]
    @Binding var openCreatedFiles: Bool
    @Binding var hideExtensions: Bool
    let isInFastRightMenu: Bool
    @StateObject private var draft = EditingValue<FileTemplate?>(nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 20) {
                Toggle(strings("Open files after naming"), isOn: $openCreatedFiles)
                Toggle(strings("Hide extensions in menus"), isOn: $hideExtensions)
            }
            .toggleStyle(.checkbox)
            CollectionSettingsList(
                entries: $templates, title: strings("File Templates"), emptyMessage: strings("Add a blank file or use an existing file as a template"),
                name: { $0.displayName(in: strings) }, topLevel: \.topLevel, enabled: \.enabled,
                isInFastRightMenu: isInFastRightMenu,
                add: { draft.value = FileTemplate(name: strings("Untitled") + ".txt") }, edit: { draft.value = $0 }
            ) { template in
                let displayName = template.displayName(in: strings)
                let presetTitle = template.presetTitle(in: strings)
                Image(systemName: template.sourcePath == nil ? "doc" : "doc.on.doc")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(presetTitle ?? displayName).lineLimit(1)
                    Text(presetTitle != nil ? displayName
                         : template.sourcePath.map { URL(fileURLWithPath: $0).lastPathComponent }
                            ?? (template.textContent == nil ? strings("Blank file") : strings("Text template")))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(18)
        .sheet(item: $draft.value) { value in
            let displayed = value.localized(in: strings)
            FileTemplateEditor(template: displayed) { changes in
                var updated = changes
                if updated.name == displayed.name { updated.name = value.name }
                if updated.textContent == displayed.textContent { updated.textContent = value.textContent }
                if let index = templates.firstIndex(where: { $0.id == updated.id }) {
                    templates[index] = updated
                } else {
                    templates.append(updated)
                }
            }
        }
    }
}

struct FavoriteApplicationSettings: View {
    @Environment(\.appStrings) private var strings
    @Binding var applications: [FavoriteApplication]
    let isInFastRightMenu: Bool
    @StateObject private var draft = EditingValue<FavoriteApplication?>(nil)
    @StateObject private var installedURLs = EditingValue<[UUID: URL]>([:])

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(strings("Select Top Level, then drag the app or Favorite Apps in Context Menu to reorder it."))
                .foregroundStyle(.secondary)
            applicationList
        }
        .padding(18)
        .onAppear(perform: refreshAvailability)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAvailability()
        }
        .sheet(item: $draft.value) { value in
            let name = value.displayName(in: strings)
            FavoriteApplicationEditor(application: value, displayName: name,
                                      installedPath: installedURLs.value[value.id]?.path ?? value.path) { changes in
                var updated = changes
                if updated.name == name { updated.name = value.name }
                if let index = applications.firstIndex(where: { $0.id == updated.id }) {
                    applications[index] = updated
                }
            }
        }
    }

    private var applicationList: some View {
        CollectionSettingsList(
            entries: $applications, title: strings("App Name"), emptyMessage: strings("Add apps to use in Finder"),
            name: { $0.displayName(in: strings) }, topLevel: \.topLevel, enabled: \.enabled,
            isInFastRightMenu: isInFastRightMenu,
            isAvailable: { installedURLs.value[$0.id] != nil },
            add: addApplications, edit: { draft.value = $0 }
        ) { app in
            let url = installedURLs.value[app.id]
            Group {
                if let url {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
                } else {
                    Image(systemName: "app").foregroundStyle(.secondary)
                }
            }
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.displayName(in: strings)).lineLimit(1)
                Text(url?.path ?? strings("Not installed")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func refreshAvailability() {
        let lookup = InstalledApplications()
        installedURLs.value = Dictionary(uniqueKeysWithValues: applications.compactMap { app in
            app.installedURL(using: lookup).map { (app.id, $0) }
        })
    }

    private func addApplications() {
        let panel = NSOpenPanel()
        panel.prompt = strings("Choose")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK else { return }
        var updated = applications
        for choice in panel.urls {
            let url = choice.standardizedFileURL
            guard let identifier = InstalledApplications.identifier(at: url) else { continue }
            let presetIdentifier = FavoriteApplication.presetIdentifier(for: identifier)
            if let index = updated.firstIndex(where: {
                $0.path == url.path || (presetIdentifier != nil && $0.presetBundleIdentifier == presetIdentifier)
            }) {
                updated[index].path = url.path
                updated[index].enabled = true
            } else {
                updated.append(FavoriteApplication(name: url.deletingPathExtension().lastPathComponent, path: url.path))
            }
        }
        applications = updated
        refreshAvailability()
    }
}

struct FavoriteDirectorySettings: View {
    @Environment(\.appStrings) private var strings
    @Binding var directories: [FavoriteDirectory]
    @StateObject private var draft = EditingValue<FavoriteDirectory?>(nil)

    var body: some View {
        CollectionSettingsList(
            entries: $directories, title: strings("Folder Name"), emptyMessage: strings("Add folders to open from the Finder context menu"),
            name: { $0.displayName(in: strings) }, enabled: \.enabled,
            add: addDirectories, edit: { draft.value = $0 }
        ) { directory in
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(directory.displayName(in: strings)).lineLimit(1)
                Text(directory.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(18)
        .sheet(item: $draft.value) { directory in
            let name = directory.localizedName(in: strings)
            FavoriteDirectoryEditor(directory: directory, displayName: name) { changes in
                var updated = changes
                if updated.name == name { updated.name = directory.name }
                if let index = directories.firstIndex(where: { $0.id == updated.id }) {
                    directories[index] = updated
                }
            }
        }
    }

    private func addDirectories() {
        let urls = chooseDirectories(prompt: strings("Choose"), allowsMultiple: true)
        guard !urls.isEmpty else { return }
        directories = FavoriteDirectory.adding(urls, to: directories)
    }
}

private struct FavoriteDirectoryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appStrings) private var strings
    @StateObject private var draft: EditingValue<FavoriteDirectory>
    let save: (FavoriteDirectory) -> Void

    init(directory: FavoriteDirectory, displayName: String, save: @escaping (FavoriteDirectory) -> Void) {
        var initial = directory
        initial.name = displayName
        _draft = StateObject(wrappedValue: EditingValue(initial))
        self.save = save
    }

    var body: some View {
        let name = draft.value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 14) {
            Text(strings("Favorite Folders")).font(.headline)
            TextField(strings("Menu name (optional)"), text: $draft.value.name)
            HStack {
                Text(draft.value.path)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
                Spacer()
                Button(strings("Choose Folder")) {
                    if let url = chooseDirectories(prompt: strings("Choose"),
                                                   startingAt: draft.value.url.deletingLastPathComponent()).first {
                        draft.value.path = url.path
                    }
                }
            }
            HStack {
                Spacer()
                Button(strings("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(strings("Save")) {
                    var updated = draft.value
                    updated.name = name
                    save(updated)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

private func chooseDirectories(prompt: String, allowsMultiple: Bool = false, startingAt: URL? = nil) -> [URL] {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = allowsMultiple
    panel.directoryURL = startingAt
    panel.prompt = prompt
    return panel.runModal() == .OK ? panel.urls.map(\.standardizedFileURL) : []
}

private struct CollectionSettingsList<Item: Identifiable & Equatable, RowLabel: View>: View where Item.ID == UUID {
    @Environment(\.appStrings) private var strings
    @Binding var entries: [Item]
    let title: String
    let emptyMessage: String
    let name: (Item) -> String
    var topLevel: WritableKeyPath<Item, Bool>? = nil
    let enabled: WritableKeyPath<Item, Bool>
    var isInFastRightMenu = false
    var isAvailable: (Item) -> Bool = { _ in true }
    let add: () -> Void
    let edit: (Item) -> Void
    @ViewBuilder let rowLabel: (Item) -> RowLabel
    @StateObject private var selection = EditingValue<UUID?>(nil)
    @StateObject private var drag = SettingsDrag<UUID>()

    private var selectedIndex: Int? { entries.firstIndex { $0.id == selection.value } }
    private var selectedItem: Item? { selectedIndex.map { entries[$0] } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text(title)
                    Spacer()
                    if topLevel != nil { Text(strings("Top Level")).frame(width: 84) }
                    Text(strings("Enabled")).frame(width: 50)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(12)
                Divider()
                if entries.isEmpty {
                    VStack(spacing: 12) {
                        Text(emptyMessage).foregroundStyle(.secondary)
                        Button(strings("Add"), action: add)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, item in
                                row(item, alternate: !index.isMultiple(of: 2))
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary))
            .clipShape(RoundedRectangle(cornerRadius: 7))

            HStack(spacing: 8) {
                Button(action: add) { Label(strings("Add"), systemImage: "plus") }
                Button {
                    guard let index = selectedIndex else { return }
                    edit(entries[index])
                } label: { Label(strings("Edit"), systemImage: "pencil") }
                .disabled(selectedItem.map(isAvailable) != true)
                Button {
                    guard let index = selectedIndex else { return }
                    entries.remove(at: index)
                    selection.value = nil
                } label: { Label(strings("Remove"), systemImage: "minus") }
                .disabled(selectedIndex == nil)
                Spacer()
                Text(strings("Drag items to change their order"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ item: Item, alternate: Bool) -> some View {
        let available = isAvailable(item)
        return HStack(spacing: 12) {
            HStack(spacing: 10) {
                rowLabel(item)
                Spacer(minLength: 0)
            }
            .foregroundStyle(available ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityAddTraits(selection.value == item.id ? .isSelected : [])
            .accessibilityAction(named: Text(strings("Select"))) { selection.value = item.id }
            .accessibilityAction(named: Text(strings("Edit"))) { selectAndEdit(item) }
            .settingsDragSource(item.id, title: name(item), drag: drag,
                                select: { selection.value = item.id },
                                edit: { selectAndEdit(item) }, canEdit: available)

            if let topLevel {
                Toggle(strings("Top level: %@", name(item)), isOn: available ? field(topLevel, for: item) : .constant(false))
                    .frame(width: 84)
                    .help(strings(isInFastRightMenu ? "This menu is in the FastRight submenu"
                                                 : "Show directly in the Finder context menu"))
                    .disabled(!available || isInFastRightMenu)
            }
            Toggle(strings("Enable: %@", name(item)), isOn: available ? field(enabled, for: item) : .constant(false))
                .frame(width: 50)
                .disabled(!available)
        }
        .toggleStyle(.checkbox)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background {
            if selection.value == item.id {
                Color.accentColor.opacity(0.18)
            } else if alternate {
                Color(nsColor: .alternatingContentBackgroundColors[1])
            }
        }
        .contentShape(Rectangle())
        .settingsDropTarget(item.id, drag: drag) { id in
            entries.contains { $0.id == id }
        } move: { id, insertion in
            guard let source = entries.first(where: { $0.id == id }),
                  let target = entries.first(where: { $0.id == item.id }) else { return }
            move(source, relativeTo: target, insertion: insertion)
        }
    }

    private func selectAndEdit(_ item: Item) {
        selection.value = item.id
        guard isAvailable(item) else { return }
        edit(item)
    }

    private func field(_ keyPath: WritableKeyPath<Item, Bool>, for item: Item) -> Binding<Bool> {
        Binding {
            entries.first(where: { $0.id == item.id })?[keyPath: keyPath] ?? item[keyPath: keyPath]
        } set: { value in
            guard let index = entries.firstIndex(where: { $0.id == item.id }) else { return }
            entries[index][keyPath: keyPath] = value
        }
    }

    private func move(_ source: Item, relativeTo target: Item, insertion: RowInsertion) {
        var ordered = entries
        insertion.move(source, relativeTo: target, in: &ordered)
        if ordered != entries { entries = ordered }
    }
}

private struct FileTemplateEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appStrings) private var strings
    @StateObject private var draft: EditingValue<FileTemplate>
    let save: (FileTemplate) -> Void

    init(template: FileTemplate, save: @escaping (FileTemplate) -> Void) {
        _draft = StateObject(wrappedValue: EditingValue(template))
        self.save = save
    }

    private var template: FileTemplate { draft.value }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(strings("File Templates")).font(.headline)
            TextField(strings("New file name"), text: $draft.value.name)
            HStack {
                Text(template.sourcePath ?? strings("Enter text")).lineLimit(1).truncationMode(.middle)
                Spacer()
                if template.sourcePath != nil {
                    Button(strings("Enter text")) { draft.value.sourcePath = nil }
                }
                Button(strings("Choose Template File"), action: selectSource)
            }
            if template.sourcePath == nil {
                TextEditor(text: Binding {
                    draft.value.textContent ?? ""
                } set: { text in
                    draft.value.textContent = text.isEmpty ? nil : text
                })
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 130)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
                .accessibilityLabel(strings("Template content"))
            }
            HStack {
                Text(template.applicationPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? strings("Use default app"))
                Spacer()
                if template.applicationPath != nil {
                    Button(strings("Use default app")) { draft.value.applicationPath = nil }
                }
                Button(strings("Choose App"), action: selectApplication)
            }
            HStack {
                Spacer()
                Button(strings("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(strings("Save")) {
                    var updated = template
                    updated.name = trimmedName
                    save(updated)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!FileTemplate.isValidName(trimmedName))
            }
        }
        .padding(22)
        .frame(width: 490)
    }

    private var trimmedName: String { template.name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func selectSource() {
        let panel = NSOpenPanel()
        panel.prompt = strings("Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.value.name = url.lastPathComponent
        draft.value.sourcePath = url.path
    }

    private func selectApplication() {
        let panel = NSOpenPanel()
        panel.prompt = strings("Choose")
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if panel.runModal() == .OK { draft.value.applicationPath = panel.url?.path }
    }
}

private struct FavoriteApplicationEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appStrings) private var strings
    @StateObject private var draft: EditingValue<FavoriteApplication>
    let installedPath: String
    let save: (FavoriteApplication) -> Void

    init(application: FavoriteApplication, displayName: String, installedPath: String,
         save: @escaping (FavoriteApplication) -> Void) {
        var initial = application
        initial.name = displayName
        _draft = StateObject(wrappedValue: EditingValue(initial))
        self.installedPath = installedPath
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(strings("Favorite App")).font(.headline)
            TextField(strings("Menu name"), text: $draft.value.name)
            Text(installedPath).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(strings("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(strings("Save")) {
                    var updated = draft.value
                    updated.name = name
                    save(updated)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 420)
    }

    private var name: String { draft.value.name.trimmingCharacters(in: .whitespacesAndNewlines) }
}
