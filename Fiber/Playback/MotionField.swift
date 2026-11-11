import SwiftUI

/// The player backdrop's colour mesh. The Lock Screen video uses the same
/// points, so the motion there is the same field, not a still frame of it.
nonisolated enum MotionField {
    static func points(at t: Double) -> [SIMD2<Float>] {
        func point(_ x: Double, _ y: Double) -> SIMD2<Float> { SIMD2(Float(x), Float(y)) }
        let top = point(0.5 + 0.12 * sin(t * 1.3), 0)
        let left = point(0, 0.5 + 0.14 * cos(t * 0.9))
        let middle = point(0.5 + 0.2 * sin(t), 0.5 + 0.2 * cos(t * 1.2))
        let right = point(1, 0.5 + 0.14 * sin(t * 1.1))
        let bottom = point(0.5 + 0.12 * cos(t * 0.8), 1)
        return [point(0, 0), top, point(1, 0), left, middle, right, point(0, 1), bottom, point(1, 1)]
    }

    /// One full trip of every sine in `points(at:)` lands back on the first frame.
    static let loop: Double = .pi * 20

    static func colors(for palette: ArtPalette) -> [Color] {
        rgbs(for: palette).map(\.color)
    }

    static func rgbs(for palette: ArtPalette) -> [ArtPalette.RGB] {
        let source = palette.accents.isEmpty ? ArtPalette.neutral.accents : palette.accents
        let accents = source.map { $0.capped(luminance: 0.3) }
        func pick(_ index: Int, _ scale: Double) -> ArtPalette.RGB {
            accents[index % accents.count].scaled(scale)
        }
        return [
            pick(0, 0.9), pick(1, 0.75), pick(2, 0.85),
            pick(2, 0.8), pick(0, 1), pick(1, 0.9),
            pick(1, 0.45), pick(2, 0.4), pick(0, 0.35),
        ]
    }
}
