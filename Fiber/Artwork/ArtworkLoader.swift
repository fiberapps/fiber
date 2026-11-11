import SwiftUI
import UIKit

/// Colours taken from a cover. Screens use these for their backgrounds.
nonisolated struct ArtPalette: Equatable, Sendable {
    /// Average of the bottom rows of the cover, darkened enough for white text.
    /// The album page fades the artwork into this colour.
    var floor: RGB
    /// The same bottom-edge colour, left brighter. Cards extend their artwork with it.
    var edge: RGB
    /// The most common vivid colours, used by the player backdrop.
    var accents: [RGB]

    nonisolated struct RGB: Equatable, Sendable {
        var r: Double, g: Double, b: Double
        var color: Color { Color(red: r, green: g, blue: b) }
        var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

        func scaled(_ factor: Double) -> RGB { RGB(r: r * factor, g: g * factor, b: b * factor) }

        /// Brings the colour under a luminance ceiling without changing its hue.
        func capped(luminance ceiling: Double) -> RGB {
            let current = luminance
            return current > ceiling ? scaled(ceiling / current) : self
        }
    }

    static let neutral = ArtPalette(
        floor: RGB(r: 0.11, g: 0.11, b: 0.13),
        edge: RGB(r: 0.2, g: 0.2, b: 0.23),
        accents: [RGB(r: 0.25, g: 0.25, b: 0.3), RGB(r: 0.16, g: 0.16, b: 0.2), RGB(r: 0.3, g: 0.26, b: 0.3)])
}

nonisolated enum ArtworkFiles {
    /// Folder for covers saved from imported files.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func url(named name: String) -> URL { directory.appendingPathComponent(name) }
}

/// Loads, draws and caches artwork for every source, and derives palettes.
/// All decoding and drawing happens off the main thread.
final class ArtworkLoader {
    static let shared = ArtworkLoader()

    private let images = NSCache<NSString, UIImage>()
    private var palettes: [Artwork: ArtPalette] = [:]
    private let session: URLSession

