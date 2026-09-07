import AppKit

enum StatusIcon {
    static let size = NSSize(width: 18, height: 18)

    static func make(bundle: Bundle = AppResources.bundle) -> NSImage {
        let image: NSImage
        if let url = bundle.url(forResource: "StatusPastePalTemplate", withExtension: "svg"),
           let resourceImage = NSImage(contentsOf: url) {
            image = resourceImage
        } else {
            image = NSImage(systemSymbolName: "tray", accessibilityDescription: AppIdentity.displayName) ?? NSImage(size: size)
        }
        image.size = size
        image.isTemplate = true
        image.accessibilityDescription = AppIdentity.displayName
        let name = NSImage.Name("StatusPastePalTemplate")
        if image.setName(name) { return image }
        return NSImage(named: name) ?? image
    }
}
