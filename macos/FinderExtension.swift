import AppKit
import FinderSync
import OSLog

@objc(FastRightFinderSync)
final class FastRightFinderSync: FIFinderSync {
    private let controller = FIFinderSyncController.default()
    private let preparationQueue = DispatchQueue(label: "com.ynpe.fastright.findersync.mounts", qos: .userInitiated)
    private let menuLogger = Logger(subsystem: "com.ynpe.fastright.findersync", category: "Menu")
    private let initializedAt = ProcessInfo.processInfo.systemUptime
    private var builtFirstMenu = false
    private var requestedCutShortcut = false
    private var volumeObservers: [NSObjectProtocol] = []
    private lazy var menus = FastRightMenu(
        archiveURL: Bundle(for: FastRightFinderSync.self).url(forResource: "FinderMenuIcons", withExtension: "archive"),
        actionTarget: self,
        openPreferences: { [weak self] in
            guard let self else { throw FileActionError.launchFailed }
            try self.openPreferences()
        },
        sendRequest: { [weak self] request, onFailure in
            guard let self else { throw FileActionError.launchFailed }
            try self.sendRequest(request, onFailure: onFailure)
        }
    )

    override init() {
        super.init()
        if !StoreSandbox.isEnabled { controller.directoryURLs = FinderScope.baseRoots }
        refreshMonitoredRoots()
        _ = menus
        if StoreSandbox.isEnabled {
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(settingsDidSave),
                                                                 name: Settings.didSaveNotification, object: nil)
        }
        let center = NSWorkspace.shared.notificationCenter
        volumeObservers = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshMonitoredRoots()
            }
        }
    }

    override func beginObservingDirectory(at url: URL) {
        DispatchQueue.main.async { [weak self] in
            guard !StoreSandbox.isEnabled, let self, !self.requestedCutShortcut else { return }
            self.requestedCutShortcut = true
            do {
                try self.sendRequest(FinderRequest(action: .startCutShortcut, path: "/")) { [weak self] _ in
                    self?.requestedCutShortcut = false
                }
            } catch {
                self.requestedCutShortcut = false
            }
        }
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        let center = NSWorkspace.shared.notificationCenter
        volumeObservers.forEach(center.removeObserver)
    }

    @objc private func settingsDidSave() {
        refreshMonitoredRoots()
    }

    private func refreshMonitoredRoots() {
        preparationQueue.async { [weak self] in
            let roots: Set<URL>
            if StoreSandbox.isEnabled {
                let settings = (try? Settings.load()) ?? Settings()
                roots = Set(settings.authorizedFolders.compactMap { folder in
                    let url = URL(fileURLWithPath: folder.path, isDirectory: true)
                    guard settings.externalVolumes || FinderScope.allows(url, externalVolumes: false, visibleMountRoots: nil)
                    else { return nil }
                    return url
                })
            } else {
                roots = FinderScope.monitoredRoots()
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.controller.directoryURLs != roots else { return }
                self.controller.directoryURLs = roots
            }
        }
    }

    override func menu(for menu: FIMenuKind) -> NSMenu? {
        guard menu != .toolbarItemMenu, let target = controller.targetedURL() else { return nil }
        let started = ProcessInfo.processInfo.systemUptime
        let settings = (try? Settings.load()) ?? Settings()
        let selection = menu == .contextualMenuForItems ? controller.selectedItemURLs() ?? [] : []
        let result = menus.contextMenu(for: menu, target: target, selection: selection, settings: settings)
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
        if result != nil, !builtFirstMenu {
            builtFirstMenu = true
            let age = Int((started - initializedAt) * 1_000)
            menuLogger.notice("First menu built in \(elapsed, privacy: .public) ms, callback began \(age, privacy: .public) ms after init")
        } else if elapsed >= 100 {
            menuLogger.notice("Menu callback took \(elapsed, privacy: .public) ms")
        }
        return result
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        menus.runAction(sender)
    }

    private var appURL: URL {
        Bundle(for: FastRightFinderSync.self).bundleURL
            .deletingLastPathComponent() // PlugIns
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // FastRight.app
    }

    private func openPreferences() throws {
        try sendRequest(FinderRequest(action: .openPreferences, path: "/")) { error in
            NSAlert(error: error).runModal()
        }
    }

    private func sendRequest(_ request: FinderRequest, onFailure: @escaping (Error) -> Void) throws {
        let url = try request.writeRequest()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        // Finder Sync can open a document in the host, but Launch Services drops its command-line arguments.
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { _, error in
            guard let error else { return }
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async { onFailure(error) }
        }
    }
}
