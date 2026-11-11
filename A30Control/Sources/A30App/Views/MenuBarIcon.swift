// Menu bar glyph: the "a" + spark from Assets/icon.png (Tools/prepicon.swift → menubar(@2x).png),
// plus status badges. MenuBarExtra's label shows only one Image and one Text, so the badges
// (⚡ charging, mic muted, low battery) are drawn into the same template image.
import AppKit

enum MenuBarIcon {
    enum Badge: Hashable { case charging, micMuted, lowBattery }

    private static let glyph: NSImage? = Bundle.main.image(forResource: "menubar")
    private static var cache: [[Badge]: NSImage] = [:]

    static func image(_ badges: [Badge]) -> NSImage {
        if let hit = cache[badges] { return hit }
        let glyphW: CGFloat = 20, h: CGFloat = 16, gap: CGFloat = 3
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let symbols: [NSImage] = badges.compactMap { b in
            let name: String = switch b {
            case .charging: "bolt.fill"
            case .micMuted: "mic.slash.fill"
            case .lowBattery: "battery.25"
            }
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        }
        let width = glyphW + symbols.reduce(0) { $0 + gap + $1.size.width }
        let img = NSImage(size: NSSize(width: width, height: h), flipped: false) { _ in
            if let g = glyph { g.draw(in: NSRect(x: 0, y: 0, width: glyphW, height: h)) }
            else { NSImage(systemSymbolName: "headphones", accessibilityDescription: nil)?.draw(in: NSRect(x: 0, y: 0, width: glyphW, height: h)) }
            var x = glyphW
            for s in symbols {
                x += gap
                s.draw(in: NSRect(x: x, y: (h - s.size.height) / 2, width: s.size.width, height: s.size.height))
                x += s.size.width
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "A30 Control"
        cache[badges] = img
        return img
    }
}
