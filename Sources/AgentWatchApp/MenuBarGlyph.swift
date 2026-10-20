import AppKit

/// Menu bar icon: a session node branching into three subagents, matching the app icon.
/// Children are hollow when nothing runs and filled when something does.
/// A template image, so macOS tints it for light and dark menu bars.
enum MenuBarGlyph {
    static let idle = make(active: false)
    static let active = make(active: true)

    static func make(active: Bool, size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let s = rect.width / 18
            NSColor.black.setFill()
            NSColor.black.setStroke()

            let parent = CGPoint(x: 9 * s, y: 13.5 * s)
            let children = [CGPoint(x: 3.5 * s, y: 4 * s), CGPoint(x: 9 * s, y: 3.5 * s), CGPoint(x: 14.5 * s, y: 4 * s)]

            for child in children {
                let link = NSBezierPath()
                link.lineWidth = 1.4 * s
                link.lineCapStyle = .round
                link.move(to: CGPoint(x: parent.x, y: parent.y - 2.5 * s))
                link.curve(
                    to: child,
                    controlPoint1: CGPoint(x: parent.x, y: parent.y - 7 * s),
                    controlPoint2: CGPoint(x: child.x, y: child.y + 7 * s))
                link.stroke()
            }

            NSBezierPath(ovalIn: NSRect(x: parent.x - 3.2 * s, y: parent.y - 3.2 * s, width: 6.4 * s, height: 6.4 * s)).fill()

            for child in children {
                let radius = 2.3 * s
                let node = NSBezierPath(ovalIn: NSRect(
                    x: child.x - radius, y: child.y - radius, width: radius * 2, height: radius * 2))
                if active {
                    node.fill()
                } else {
                    // Clear the link end inside the node, then draw the ring.
                    NSGraphicsContext.current?.compositingOperation = .clear
                    node.fill()
                    NSGraphicsContext.current?.compositingOperation = .sourceOver
                    node.lineWidth = 1.3 * s
                    node.stroke()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
