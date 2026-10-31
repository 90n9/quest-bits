import AppKit

/// The menu-bar item's image: the QuestBits logo (the app icon's quest scroll with its
/// check mark, drawn as a line glyph) and the counts, rendered into one template image.
/// A menu-bar label drops images interpolated into its Text, so the symbols and counts
/// are drawn here; as a template it follows the menu bar's light or dark look.
enum MenuBarIcon {
    private static let height: CGFloat = 18
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)

    private enum Part {
        case logo
        case symbol(String)
        case text(String)
        case gap(CGFloat)
    }

    /// The logo, then ✋ waiting and ⚡ working when either is above 0.
    static func image(waiting: Int, working: Int) -> NSImage {
        var parts: [Part] = [.logo]
        if waiting > 0 { parts += [.gap(6), .symbol("hand.raised.fill"), .gap(2), .text("\(waiting)")] }
        if waiting > 0 && working > 0 { parts += [.gap(4), .text("·"), .gap(4)] }
        else if working > 0 { parts += [.gap(6)] }
        if working > 0 { parts += [.symbol("bolt.fill"), .gap(1), .text("\(working)")] }

        let width = parts.reduce(CGFloat(0)) { $0 + Self.width(of: $1) }
        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for part in parts {
                draw(part, at: x)
                x += Self.width(of: part)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static let logoWidth: CGFloat = 15

    private static func width(of part: Part) -> CGFloat {
        switch part {
        case .logo: return logoWidth
        case .gap(let w): return w
        case .text(let s): return ceil((s as NSString).size(withAttributes: [.font: font]).width)
        case .symbol(let name): return symbolImage(name)?.size.width ?? 0
        }
    }

    private static func symbolImage(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
    }

    private static func draw(_ part: Part, at x: CGFloat) {
        switch part {
        case .gap: break
        case .logo: drawLogo(at: x)
        case .text(let s):
            let size = (s as NSString).size(withAttributes: [.font: font])
            (s as NSString).draw(at: NSPoint(x: x, y: (height - size.height) / 2),
                                 withAttributes: [.font: font, .foregroundColor: NSColor.black])
        case .symbol(let name):
            guard let img = symbolImage(name) else { return }
            img.draw(in: NSRect(x: x, y: (height - img.size.height) / 2, width: img.size.width, height: img.size.height))
        }
    }

    /// A scroll: rolled top and bottom, the sheet between them, a check mark on the sheet.
    private static func drawLogo(at x: CGFloat) {
        NSColor.black.set()
        let line: CGFloat = 1.3
        // Rolls, wider than the sheet.
        for y in [1.5, 13.5] as [CGFloat] {
            let roll = NSBezierPath(roundedRect: NSRect(x: x + 0.75, y: y, width: logoWidth - 1.5, height: 3),
                                    xRadius: 1.5, yRadius: 1.5)
            roll.lineWidth = line
            roll.stroke()
        }
        // The sheet's sides.
        let sides = NSBezierPath()
        sides.move(to: NSPoint(x: x + 2.5, y: 4.5)); sides.line(to: NSPoint(x: x + 2.5, y: 13.5))
        sides.move(to: NSPoint(x: x + logoWidth - 2.5, y: 4.5)); sides.line(to: NSPoint(x: x + logoWidth - 2.5, y: 13.5))
        sides.lineWidth = line
        sides.stroke()
        // The check mark.
        let check = NSBezierPath()
        check.move(to: NSPoint(x: x + 4.6, y: 9.2))
        check.line(to: NSPoint(x: x + 6.6, y: 7.0))
        check.line(to: NSPoint(x: x + 10.6, y: 11.4))
        check.lineWidth = 1.8
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        check.stroke()
    }
}