    private init() {
        images.totalCostLimit = 96 * 1024 * 1024
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 256 << 20)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: configuration)
    }

    /// Rounds requested sizes into a few buckets so the cache gets reused.
    private func bucket(_ pixels: Int) -> Int {
        for size in [96, 200, 400, 700, 1200] where pixels <= size { return size }
        return 1200
    }

    private func key(_ artwork: Artwork, _ pixels: Int) -> NSString { "\(artwork.hashValue)-\(pixels)" as NSString }

    func cachedImage(for artwork: Artwork, pixels: Int) -> UIImage? {
        images.object(forKey: key(artwork, bucket(pixels)))
    }

    func image(for artwork: Artwork, pixels: Int) async -> UIImage? {
        let size = bucket(pixels)
        let cacheKey = key(artwork, size)
        if let hit = images.object(forKey: cacheKey) { return hit }

        let image: UIImage?
        switch artwork {
        case .none:
            image = nil
        case .generated(let seed, let style, let label):
            image = await Task.detached(priority: .userInitiated) {
                GeneratedArt.image(seed: seed, style: style, label: label, pixels: size)
            }.value
        case .file(let name):
            image = await Task.detached(priority: .userInitiated) {
                Self.downsample(url: ArtworkFiles.url(named: name), pixels: size)
            }.value
        case .remote(let template):
            let address = template
                .replacingOccurrences(of: "{w}", with: "\(size)")
                .replacingOccurrences(of: "{h}", with: "\(size)")
            guard let url = URL(string: address) else { return nil }
            do {
                let (data, _) = try await session.data(from: url)
                image = await Task.detached(priority: .userInitiated) { UIImage(data: data)?.preparingForDisplay() }.value
            } catch {
                // A missing cover is not worth interrupting the user; the placeholder stays.
                image = nil
            }
        }

        if let image {
            images.setObject(image, forKey: cacheKey, cost: Int(image.size.width * image.size.height * 4))
        }
        return image
    }

    func palette(for artwork: Artwork) async -> ArtPalette {
        if let hit = palettes[artwork] { return hit }
        guard let image = await image(for: artwork, pixels: 200) else { return .neutral }
        let palette = await Task.detached(priority: .userInitiated) { Self.extractPalette(from: image) }.value
        palettes[artwork] = palette
        return palette
    }

    func cachedPalette(for artwork: Artwork) -> ArtPalette? { palettes[artwork] }

    private nonisolated static func downsample(url: URL, pixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    nonisolated static func extractPalette(from image: UIImage) -> ArtPalette {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let cgImage = image.cgImage,
              let context = CGContext(
                data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return .neutral }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        func rgb(_ x: Int, _ y: Int) -> ArtPalette.RGB {
            let offset = (y * side + x) * 4
            return .init(r: Double(pixels[offset]) / 255, g: Double(pixels[offset + 1]) / 255, b: Double(pixels[offset + 2]) / 255)
        }

        // Bottom rows of the picture (memory row 0 is the top of the image here).
        var floor = ArtPalette.RGB(r: 0, g: 0, b: 0)
        let floorRows = 3
        for y in (side - floorRows)..<side {
            for x in 0..<side {
                let value = rgb(x, y)
                floor.r += value.r; floor.g += value.g; floor.b += value.b
            }
        }
        let floorCount = Double(floorRows * side)
        let bottom = ArtPalette.RGB(r: floor.r / floorCount, g: floor.g / floorCount, b: floor.b / floorCount)
        floor = bottom.capped(luminance: 0.2)
        let edge = bottom.capped(luminance: 0.42)

        // Histogram over coarse colour buckets, favouring saturated pixels.
        struct Bucket { var weight = 0.0, r = 0.0, g = 0.0, b = 0.0 }
        var buckets: [Int: Bucket] = [:]
        for y in 0..<side {
            for x in 0..<side {
                let value = rgb(x, y)
                let high = max(value.r, value.g, value.b)
                let low = min(value.r, value.g, value.b)
                let saturation = high > 0 ? (high - low) / high : 0
                let weight = 0.25 + saturation * 1.5
                let index = (Int(value.r * 5.99) * 36) + (Int(value.g * 5.99) * 6) + Int(value.b * 5.99)
                var bucket = buckets[index, default: Bucket()]
                bucket.weight += weight
                bucket.r += value.r * weight; bucket.g += value.g * weight; bucket.b += value.b * weight
                buckets[index] = bucket
            }
        }
        var accents: [ArtPalette.RGB] = []
        for bucket in buckets.values.sorted(by: { $0.weight > $1.weight }) {
            let candidate = ArtPalette.RGB(r: bucket.r / bucket.weight, g: bucket.g / bucket.weight, b: bucket.b / bucket.weight)
            let isDistinct = accents.allSatisfy { abs($0.r - candidate.r) + abs($0.g - candidate.g) + abs($0.b - candidate.b) > 0.28 }
            if isDistinct { accents.append(candidate) }
            if accents.count == 4 { break }
        }
        while accents.count < 3 { accents.append((accents.last ?? floor).scaled(0.7)) }
        return ArtPalette(floor: floor, edge: edge, accents: accents)
    }
}

/// Shows a cover with the hairline edge the references use.
struct ArtworkView: View {
    let artwork: Artwork
    var cornerRadius: CGFloat = 6
    /// Longest side in points, used to pick a sensible image size.
    var points: CGFloat = 200

    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    private var pixels: Int { Int(points * displayScale) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            Rectangle().fill(Color(white: 0.16))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: max(points * 0.3, 12), weight: .medium))
                    .foregroundStyle(Color(white: 0.4))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .accessibilityHidden(true)
        .task(id: artwork) {
            if let hit = ArtworkLoader.shared.cachedImage(for: artwork, pixels: pixels) {
                image = hit
                return
            }
            image = nil
            let loaded = await ArtworkLoader.shared.image(for: artwork, pixels: pixels)
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }
}
