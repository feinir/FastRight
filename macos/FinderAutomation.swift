import AppKit
import ApplicationServices
import Carbon

@MainActor
enum FinderAutomation {
    static var isAuthorized: Bool { AXIsProcessTrusted() && CGPreflightPostEventAccess() }
    static var canChangeDirectory: Bool { navigationPermission(prompt: false) == noErr }

    private static let finderID = "com.apple.finder"
    private static let navigateScript = NSAppleScript(source: """
        on navigateTo(directoryPath)
            set destination to POSIX file directoryPath as alias
            tell application id "com.apple.finder"
                if not frontmost then error number -128
                if not (exists front Finder window) then error number -1728
                set target of front Finder window to destination
            end tell
        end navigateTo
        """)

    static func requestAccess() {
        let option = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if AXIsProcessTrustedWithOptions([option: true] as CFDictionary), !CGPreflightPostEventAccess() {
            CGRequestPostEventAccess()
        }
    }

    static func requestNavigationAccess() {
        if navigationPermission(prompt: true) != noErr,
           let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func navigationPermission(prompt: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: finderID)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(kAECoreSuite),
                                                      AEEventID(kAESetData), prompt)
    }

    static func goToDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw NavigationError.missingDirectory }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == finderID else { throw NavigationError.missingWindow }

        guard navigationPermission(prompt: true) == noErr else { throw NavigationError.automationAuthorization }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite),
                                           eventID: AEEventID(kASSubroutineEvent), targetDescriptor: nil,
                                           returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(NSAppleEventDescriptor(string: url.path), at: 1)
        event.setParam(NSAppleEventDescriptor(string: "navigateto"), forKeyword: AEKeyword(keyASSubroutineName))
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))
        var details: NSDictionary?
        navigateScript?.executeAppleEvent(event, error: &details)
        if let code = details?[NSAppleScript.errorNumber] as? Int {
            switch code {
            case Int(errAEEventNotPermitted): throw NavigationError.automationAuthorization
            case -1728: throw NavigationError.missingWindow
            case -128: throw NavigationError.interrupted
            default: throw NavigationError.unavailable
            }
        }
        if navigateScript == nil || details != nil { throw NavigationError.unavailable }
    }

    static func activateFinder() async throws {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == finderID { return }
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: finderID).first
        else { throw NavigationError.missingWindow }
        if #available(macOS 14.0, *) { NSApplication.shared.yieldActivation(to: finder) }
        finder.activate(options: [])
        let deadline = ContinuousClock.now + .seconds(1)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != finder.processIdentifier {
            guard ContinuousClock.now < deadline else { throw NavigationError.interrupted }
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    static func openFavoriteFromMenuBar(_ url: URL) async throws {
        try await activateFinder()
        do {
            try goToDirectory(url)
        } catch NavigationError.missingWindow {
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == finderID,
                  NSWorkspace.shared.open(url) else { throw NavigationError.missingWindow }
        }
    }

    static func value<Value>(_ element: AXUIElement, _ attribute: String) -> Value? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result as? Value
    }

    @discardableResult
    static func postKey(_ key: Int, flags: CGEventFlags = [], to pid: pid_t) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: false) else { return false }
        down.flags = flags
        up.flags = flags
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }

    static func pasteFiles(into folder: URL, clipboardChangeCount: Int?) async throws {
        guard isAuthorized else { throw PasteError.authorization }
        let clipboard = NSPasteboard.general
        guard clipboard.changeCount == clipboardChangeCount, FinderClipboard.containsFiles(clipboard) else {
            throw PasteError.clipboardChanged
        }
        guard let finder = NSWorkspace.shared.frontmostApplication, finder.bundleIdentifier == "com.apple.finder"
        else { throw PasteError.interrupted }
        let pid = finder.processIdentifier
        let axFinder = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axFinder, 0.15)
        let window: AXUIElement? = value(axFinder, kAXFocusedWindowAttribute)
        if let window {
            guard value(window, kAXSubroleAttribute) as String? == kAXStandardWindowSubrole,
                  sheets(in: window).isEmpty else { throw PasteError.interrupted }
            if !isShowingFolder(folder, in: window) {
                try await locatePasteDestination(folder)
            }
            guard let focused: AXUIElement = value(axFinder, kAXFocusedWindowAttribute), CFEqual(window, focused),
                  sheets(in: focused).isEmpty else { throw PasteError.interrupted }
        } else {
            guard Settings.desktopDirectory.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path
            else { throw PasteError.interrupted }
        }
        try Task.checkCancellation()
        if let focused: AXUIElement = value(axFinder, kAXFocusedUIElementAttribute),
           let role: String = value(focused, kAXRoleAttribute),
           [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) {
            throw PasteError.interrupted
        }
        guard clipboard.changeCount == clipboardChangeCount else { throw PasteError.clipboardChanged }
        // Finder handles conflicts, file metadata, cross-volume moves, and Undo.
        var flags: CGEventFlags = .maskCommand
        if FinderClipboard.containsCutFiles(clipboard) {
            flags.insert(.maskAlternate)
        }
        guard clipboard.changeCount == clipboardChangeCount else { throw PasteError.clipboardChanged }
        guard postKey(kVK_ANSI_V, flags: flags, to: pid) else { throw PasteError.interrupted }
    }

    private static func isShowingFolder(_ folder: URL, in window: AXUIElement) -> Bool {
        let documentURL: URL? = value(window, kAXDocumentAttribute)
            ?? (value(window, kAXDocumentAttribute) as String?).flatMap(URL.init(string:))
        guard let documentURL, documentURL.isFileURL else { return false }
        return documentURL.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path
    }

    private static func locatePasteDestination(_ url: URL) async throws {
        guard isAuthorized else { throw NavigationError.authorization }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw NavigationError.missingDirectory }
        guard let finder = NSWorkspace.shared.frontmostApplication, finder.bundleIdentifier == "com.apple.finder"
        else { throw NavigationError.missingWindow }
        let pid = finder.processIdentifier
        let axFinder = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axFinder, 0.15)
        guard let window: AXUIElement = value(axFinder, kAXFocusedWindowAttribute),
              sheets(in: window).isEmpty else { throw NavigationError.missingWindow }
        guard postKey(kVK_ANSI_G, flags: [.maskCommand, .maskShift], to: pid) else { throw NavigationError.interrupted }

        var ownSheet: AXUIElement?
        let openDeadline = ContinuousClock.now + .seconds(1)
        while ownSheet == nil, ContinuousClock.now < openDeadline {
            try Task.checkCancellation()
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw NavigationError.interrupted }
            ownSheet = sheets(in: window).first {
                value($0, kAXIdentifierAttribute) as String? == "GoToWindow"
            }
            if ownSheet == nil { try await Task.sleep(for: .milliseconds(40)) }
        }
        guard let sheet = ownSheet,
              let input = find(in: sheet, depth: 4, matching: { value($0, kAXIdentifierAttribute) as String? == "PathTextField" })
        else { throw NavigationError.unavailable }
        func pathFieldIsActive() -> Bool {
            // While Go to Folder is open, Finder can report the sheet itself as its focused window.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  sheets(in: window).contains(where: { CFEqual($0, sheet) }) else { return false }
            if let focused: AXUIElement = value(axFinder, kAXFocusedUIElementAttribute), CFEqual(focused, input) { return true }
            return value(input, kAXFocusedAttribute) as Bool? == true
        }
        defer { if pathFieldIsActive() { postKey(kVK_Escape, to: pid) } }
        guard pathFieldIsActive(),
              AXUIElementSetAttributeValue(input, kAXValueAttribute as CFString, url.path as CFString) == .success
        else { throw NavigationError.unavailable }

        let resultDeadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < resultDeadline {
            try Task.checkCancellation()
            guard pathFieldIsActive(),
                  value(input, kAXValueAttribute) as String? == url.path else { throw NavigationError.interrupted }
            if selectedPath(in: sheet, matching: url) {
                guard postKey(kVK_Return, to: pid) else { throw NavigationError.interrupted }
                let transitionDeadline = ContinuousClock.now + .seconds(1)
                while ContinuousClock.now < transitionDeadline {
                    try Task.checkCancellation()
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw NavigationError.interrupted }
                    if !sheets(in: window).contains(where: { CFEqual($0, sheet) }),
                       let current: AXUIElement = value(axFinder, kAXFocusedWindowAttribute), CFEqual(window, current) { return }
                    try await Task.sleep(for: .milliseconds(55))
                }
                throw NavigationError.unavailable
            }
            try await Task.sleep(for: .milliseconds(55))
        }
        throw NavigationError.unavailable
    }

    private static func sheets(in window: AXUIElement) -> [AXUIElement] {
        let direct: [AXUIElement] = value(window, "AXSheets") ?? []
        if !direct.isEmpty { return direct }
        let children: [AXUIElement] = value(window, kAXChildrenAttribute) ?? []
        return children.filter { value($0, kAXRoleAttribute) as String? == kAXSheetRole }
    }

    private static func selectedPath(in sheet: AXUIElement, matching url: URL) -> Bool {
        let table = find(in: sheet, depth: 4) { value($0, kAXRoleAttribute) as String? == kAXTableRole }
        guard let table, let selected: [AXUIElement] = value(table, kAXSelectedRowsAttribute),
              selected.count == 1 else { return false }
        return find(in: selected[0], depth: 4) { element in
            guard let candidate: String = value(element, kAXIdentifierAttribute), candidate.hasPrefix("/") else { return false }
            let candidateURL = URL(fileURLWithPath: candidate)
            return candidateURL.standardizedFileURL.path == url.standardizedFileURL.path
                || candidateURL.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path
        } != nil
    }

    private static func find(in element: AXUIElement, depth: Int, matching: (AXUIElement) -> Bool) -> AXUIElement? {
        if matching(element) { return element }
        guard depth > 0, let children: [AXUIElement] = value(element, kAXChildrenAttribute) else { return nil }
        for child in children {
            if let match = find(in: child, depth: depth - 1, matching: matching) { return match }
        }
        return nil
    }

    private enum NavigationError: LocalizedError {
        case authorization, automationAuthorization, missingDirectory, missingWindow, interrupted, unavailable

        var errorDescription: String? {
            let strings = AppStrings.current
            switch self {
            case .authorization: return strings("Grant Accessibility access in FastRight’s General settings.")
            case .automationAuthorization: return strings("Allow Finder control in FastRight’s General settings to switch folders in the current window.")
            case .missingDirectory: return strings("This favorite folder could not be found.")
            case .missingWindow: return strings("Choose a favorite folder from an open Finder window.")
            case .interrupted: return strings("The active Finder window changed. Choose the favorite folder again.")
            case .unavailable: return strings("Finder could not open this favorite folder.")
            }
        }
    }

    private enum PasteError: LocalizedError {
        case authorization, clipboardChanged, interrupted

        var errorDescription: String? {
            let strings = AppStrings.current
            switch self {
            case .authorization: return strings("Grant Accessibility access in FastRight’s General settings to use Finder paste.")
            case .clipboardChanged: return strings("The clipboard changed. Choose Paste again.")
            case .interrupted: return strings("Could not confirm the paste location in Finder. Open the destination folder and try again.")
            }
        }
    }
}
