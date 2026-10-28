import AppKit

/// The menu bar bell, drawn once with Core Graphics. An SF Symbol would load the symbol
/// font and its caches into the always-running agent (about 0.7 MB more).
enum MenuBarIcon {
    static let bell = make(silent: false)
    static let bellSlash = make(silent: true)

    private static func make(silent: Bool) -> NSImage {
        let size = 18, scale = 2
        guard let ctx = CGContext(data: nil, width: size * scale, height: size * scale, bitsPerComponent: 8,
                                  bytesPerRow: size * scale * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return NSImage() }
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))

        // Flared body with a domed top (y grows upward).
        let body = CGMutablePath()
        body.move(to: CGPoint(x: 3.9, y: 6.2))
        body.addCurve(to: CGPoint(x: 5.0, y: 10.8), control1: CGPoint(x: 4.9, y: 6.8), control2: CGPoint(x: 5.0, y: 8.8))
        body.addArc(center: CGPoint(x: 9, y: 10.8), radius: 4, startAngle: .pi, endAngle: 0, clockwise: true)
        body.addCurve(to: CGPoint(x: 14.1, y: 6.2), control1: CGPoint(x: 13.0, y: 8.8), control2: CGPoint(x: 13.1, y: 6.8))
        body.closeSubpath()
        ctx.addPath(body)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 2.6, y: 4.7, width: 12.8, height: 1.8), cornerWidth: 0.9, cornerHeight: 0.9, transform: nil))
        ctx.addEllipse(in: CGRect(x: 8.0, y: 14.4, width: 2.0, height: 2.0))   // crown
        ctx.addEllipse(in: CGRect(x: 7.4, y: 1.9, width: 3.2, height: 3.2))    // clapper
        ctx.fillPath()

        if silent {
            ctx.setLineCap(.round)
            ctx.setBlendMode(.clear)
            ctx.setLineWidth(3.4)
            ctx.strokeLineSegments(between: [CGPoint(x: 2.8, y: 16.2), CGPoint(x: 15.6, y: 1.8)])
            ctx.setBlendMode(.normal)
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
            ctx.setLineWidth(1.5)
            ctx.strokeLineSegments(between: [CGPoint(x: 2.8, y: 16.2), CGPoint(x: 15.6, y: 1.8)])
        }

        guard let cg = ctx.makeImage() else { return NSImage() }
        let image = NSImage(cgImage: cg, size: NSSize(width: size, height: size))
        image.isTemplate = true
        image.accessibilityDescription = "Howr"
        return image
    }
}
