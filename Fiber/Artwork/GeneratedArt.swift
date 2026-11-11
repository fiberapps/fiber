import UIKit

/// Small deterministic random generator, so a seed always draws the same cover.
nonisolated struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> CGFloat { CGFloat(next() >> 11) / CGFloat(1 << 53) }
    mutating func range(_ low: CGFloat, _ high: CGFloat) -> CGFloat { low + (high - low) * unit() }
}

/// Draws original cover art for the demo catalog. Nothing here is copied from
/// a real release: every image is shapes and gradients chosen from a seed.
nonisolated enum GeneratedArt {
    static func image(seed: UInt64, style: ArtStyle, label: String?, pixels: Int) -> UIImage {
        let side = CGFloat(max(pixels, 32))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        return renderer.image { context in
            var random = SeededRandom(seed: seed)
            let cg = context.cgContext
            let rect = CGRect(x: 0, y: 0, width: side, height: side)
            switch style {
            case .bloom: drawBloom(cg, rect, &random)
            case .rings: drawRings(cg, rect, &random)
            case .chevrons: drawChevrons(cg, rect, &random)
            case .stripes: drawStripes(cg, rect, &random)
            case .halftone: drawHalftone(cg, rect, &random)
            case .horizon: drawHorizon(cg, rect, &random)
            case .tile: drawTile(cg, rect, &random, label: label ?? "")
            }
            if style != .tile, let label, !label.isEmpty {
                drawLabel(label, in: rect, color: UIColor.white.withAlphaComponent(0.94))
            }
        }
    }

    // MARK: Styles

    private static func color(_ hue: CGFloat, _ saturation: CGFloat, _ brightness: CGFloat) -> UIColor {
        UIColor(hue: hue.truncatingRemainder(dividingBy: 1), saturation: saturation, brightness: brightness, alpha: 1)
    }

    private static func fillGradient(_ cg: CGContext, _ rect: CGRect, _ colors: [UIColor], angle: CGFloat = .pi / 2) {
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map(\.cgColor) as CFArray, locations: nil)!
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let reach = rect.width * 0.75
        let start = CGPoint(x: center.x - cos(angle) * reach, y: center.y - sin(angle) * reach)
        let end = CGPoint(x: center.x + cos(angle) * reach, y: center.y + sin(angle) * reach)
        cg.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private static func glow(_ cg: CGContext, at point: CGPoint, radius: CGFloat, color: UIColor) {
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
        cg.drawRadialGradient(gradient, startCenter: point, startRadius: 0, endCenter: point, endRadius: radius, options: [])
    }

    private static func drawBloom(_ cg: CGContext, _ rect: CGRect, _ random: inout SeededRandom) {
        let hue = random.unit()
        fillGradient(cg, rect, [color(hue, 0.75, 0.32), color(hue + 0.08, 0.8, 0.14)], angle: random.range(0.6, 2.2))
        for index in 0..<6 {
            let spread = CGFloat(index) * random.range(0.04, 0.11)
            let point = CGPoint(x: rect.width * random.unit(), y: rect.height * random.unit())
            glow(cg, at: point, radius: rect.width * random.range(0.35, 0.7),
                 color: color(hue + spread, random.range(0.55, 0.95), random.range(0.75, 1)).withAlphaComponent(0.85))
        }
    }

    private static func drawRings(_ cg: CGContext, _ rect: CGRect, _ random: inout SeededRandom) {
        let hue = random.unit()
        let contrast = hue + random.range(0.38, 0.55)
        cg.setFillColor(color(hue, 0.25, 0.96).cgColor)
        cg.fill(rect)
        let center = CGPoint(x: rect.width * random.range(0.3, 0.7), y: rect.height * random.range(0.35, 0.75))
        let count = 9
        for index in 0..<count {
            let progress = CGFloat(index) / CGFloat(count)
            let radius = rect.width * 1.05 * (1 - progress)
            let ringColor = index.isMultiple(of: 2)
                ? color(contrast, 0.7, 0.95 - progress * 0.35)
                : color(hue, 0.35 + progress * 0.4, 0.98)
            cg.setFillColor(ringColor.cgColor)
            cg.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
    }

    private static func drawChevrons(_ cg: CGContext, _ rect: CGRect, _ random: inout SeededRandom) {
        let hue = random.unit()
        fillGradient(cg, rect, [color(hue, 0.62, 0.98), color(hue + 0.06, 0.7, 0.95)], angle: 0)
        let count = 6
        for index in 0..<count {
            let progress = CGFloat(index) / CGFloat(count - 1)
            let tipX = rect.width * (1.05 - progress * 0.95)
            let halfHeight = rect.height * (1.1 - progress * 0.75)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: -rect.width * 0.2, y: rect.midY - halfHeight))
            path.addLine(to: CGPoint(x: tipX, y: rect.midY))
            path.addLine(to: CGPoint(x: -rect.width * 0.2, y: rect.midY + halfHeight))
            path.closeSubpath()
            cg.addPath(path)
            cg.setFillColor(color(hue + 0.02 + progress * 0.09, 0.55 + progress * 0.2, 0.97).withAlphaComponent(0.9).cgColor)
            cg.fillPath()
        }
    }

    private static func drawStripes(_ cg: CGContext, _ rect: CGRect, _ random: inout SeededRandom) {
        let hue = random.unit()
        let palette = [
            color(hue, 0.8, 0.95), color(hue + 0.09, 0.75, 0.98), color(hue + 0.5, 0.6, 0.25),
            color(hue + 0.16, 0.5, 1), color(hue + 0.58, 0.7, 0.9),
        ]
        cg.setFillColor(palette[2].cgColor)
        cg.fill(rect)
        cg.saveGState()
        cg.translateBy(x: rect.midX, y: rect.midY)
        cg.rotate(by: random.range(-0.9, -0.5))
        var x = -rect.width
        var index = 0
        while x < rect.width {
            let width = rect.width * random.range(0.06, 0.2)
            cg.setFillColor(palette[index % palette.count].cgColor)
            cg.fill(CGRect(x: x, y: -rect.height * 1.5, width: width, height: rect.height * 3))
            x += width
            index += 1
        }
        cg.restoreGState()
    }

    private static func drawHalftone(_ cg: CGContext, _ rect: CGRect, _ random: inout SeededRandom) {
        let hue = random.unit()
        cg.setFillColor(color(hue, 0.12, 0.97).cgColor)
        cg.fill(rect)
        cg.setFillColor(color(hue, 0.78, 0.62).cgColor)
        let columns = 30
        let cell = rect.width / CGFloat(columns)
        let focus = CGPoint(x: rect.width * random.range(0.25, 0.75), y: rect.height * random.range(0.25, 0.75))
        let wave = random.range(2.5, 5)
        for row in 0..<columns {
            for column in 0..<columns {
                let point = CGPoint(x: (CGFloat(column) + 0.5) * cell, y: (CGFloat(row) + 0.5) * cell)
                let distance = hypot(point.x - focus.x, point.y - focus.y) / rect.width
                let size = cell * (0.15 + 0.8 * abs(sin(distance * wave * .pi)))
                cg.fillEllipse(in: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size))
            }
        }
    }

    private static func drawHorizon(_ cg: CGContext, _ rect: CGRect, _ random: inout SeededRandom) {
        let hue = random.unit()
        fillGradient(cg, rect, [color(hue, 0.35, 1), color(hue + 0.1, 0.55, 0.95), color(hue + 0.18, 0.5, 0.75)])
        let sun = CGPoint(x: rect.width * random.range(0.3, 0.7), y: rect.height * random.range(0.3, 0.45))
        glow(cg, at: sun, radius: rect.width * 0.5, color: UIColor.white.withAlphaComponent(0.55))
        let sunRadius = rect.width * random.range(0.1, 0.16)
        cg.setFillColor(color(hue + 0.12, 0.25, 1).cgColor)
        cg.fillEllipse(in: CGRect(x: sun.x - sunRadius, y: sun.y - sunRadius, width: sunRadius * 2, height: sunRadius * 2))
        for layer in 0..<4 {
            let depth = CGFloat(layer) / 3
            let baseline = rect.height * (0.58 + depth * 0.13)
            let amplitude = rect.height * random.range(0.03, 0.08)
            let frequency = random.range(1.2, 3.2)
            let phase = random.range(0, 6)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: rect.height))
            var x: CGFloat = 0
            while x <= rect.width {
                let y = baseline + sin(x / rect.width * frequency * .pi + phase) * amplitude
                path.addLine(to: CGPoint(x: x, y: y))
                x += rect.width / 48
            }
            path.addLine(to: CGPoint(x: rect.width, y: rect.height))
            path.closeSubpath()
            cg.addPath(path)
            cg.setFillColor(color(hue + 0.55, 0.45 + depth * 0.2, 0.5 - depth * 0.3).cgColor)
            cg.fillPath()
        }
    }

    /// Light tile with a big coloured word, used for radio stations.
    private static func drawTile(_ cg: CGContext, _ rect: CGRect, _ random: inout SeededRandom, label: String) {
        fillGradient(cg, rect, [UIColor(white: 0.99, alpha: 1), UIColor(white: 0.92, alpha: 1)])
        let hue = random.unit()
        let ink = color(hue, 0.85, 0.9)
        let words = label.uppercased().split(separator: " ").map(String.init)
        let longest = words.map(\.count).max() ?? 1
        let fontSize = min(rect.width * 0.86 / (CGFloat(longest) * 0.62), rect.height * 0.62 / CGFloat(max(words.count, 1)))
        let descriptor = UIFont.systemFont(ofSize: fontSize, weight: .black).fontDescriptor
            .withSymbolicTraits([.traitBold, .traitItalic, .traitCondensed])
        let font = descriptor.map { UIFont(descriptor: $0, size: fontSize) } ?? .systemFont(ofSize: fontSize, weight: .black)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineHeightMultiple = 0.82
        let text = NSAttributedString(string: words.joined(separator: "\n"), attributes: [
            .font: font, .foregroundColor: ink, .paragraphStyle: paragraph, .kern: -fontSize * 0.03,
        ])
        let bounds = text.boundingRect(with: CGSize(width: rect.width, height: rect.height), options: [.usesLineFragmentOrigin], context: nil)
        let origin = CGPoint(x: 0, y: (rect.height * 0.86 - bounds.height) / 2)
        text.draw(with: CGRect(origin: origin, size: CGSize(width: rect.width, height: bounds.height)), options: [.usesLineFragmentOrigin], context: nil)

        let footer = NSAttributedString(string: "fiber radio", attributes: [
            .font: UIFont.systemFont(ofSize: rect.width * 0.085, weight: .bold),
            .foregroundColor: UIColor(white: 0.25, alpha: 1), .paragraphStyle: paragraph,
        ])
        footer.draw(with: CGRect(x: 0, y: rect.height * 0.8, width: rect.width, height: rect.height * 0.15), options: [.usesLineFragmentOrigin], context: nil)
    }

    private static func drawLabel(_ label: String, in rect: CGRect, color: UIColor) {
        let fontSize = rect.width * 0.14
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 0.86
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = rect.width * 0.02
        let text = NSAttributedString(string: label, attributes: [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .heavy), .foregroundColor: color,
            .paragraphStyle: paragraph, .kern: -fontSize * 0.02, .shadow: shadow,
        ])
        let inset = rect.width * 0.07
        text.draw(with: rect.insetBy(dx: inset, dy: inset), options: [.usesLineFragmentOrigin], context: nil)
    }
}
