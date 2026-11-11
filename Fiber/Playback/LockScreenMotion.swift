import AVFoundation
import CoreGraphics
import MediaPlayer
import UIKit

/// Renders the playing colour field into a short square video and hands it to
/// the system as animated Lock Screen artwork. iOS only animates artwork when
/// the pixels are a real video file; a SwiftUI timeline stops the moment the
/// screen locks.
nonisolated enum LockScreenMotion {
    private static let frames = 48
    private static let framesPerSecond: Int32 = 12
    private static let side = 640

    static func videoFile(for palette: ArtPalette) async throws -> URL {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LockMotion", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(cacheName(for: palette) + ".mp4")
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if FileManager.default.fileExists(atPath: url.path), bytes > 1500 {
            return url
        }
        try? FileManager.default.removeItem(at: url)
        try await write(palette, to: url)
        return url
    }

    static func animatedArtwork(file url: URL, palette: ArtPalette, preview: UIImage) -> (key: String, artwork: MPMediaItemAnimatedArtwork)? {
        guard !UIAccessibility.isReduceMotionEnabled else { return nil }
        let key = MPNowPlayingInfoProperty1x1AnimatedArtwork
        guard MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys.contains(key) else { return nil }
        let artwork = MPMediaItemAnimatedArtwork(artworkID: cacheName(for: palette),
            previewImageRequestHandler: { _, completion in completion(preview) },
            videoAssetFileURLRequestHandler: { _, completion in completion(url) })
        return (key, artwork)
    }

    private static func cacheName(for palette: ArtPalette) -> String {
        let sample = (palette.accents + [palette.floor]).prefix(4)
        let text = sample.map { String(format: "%.2f%.2f%.2f", $0.r, $0.g, $0.b) }.joined()
        let safe = text.map { $0.isNumber || $0 == "." ? $0 : "-" }
        return "v2-" + String(safe.prefix(96))
    }

    private static func write(_ palette: ArtPalette, to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: side,
            AVVideoHeightKey: side,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 1_200_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: side,
            kCVPixelBufferHeightKey as String: side,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ])
        guard writer.canAdd(input) else { throw ProviderError.playback("This device couldn't prepare Lock Screen motion.") }
        writer.add(input)
        guard writer.startWriting() else { throw ProviderError.playback(writer.error?.localizedDescription ?? "Lock Screen motion didn't start.") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            var spins = 0
            while !input.isReadyForMoreMediaData {
                spins += 1
                if spins > 500 { throw ProviderError.playback("Lock Screen motion stalled while saving.") }
                try await Task.sleep(for: .milliseconds(2))
            }
            let progress = Double(frame) / Double(frames)
            guard let buffer = pixelBuffer(at: progress * MotionField.loop, palette: palette) else {
                throw ProviderError.playback("Lock Screen motion couldn't draw a frame.")
            }
            let time = CMTime(value: CMTimeValue(frame), timescale: framesPerSecond)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw ProviderError.playback(writer.error?.localizedDescription ?? "Lock Screen motion couldn't be saved.")
            }
        }
        input.markAsFinished()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                if writer.status == .completed { continuation.resume() }
                else { continuation.resume(throwing: ProviderError.playback(writer.error?.localizedDescription ?? "Lock Screen motion wasn't saved.")) }
            }
        }
    }

    private static func pixelBuffer(at t: Double, palette: ArtPalette) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA, [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ] as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }
        draw(at: t, palette: palette, in: context)
        return buffer
    }

    /// Moving colour blobs at the mesh's own control points, plus a dark wash
    /// matching the in-app backdrop.
    private static func draw(at t: Double, palette: ArtPalette, in context: CGContext) {
        let s = CGFloat(side)
        context.setFillColor(CGColor(srgbRed: 0.02, green: 0.02, blue: 0.03, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: s, height: s))
        let accents = MotionField.rgbs(for: palette)
        let points = MotionField.points(at: t)
        let blobs: [(Int, CGFloat)] = [(4, 0.78), (1, 0.62), (3, 0.56), (5, 0.56), (7, 0.64)]
        context.setBlendMode(.plusLighter)
        for (index, blob) in blobs.enumerated() {
            let point = points[blob.0]
            let center = CGPoint(x: CGFloat(point.x) * s, y: CGFloat(point.y) * s)
            let rgb = accents[index % accents.count]
            let color = CGColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 0.9)
            let clear = CGColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 0)
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color, clear] as CFArray, locations: [0, 1]) else { continue }
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: s * blob.1, options: [])
        }
        context.setBlendMode(.normal)
        context.setFillColor(CGColor(gray: 0, alpha: 0.22))
        context.fill(CGRect(x: 0, y: 0, width: s, height: s))
    }
}
