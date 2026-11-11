import AVFoundation

/// The musical recipe for one demo song. Everything is derived from the seed.
nonisolated struct DemoSong: Hashable, Sendable {
    var seed: UInt64
    var bpm: Double
    var bars: Int

    var beat: TimeInterval { 60 / bpm }
    var duration: TimeInterval { Double(bars) * 4 * beat }
    /// Bars of pad-only introduction before the full arrangement starts.
    static let introBars = 2
}

/// Writes a short original instrumental for a demo track, so the demo catalog
/// plays real audio through the same engine, equalizer and lock screen path as
/// local files. Nothing here is recorded music.
nonisolated enum DemoSynth {
    static let sampleRate = 32_000.0

    static func fileURL(for trackID: String) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("DemoAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(trackID)-v1.caf")
    }

    static func renderIfNeeded(_ song: DemoSong, trackID: String) throws -> URL {
        let url = fileURL(for: trackID)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let samples = compose(song)
        let scratch = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".caf")
        try write(samples, to: scratch)
        // Another task may have finished the same song first; either copy is identical.
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: scratch)
        } else {
            try FileManager.default.moveItem(at: scratch, to: url)
        }
        return url
    }

    private static func write(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { throw ProviderError.playback("Couldn't allocate the demo audio buffer.") }
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
    }

    // MARK: Composition

    static func compose(_ song: DemoSong) -> [Float] {
        let rate = sampleRate
        let total = Int(song.duration * rate)
        var mix = [Float](repeating: 0, count: total)
        var random = SeededRandom(seed: song.seed)

        let root = 45 + Int(random.next() % 9)
        let isMinor = random.next() % 3 != 0
        let scale = isMinor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]
        let progressions = isMinor
            ? [[0, 5, 2, 6], [0, 3, 5, 4], [0, 6, 5, 6], [0, 2, 3, 6]]
            : [[0, 4, 5, 3], [0, 5, 3, 4], [1, 4, 0, 5], [0, 3, 0, 4]]
        let progression = progressions[Int(random.next() % UInt64(progressions.count))]
        let arpeggio = [[0, 2, 4, 2, 7, 4, 2, 4], [0, 4, 7, 4, 2, 4, 7, 9], [7, 4, 2, 0, 2, 4, 7, 4]][Int(random.next() % 3)]
        let beat = song.beat

        func frequency(degree: Int, octave: Int) -> Double {
            let note = root + scale[((degree % 7) + 7) % 7] + 12 * (degree / 7 + octave)
            return 440 * pow(2, Double(note - 69) / 12)
        }

        func tone(_ hertz: Double, at start: Double, length: Double, level: Float, attack: Double, decay: Double, bright: Float) {
            let first = Int(start * rate)
            let count = min(Int(length * rate), total - first)
            guard count > 0, first >= 0 else { return }
            let step = Float(2 * Double.pi * hertz / rate)
            let attackFrames = Float(max(attack * rate, 1))
            let releaseFrames = Float(0.03 * rate)
            let decayPerFrame = Float(exp(-decay / rate))
            var envelope: Float = 1
            mix.withUnsafeMutableBufferPointer { out in
                for index in 0..<count {
                    let position = Float(index)
                    let fadeIn = min(1, position / attackFrames)
                    let fadeOut = min(1, Float(count - index) / releaseFrames)
                    let phase = step * position
                    out[first + index] += level * envelope * fadeIn * fadeOut * (sinf(phase) + bright * sinf(2 * phase))
                    envelope *= decayPerFrame
                }
            }
        }

        func kick(at start: Double) {
            let first = Int(start * rate)
            let count = min(Int(0.22 * rate), total - first)
            guard count > 0 else { return }
            var phase: Float = 0
            for index in 0..<count {
                let time = Float(index) / Float(rate)
                let hertz = 48 + 90 * expf(-time * 38)
                phase += 2 * .pi * hertz / Float(rate)
                mix[first + index] += 0.42 * expf(-time * 15) * sinf(phase)
            }
        }

        func hat(at start: Double, level: Float) {
            let first = Int(start * rate)
            let count = min(Int(0.05 * rate), total - first)
            guard count > 0 else { return }
            var previous: Float = 0
            for index in 0..<count {
                let noise = Float(random.unit()) * 2 - 1
                let time = Float(index) / Float(rate)
                // Subtracting the previous sample is a crude high-pass filter.
                mix[first + index] += level * expf(-time * 90) * (noise - previous)
                previous = noise
            }
        }

        var melodyDegree = 4
        for bar in 0..<song.bars {
            let chord = progression[bar % 4]
            let barStart = Double(bar) * 4 * beat
            let isFull = bar >= DemoSong.introBars && bar < song.bars - 2

            for voice in [0, 2, 4] {
                tone(frequency(degree: chord + voice, octave: 1), at: barStart, length: 4 * beat,
                     level: 0.055, attack: 0.3, decay: 0.05, bright: 0.2)
            }
            for position in isFull ? [0.0, 1.5, 2.0, 3.5] : [0.0] {
                tone(frequency(degree: chord, octave: -1), at: barStart + position * beat, length: beat * 0.95,
                     level: 0.2, attack: 0.008, decay: 3, bright: 0.35)
            }
            for (step, offset) in arpeggio.enumerated() where bar >= 1 {
                tone(frequency(degree: chord + offset, octave: 2), at: barStart + Double(step) * beat / 2, length: beat * 0.9,
                     level: isFull ? 0.07 : 0.04, attack: 0.004, decay: 7, bright: 0.15)
            }
            guard isFull else { continue }
            for quarter in 0..<4 {
                kick(at: barStart + Double(quarter) * beat)
                hat(at: barStart + (Double(quarter) + 0.5) * beat, level: 0.09)
            }
            // A wandering lead line in the second half of every eight bars.
            if bar % 8 >= 4 {
                var position = 0.0
                while position < 4 {
                    let length = random.next() % 3 == 0 ? 1.0 : 0.5
                    melodyDegree = min(11, max(0, melodyDegree + Int(random.next() % 5) - 2))
                    let pentatonic = [0, 2, 4, 7, 9, 11, 14][melodyDegree % 7]
                    tone(frequency(degree: pentatonic, octave: 2), at: barStart + position * beat, length: length * beat,
                         level: 0.075, attack: 0.012, decay: 2.2, bright: 0.4)
                    position += length
                }
            }
        }

        // Gentle limiter, then a fade at both ends.
        let fadeIn = Int(0.02 * rate)
        let fadeOut = Int(min(3, song.duration / 4) * rate)
        for index in 0..<total {
            var sample = tanhf(mix[index] * 1.4) * 0.8
            if index < fadeIn { sample *= Float(index) / Float(fadeIn) }
            if index >= total - fadeOut { sample *= Float(total - index) / Float(fadeOut) }
            mix[index] = sample
        }
        return mix
    }
}
