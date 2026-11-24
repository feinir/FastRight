import AppKit
import SwiftUI

enum RowInsertion: Equatable {
    case before, after

    func move<Item: Equatable>(_ source: Item, relativeTo target: Item, in items: inout [Item]) {
        guard source != target, let index = items.firstIndex(of: source),
              let targetIndex = items.firstIndex(of: target) else { return }
        let destination = targetIndex + (self == .after ? 1 : 0) - (index < targetIndex ? 1 : 0)
        guard index != destination else { return }
        items.insert(items.remove(at: index), at: destination)
    }
}

final class SettingsDrag<ID: Hashable>: ObservableObject {
    fileprivate static var pasteboardType: String { "com.ynpe.fastright.settings-row" }
    fileprivate var source: ID?
    @Published fileprivate var destination: Destination?

    fileprivate struct Destination: Equatable {
        let target: AnyHashable
        let insertion: RowInsertion
    }

    fileprivate func clearTarget(_ id: AnyHashable) {
        if destination?.target == id { destination = nil }
    }
}

extension View {
    func settingsDragSource<ID>(_ id: ID, title: String, drag: SettingsDrag<ID>,
                                select: (() -> Void)? = nil, edit: (() -> Void)? = nil,
                                canEdit: Bool = true) -> some View {
        overlay {
            SettingsDragSource(
                title: title, select: select, edit: edit, canEdit: canEdit,
                begin: { drag.source = id },
                end: {
                    drag.source = nil
                    if drag.destination != nil { drag.destination = nil }
                }
            )
            .accessibilityHidden(true)
        }
    }

    func settingsDropTarget<ID, Target: Hashable>(
        _ target: Target, drag: SettingsDrag<ID>, fixedInsertion: RowInsertion? = nil,
        accepts: @escaping (ID) -> Bool, move: @escaping (ID, RowInsertion) -> Void
    ) -> some View {
        modifier(SettingsDropTarget(drag: drag, target: AnyHashable(target),
                                    fixedInsertion: fixedInsertion, accepts: accepts, move: move))
    }
}

private struct SettingsDragSource: NSViewRepresentable {
    @Environment(\.appStrings) private var strings
    let title: String
    let select: (() -> Void)?
    let edit: (() -> Void)?
    let canEdit: Bool
    let begin: () -> Void
    let end: () -> Void

    func makeNSView(context: Context) -> SourceView { SourceView() }

    func updateNSView(_ view: SourceView, context: Context) {
        view.configuration = self
    }

    final class SourceView: NSView, NSDraggingSource {
        var configuration: SettingsDragSource?
        private var startPoint: NSPoint?
        private var endDrag: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            startPoint = event.locationInWindow
            configuration?.select?()
        }

        override func mouseUp(with event: NSEvent) {
            defer { startPoint = nil }
            guard startPoint != nil, event.clickCount == 2, configuration?.canEdit == true else { return }
            configuration?.edit?()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let startPoint, let configuration else { return }
            let point = event.locationInWindow
            guard hypot(point.x - startPoint.x, point.y - startPoint.y) >= 4 else { return }
            self.startPoint = nil
            configuration.begin()
            endDrag = configuration.end

            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setData(Data([1]), forType: .init(SettingsDrag<String>.pasteboardType))
            let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
            let label = NSAttributedString(string: configuration.title, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor
            ])
            let size = NSSize(width: ceil(label.size().width) + 20, height: 26)
            let preview = NSImage(size: size, flipped: false) { rect in
                NSColor.controlBackgroundColor.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
                label.draw(at: NSPoint(x: 10, y: (size.height - label.size().height) / 2))
                return true
            }
            let local = convert(point, from: nil)
            item.setDraggingFrame(NSRect(origin: NSPoint(x: local.x + 12, y: local.y + 10), size: size),
                                  contents: preview)
            let session = beginDraggingSession(with: [item], event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = false
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }

        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            endDrag?()
            endDrag = nil
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            guard configuration?.edit != nil else { return super.menu(for: event) }
            let menu = NSMenu()
            menu.autoenablesItems = false
            let title = (configuration?.strings ?? .current)("Edit")
            let item = menu.addItem(withTitle: title, action: #selector(editSelection), keyEquivalent: "")
            item.target = self
            item.isEnabled = configuration?.canEdit == true
            return menu
        }

        @objc private func editSelection() {
            configuration?.select?()
            configuration?.edit?()
        }
    }
}

private struct SettingsDropTarget<ID: Hashable>: ViewModifier {
    private final class RowGeometry: ObservableObject {
        var height: CGFloat = 0
    }

    @ObservedObject var drag: SettingsDrag<ID>
    let target: AnyHashable
    let fixedInsertion: RowInsertion?
    let accepts: (ID) -> Bool
    let move: (ID, RowInsertion) -> Void
    @StateObject private var geometry = RowGeometry()

    func body(content: Content) -> some View {
        let drop = RowDropDelegate(drag: drag, target: target, fixedInsertion: fixedInsertion,
                                   geometry: geometry, accepts: accepts, move: move)
        return content
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { geometry.height = $0 }
            .overlay(alignment: drag.destination?.insertion == .before ? .top : .bottom) {
                if drag.destination?.target == target {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(height: 3)
                        .padding(.horizontal, 10)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onDrop(of: [SettingsDrag<ID>.pasteboardType], delegate: drop)
    }

    private struct RowDropDelegate: DropDelegate {
        let drag: SettingsDrag<ID>
        let target: AnyHashable
        let fixedInsertion: RowInsertion?
        let geometry: RowGeometry
        let accepts: (ID) -> Bool
        let move: (ID, RowInsertion) -> Void

        func validateDrop(info: DropInfo) -> Bool {
            guard let source = drag.source else { return false }
            return accepts(source)
        }

        func dropEntered(info: DropInfo) {
            _ = dropUpdated(info: info)
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            guard validateDrop(info: info) else {
                drag.clearTarget(target)
                return DropProposal(operation: .forbidden)
            }
            let destination = SettingsDrag<ID>.Destination(target: target, insertion: insertion(at: info.location))
            if drag.destination != destination { drag.destination = destination }
            return DropProposal(operation: .move)
        }

        func dropExited(info: DropInfo) {
            drag.clearTarget(target)
        }

        func performDrop(info: DropInfo) -> Bool {
            defer { drag.clearTarget(target) }
            guard let source = drag.source, accepts(source) else { return false }
            move(source, insertion(at: info.location))
            return true
        }

        private func insertion(at point: CGPoint) -> RowInsertion {
            fixedInsertion ?? (point.y < geometry.height / 2 ? .before : .after)
        }
    }
}
