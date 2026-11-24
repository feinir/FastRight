import AppKit
import ApplicationServices
import Carbon

@MainActor
struct CreatedItemRename {
    let url: URL
    let openAfterRename: Bool
    let application: URL?

    init(action: FinderRequest) {
        url = URL(fileURLWithPath: action.path)
        openAfterRename = action.openAfterRename
        application = action.applicationPath.map { URL(fileURLWithPath: $0) }
    }

    func perform() async {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let reference = openAfterRename ? (url as NSURL).fileReferenceURL() : nil
        NSWorkspace.shared.activateFileViewerSelecting([url])
        let finder = !StoreSandbox.isEnabled && FinderAutomation.isAuthorized ? await beginFinderRename() : nil
        if let reference, !Task.isCancelled {
            await openWhenNamingFinishes(reference: reference, finder: finder)
        }
    }

    private func beginFinderRename() async -> AXUIElement? {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
        else { return nil }
        let pid = finder.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        let expectedPath = url.resolvingSymlinksInPath().path
        let deadline = ContinuousClock.now + .seconds(2)
        while !Task.isCancelled, ContinuousClock.now < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
               let window: AXUIElement = FinderAutomation.value(app, kAXFocusedWindowAttribute),
               hasSelectedItem(in: window, path: expectedPath, depth: 8),
               FinderAutomation.postKey(kVK_Return, to: pid) {
                return app
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        return nil
    }

    private func openWhenNamingFinishes(reference: URL, finder: AXUIElement?) async {
        let original = url.resolvingSymlinksInPath().standardizedFileURL
        let folder = original.deletingLastPathComponent().path
        let filename = url.lastPathComponent
        let stem = (filename as NSString).deletingPathExtension
        var editor: AXUIElement?
        let deadline = ContinuousClock.now + .seconds(120)
        while !Task.isCancelled, ContinuousClock.now < deadline {
            guard let current = (reference as NSURL).filePathURL?.resolvingSymlinksInPath().standardizedFileURL,
                  current.deletingLastPathComponent().path == folder else { return }
            if current.path != original.path {
                await open(current)
                return
            }
            if let finder {
                let focused: AXUIElement? = FinderAutomation.value(finder, kAXFocusedUIElementAttribute)
                if let editor {
                    if let focused, !CFEqual(focused, editor),
                       NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" {
                        await open(current)
                        return
                    }
                } else if let focused,
                          FinderAutomation.value(focused, kAXRoleAttribute) as String? == kAXTextFieldRole,
                          let selected: String = FinderAutomation.value(focused, kAXSelectedTextAttribute),
                          !selected.isEmpty, selected == stem || selected == filename {
                    editor = focused
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func hasSelectedItem(in element: AXUIElement, path: String, depth: Int) -> Bool {
        guard depth > 0 else { return false }
        for attribute in [kAXSelectedChildrenAttribute, kAXSelectedRowsAttribute] {
            if let selection: [AXUIElement] = FinderAutomation.value(element, attribute), selection.count == 1,
               containsURL(in: selection[0], path: path, depth: 4) {
                return true
            }
        }
        let containers = [kAXWindowRole, kAXSplitGroupRole, kAXGroupRole, kAXScrollAreaRole,
                          kAXBrowserRole, kAXListRole, kAXOutlineRole, kAXTableRole, kAXLayoutAreaRole]
        guard let role: String = FinderAutomation.value(element, kAXRoleAttribute), containers.contains(role),
              let children: [AXUIElement] = FinderAutomation.value(element, kAXChildrenAttribute) else { return false }
        return children.contains { hasSelectedItem(in: $0, path: path, depth: depth - 1) }
    }

    private func containsURL(in element: AXUIElement, path: String, depth: Int) -> Bool {
        guard depth > 0 else { return false }
        if let itemURL: URL = FinderAutomation.value(element, kAXURLAttribute) {
            return itemURL.resolvingSymlinksInPath().path == path
        }
        let children: [AXUIElement] = FinderAutomation.value(element, kAXChildrenAttribute) ?? []
        return children.contains { containsURL(in: $0, path: path, depth: depth - 1) }
    }

    private func open(_ item: URL) async {
        if let application {
            _ = try? await NSWorkspace.shared.open([item], withApplicationAt: application, configuration: .init())
        } else {
            NSWorkspace.shared.open(item)
        }
    }
}
