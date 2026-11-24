import AppKit

struct FinderMenuIcons {
    private let monochrome: [String: NSImage]
    private let colorful: [String: NSImage]

    init(archiveURL: URL? = nil) {
        if let archiveURL, let data = try? Data(contentsOf: archiveURL),
           let decoded = try? NSKeyedUnarchiver.unarchivedObject(
               ofClasses: [NSDictionary.self, NSString.self, NSImage.self, NSBitmapImageRep.self, NSArray.self], from: data
           ) as? [String: [String: NSImage]],
           let monochrome = decoded["monochrome"], let colorful = decoded["colorful"] {
            self.monochrome = monochrome
            self.colorful = colorful
            return
        }
        let symbols = Set(FinderAction.allCases.map(\.symbol) + ["app", "doc", "folder", "folder.badge.plus", "gearshape"])
        var monochrome: [String: NSImage] = [:]
        var colorful: [String: NSImage] = [:]
        let base = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let palette = base.applying(.init(paletteColors: [.systemBlue, .systemTeal]))
        for name in symbols {
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { continue }
            if let image = symbol.withSymbolConfiguration(base) {
                monochrome[name] = Self.render(image, template: true)
            }
            if let image = symbol.withSymbolConfiguration(palette) {
                colorful[name] = Self.render(image)
            }
        }
        self.monochrome = monochrome
        self.colorful = colorful
    }

    func image(_ symbol: String, colorful: Bool) -> NSImage? {
        colorful ? self.colorful[symbol] : monochrome[symbol]
    }

    func writeArchive(to url: URL) throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: ["monochrome": monochrome, "colorful": colorful],
                                                    requiringSecureCoding: true)
        try data.write(to: url, options: .atomic)
    }

    static func render(_ source: NSImage, template: Bool = false) -> NSImage? {
        let size = NSSize(width: 16, height: 16)
        let sourceSize = source.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }
        let fit = min(size.width / sourceSize.width, size.height / sourceSize.height)
        let width = sourceSize.width * fit
        let height = sourceSize.height * fit
        let destination = NSRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
        let result = NSImage(size: size)
        result.isTemplate = template
        result.cacheMode = .never

        // The menu crosses into Finder's process. Keep only menu-size bitmap representations.
        for scale in [1, 2] {
            let pixels = Int(size.width) * scale
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
            context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            context.imageInterpolation = .high
            source.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            bitmap.size = size
            result.addRepresentation(bitmap)
        }
        return result
    }
}
