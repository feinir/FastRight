import AppKit
import FinderSync

@MainActor
final class FastRightStatusItem: NSObject, NSMenuDelegate {
    private static let icon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let centerX = rect.midX
            let centerY = rect.midY
            let mark = NSBezierPath()
            mark.lineWidth = 1.7
            mark.lineCapStyle = .round
            mark.lineJoinStyle = .round
            mark.move(to: NSPoint(x: centerX - 6, y: centerY + 5))
            mark.line(to: NSPoint(x: centerX - 1, y: centerY))
            mark.line(to: NSPoint(x: centerX - 6, y: centerY - 5))
            for offset in [-4.5, 0, 4.5] as [CGFloat] {
                mark.move(to: NSPoint(x: centerX + 2, y: centerY + offset))
                mark.line(to: NSPoint(x: centerX + (offset == 0 ? 6 : 5), y: centerY + offset))
            }
            NSColor.black.setStroke()
            mark.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()

    private let openPreferences: () throws -> Void
    private let sendRequest: FastRightMenu.RequestHandler
    private var statusItem: NSStatusItem?
    private lazy var menus = FastRightMenu(
        archiveURL: Bundle.main.builtInPlugInsURL
            .flatMap { Bundle(url: $0.appendingPathComponent("FastRightFinder.appex")) }?
            .url(forResource: "FinderMenuIcons", withExtension: "archive"),
        isMenuBar: true, openPreferences: openPreferences, sendRequest: sendRequest
    )

    init(openPreferences: @escaping () throws -> Void, sendRequest: @escaping FastRightMenu.RequestHandler) {
        self.openPreferences = openPreferences
        self.sendRequest = sendRequest
        super.init()
    }

    func start() {
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(settingsDidSave(_:)),
                                                            name: Settings.didSaveNotification, object: nil)
        updateVisibility()
    }

    func stop() {
        DistributedNotificationCenter.default().removeObserver(self)
        removeStatusItem()
    }

    @objc private func settingsDidSave(_ notification: Notification) {
        updateVisibility()
    }

    private func updateVisibility() {
        guard ((try? Settings.load()) ?? Settings()).showMenuBarIcon else {
            removeStatusItem()
            return
        }
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.icon
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "FastRight"
        item.button?.setAccessibilityLabel("FastRight")

        let menu = NSMenu(title: "FastRight")
        menu.autoenablesItems = false
        menu.delegate = self
        menuNeedsUpdate(menu)
        item.menu = menu
        statusItem = item
    }

    private func removeStatusItem() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let settings = (try? Settings.load()) ?? Settings()
        guard let content = menus.contextMenu(for: .contextualMenuForContainer, target: Settings.desktopDirectory,
                                              selection: [], settings: settings) else { return }
        let items = content.items
        content.removeAllItems()
        menu.removeAllItems()
        items.forEach(menu.addItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: settings.strings("Quit FastRight"),
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApplication.shared
        if settings.showMainMenuIcons {
            quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        }
        menu.addItem(quit)

        if #available(macOS 27.0, *) { showConfiguredIcons(in: menu) }
    }

    @available(macOS 27.0, *)
    private func showConfiguredIcons(in menu: NSMenu) {
        for item in menu.items {
            if item.image != nil { item.preferredImageVisibility = .visible }
            if let submenu = item.submenu { showConfiguredIcons(in: submenu) }
        }
    }
}
