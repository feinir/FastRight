import AppKit
import ApplicationServices
import Carbon

@MainActor
final class FinderCutShortcut {
    private let finderID = "com.apple.finder"
    private var monitoredPID: pid_t?
    private var eventTap: CFMachPort?
    private var eventSource: CFRunLoopSource?
    private var refreshTimer: Timer?

    func start() {
        guard refreshTimer == nil else { return }
        refreshTap()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTap() }
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        removeTap()
    }

    private func removeTap() {
        if let eventSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), eventSource, .commonModes) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        eventSource = nil
        eventTap = nil
        monitoredPID = nil
    }

    private func refreshTap() {
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: finderID).first?.processIdentifier
        guard let pid, AXIsProcessTrusted() else { removeTap(); return }
        if monitoredPID == pid, let eventTap, CFMachPortIsValid(eventTap) { return }
        removeTap()
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let shortcut = Unmanaged<FinderCutShortcut>.fromOpaque(context).takeUnretainedValue()
            return MainActor.assumeIsolated { shortcut.handle(type, event: event) ? nil : Unmanaged.passUnretained(event) }
        }
        guard let tap = CGEvent.tapCreateForPid(pid: pid, place: .headInsertEventTap, options: .defaultTap,
                                                eventsOfInterest: 1 << CGEventType.keyDown.rawValue,
                                                callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { return }
        monitoredPID = pid
        eventTap = tap
        eventSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(_ type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return false
        }
        let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        guard type == .keyDown, event.flags.intersection(modifiers) == .maskCommand,
              event.getIntegerValueField(.keyboardEventKeycode) == kVK_ANSI_X,
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
              let pid = monitoredPID, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        let settings = (try? Settings.load()) ?? Settings()
        guard settings.menuEnabled, settings.enabledActions.contains(FinderAction.cut.rawValue) else { return false }
        let finder = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(finder, 0.08)
        guard let focus: AXUIElement = FinderAutomation.value(finder, kAXFocusedUIElementAttribute),
              let urls = selectedFiles(in: focus),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        return FinderClipboard.writeFiles(urls, cut: true)
    }

    private func selectedFiles(in focus: AXUIElement) -> [URL]? {
        let contentRoles = [kAXListRole, kAXTableRole, kAXOutlineRole, kAXLayoutAreaRole, kAXBrowserRole, kAXScrollAreaRole]
        let editableRoles = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]
        var element = focus
        for _ in 0..<6 {
            guard let role: String = FinderAutomation.value(element, kAXRoleAttribute),
                  !editableRoles.contains(role), role != kAXWindowRole, role != kAXSheetRole else { return nil }
            if contentRoles.contains(role) {
                for attribute in [kAXSelectedRowsAttribute, kAXSelectedChildrenAttribute] {
                    let selection: [AXUIElement] = FinderAutomation.value(element, attribute) ?? []
                    if !selection.isEmpty {
                        let urls = selection.compactMap { fileURL(in: $0, depth: 4) }
                        if urls.count == selection.count { return urls }
                    }
                }
            }
            guard let parent: AXUIElement = FinderAutomation.value(element, kAXParentAttribute) else { return nil }
            element = parent
        }
        return nil
    }

    private func fileURL(in element: AXUIElement, depth: Int) -> URL? {
        if let url: URL = FinderAutomation.value(element, kAXURLAttribute), url.isFileURL {
            let parts = url.standardizedFileURL.pathComponents
            return parts == ["/"] || (parts.count == 3 && parts[1] == "Volumes") ? nil : url
        }
        guard depth > 0, let children: [AXUIElement] = FinderAutomation.value(element, kAXChildrenAttribute)
        else { return nil }
        return children.lazy.compactMap { self.fileURL(in: $0, depth: depth - 1) }.first
    }
}
