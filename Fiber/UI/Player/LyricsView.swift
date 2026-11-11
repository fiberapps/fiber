import SwiftUI

/// Marks one sung word inside a lyric line, so the renderer can light it up in time.
nonisolated struct WordTiming: TextAttribute {
    var start: TimeInterval
    var end: TimeInterval
}

/// Marks a word that gets a visual effect while it is sung.
nonisolated struct WordEffect: TextAttribute {
    var effect: LyricEffect
    var start: TimeInterval
    var end: TimeInterval
}

nonisolated extension LyricEffect {
    var glow: Color {
        switch self {
        case .fire: Color(red: 1, green: 0.45, blue: 0.1)
        case .cold: Color(red: 0.6, green: 0.85, blue: 1)
        case .rain: Color(red: 0.4, green: 0.65, blue: 1)
        case .star: Color(red: 1, green: 0.95, blue: 0.75)
        case .heart: Color(red: 1, green: 0.35, blue: 0.55)
        case .light: Color(red: 1, green: 0.8, blue: 0.4)
        }
    }

    /// Where the background wash for this mood comes from.
    var washCenter: UnitPoint {
        switch self {
        case .fire: .bottom
        case .cold, .rain, .light: .top
        case .star: .topTrailing
        case .heart: .center
        }
    }
}

extension LyricLine {
    /// Effect words in this line, with the time each one is sung. Lines without
    /// word timing use the whole line's span.
    var effectSpans: [WordEffect] {
        if let words, !words.isEmpty {
            return words.compactMap { word in
                LyricEffectDetector.effect(for: word.text).map { WordEffect(effect: $0, start: word.start, end: word.end) }
            }
        }
        return text.split(separator: " ").compactMap { token in
            LyricEffectDetector.effect(for: String(token)).map { WordEffect(effect: $0, start: start, end: end) }
        }
    }
}

/// Draws a lyric line with each word filling from left to right as it is sung.
/// Words that have no timing are drawn fully lit, so nothing is ever faked.
/// Effect words are layered by context: a shader recolours the glyphs, held
/// words also shed particles, and fire shimmers with heat.
///
/// `nonisolated`: SwiftUI may call `draw` from its render thread, and the module
/// otherwise defaults to the main actor, which traps when called off the main thread.
nonisolated struct KaraokeRenderer: TextRenderer {
    var time: TimeInterval
    var level = LyricEffectLevel.full
    var fill = LyricFillStyle.sweep
    var dimOpacity: Double = 0.35

    /// Room around the text for glow and particles.
    var displayPadding: EdgeInsets { EdgeInsets(top: 48, leading: 26, bottom: 48, trailing: 26) }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                let timing = run[WordTiming.self]
                let effect = level == .off ? nil : run[WordEffect.self]
                guard timing != nil || effect != nil else {
                    context.draw(run)
                    continue
                }
                let progress: Double = timing.map { min(max((time - $0.start) / max($0.end - $0.start, 0.05), 0), 1) } ?? 1
                let bounds = run.typographicBounds.rect

                // Lift and Bounce move the whole word, lit and unlit parts together.
                var base = context
                if let timing {
                    let eased = progress * progress * (3 - 2 * progress)
                    if fill == .lift {
                        base.translateBy(x: 0, y: -3.5 * eased)
                    } else if fill == .bounce, time >= timing.start {
                        let age = time - timing.start
                        let swell = 0.09 * exp(-age * 3.2) * abs(cos(age * 9))
                        base.translateBy(x: bounds.midX, y: bounds.maxY)
                        base.scaleBy(x: 1 + swell, y: 1 + swell)
                        base.translateBy(x: -bounds.midX, y: -bounds.maxY)
                    }
                }

                if progress < 1 {
                    var dim = base
                    dim.opacity = dimOpacity
                    dim.draw(run)
                }
                guard progress > 0 else { continue }

                var lit = base
                if fill == .word, let timing {
                    // The whole word fades up quickly instead of filling.
                    lit.opacity = min((time - timing.start) / 0.12, 1)
                } else if progress < 1 {
                    let softness: CGFloat = 10
                    let edge = bounds.minX + (bounds.width + softness * 2) * progress - softness
                    lit.clipToLayer { layer in
                        layer.fill(
                            Path(bounds.insetBy(dx: -softness * 2, dy: -12)),
                            with: .linearGradient(
                                Gradient(colors: [.white, .white.opacity(0)]),
                                startPoint: CGPoint(x: edge - softness, y: bounds.midY),
                                endPoint: CGPoint(x: edge + softness, y: bounds.midY)))
                    }
                }
                if fill == .glow, let timing {
                    let halo = Self.envelope(time, timing.start, timing.end, release: 0.7)
                    if halo > 0.01 { lit.addFilter(.shadow(color: .white.opacity(0.75 * halo), radius: 9)) }
                }

                if let effect {
                    let strength = Self.envelope(time, effect.start, effect.end)
                    if strength > 0.01 {
                        apply(effect.effect, strength: strength, bounds: bounds, to: &lit)
                    }
                }
                lit.draw(run)

                // Particles only for words held long enough to notice them.
                if let effect, level == .full, effect.end - effect.start >= 0.3 {
                    drawParticles(effect, bounds: bounds, in: &context)
                }
            }
        }
    }

    /// Fades in quickly when the word starts and lingers a little after it ends.
    static func envelope(_ time: TimeInterval, _ start: TimeInterval, _ end: TimeInterval, release: TimeInterval = 1.4) -> Double {
        guard time >= start else { return 0 }
        let attack = min((time - start) / 0.18, 1)
        let fade = time > end ? max(1 - (time - end) / release, 0) : 1
        return attack * fade
    }

    private func apply(_ effect: LyricEffect, strength: Double, bounds: CGRect, to context: inout GraphicsContext) {
        let rect = Shader.Argument.float4(bounds.minX, bounds.minY, bounds.width, bounds.height)
        if effect == .heart {
            let cycle = (time * 1.1).truncatingRemainder(dividingBy: 1)
            let beat = exp(-cycle * 9) + 0.6 * exp(-abs(cycle - 0.28) * 14)
            let scale = 1 + 0.07 * beat * strength
            context.translateBy(x: bounds.midX, y: bounds.midY)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -bounds.midX, y: -bounds.midY)
        }
        if effect == .fire, level == .full {
            context.addFilter(.distortionShader(
                ShaderLibrary.lyricHeat(rect, .float(time), .float(strength)), maxSampleOffset: CGSize(width: 5, height: 5)))
        }
        context.addFilter(.colorShader(
            ShaderLibrary.lyricGlyph(rect, .float(time), .float(Double(effect.rawValue)), .float(strength))))
        context.addFilter(.shadow(color: effect.glow.opacity(0.75 * strength), radius: level == .full ? 12 : 6))
    }

    // MARK: Particles

    /// A repeatable pseudo-random number for particle `index`, so particles
    /// need no stored state and look the same every time the word is sung.
    private func random(_ index: Int, _ salt: Int, _ seed: TimeInterval) -> Double {
        var value = UInt64(bitPattern: Int64(index &* 73_856_093 ^ salt &* 19_349_663 ^ Int(seed * 1000) &* 83_492_791))
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((value ^ (value >> 31)) >> 11) / Double(1 << 53)
    }

    private func drawParticles(_ word: WordEffect, bounds: CGRect, in context: inout GraphicsContext) {
        guard time > word.start, time < word.end + 1.6 else { return }
        let count: Int = switch word.effect {
        case .fire: 22
        case .rain: 16
        case .cold: 14
        case .star: 9
        case .heart: 6
        case .light: 0
        }
        guard count > 0 else { return }
        let span = max(word.end - word.start, 0.3) + 0.3
        var layer = context
        layer.blendMode = .plusLighter
        let heart = word.effect == .heart ? layer.resolve(Image(systemName: "heart.fill")) : nil

        for index in 0..<count {
            let a = random(index, 1, word.start), b = random(index, 2, word.start), c = random(index, 3, word.start)
            let age = time - (word.start + a * span)
            let life = 0.7 + b * 0.7
            guard age > 0, age < life else { continue }
            let fade = sin(age / life * .pi)
            let startX = bounds.minX + bounds.width * c

            switch word.effect {
            case .fire:
                let point = CGPoint(x: startX + sin(age * 6 + b * 6) * 4, y: bounds.minY + bounds.height * 0.4 - age * (38 + b * 30))
                let size = 1.6 + a * 2.4
                let color = Color(red: 1, green: 0.75 - 0.5 * age / life, blue: 0.15)
                layer.fill(Path(ellipseIn: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)),
                           with: .color(color.opacity(fade)))
            case .rain:
                let y = bounds.maxY - 6 + age * (70 + b * 50)
                var drop = Path()
                drop.move(to: CGPoint(x: startX, y: y))
                drop.addLine(to: CGPoint(x: startX - 1.5, y: y + 7 + a * 5))
                layer.stroke(drop, with: .color(Color(red: 0.6, green: 0.82, blue: 1).opacity(fade * 0.8)),
                             style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            case .cold:
                let point = CGPoint(x: startX + sin(age * 2 + a * 6) * 6, y: bounds.minY + bounds.height * b + age * 14)
                let size = 1.5 + a * 2.2
                layer.fill(Path(ellipseIn: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)),
                           with: .color(.white.opacity(fade * 0.8)))
            case .star:
                let center = CGPoint(x: bounds.minX - 12 + (bounds.width + 24) * c, y: bounds.minY - 10 + (bounds.height + 20) * b)
                let reach = (3 + a * 6) * fade
                var star = Path()
                for arm in 0..<4 {
                    let angle = Double(arm) * .pi / 2
                    let tip = CGPoint(x: center.x + cos(angle) * reach, y: center.y + sin(angle) * reach)
                    let side = angle + .pi / 4
                    let notch = CGPoint(x: center.x + cos(side) * reach * 0.22, y: center.y + sin(side) * reach * 0.22)
                    if arm == 0 { star.move(to: tip) } else { star.addLine(to: tip) }
                    star.addLine(to: notch)
                }
                star.closeSubpath()
                layer.fill(star, with: .color(Color(red: 1, green: 0.96, blue: 0.8).opacity(fade)))
            case .heart:
                guard var symbol = heart else { continue }
                symbol.shading = .color(Color(red: 1, green: 0.4, blue: 0.6).opacity(fade * 0.85))
                let size = 8 + a * 8
                let point = CGPoint(x: startX + sin(age * 3 + b * 6) * 5, y: bounds.minY - age * 28)
                layer.draw(symbol, in: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size))
            case .light:
                break
            }
        }
    }
}

/// Time-synced lyrics: the current line is sharp and bright, its neighbours
/// fade and blur with distance, and the list follows the song.
struct LyricsView: View {
    let lyrics: Lyrics
    let isPlaying: Bool
    /// The exact playback position, read every frame.
    let clock: () -> TimeInterval
    /// Nil when the service can't seek; lines are then not tappable.
    let onSeek: ((TimeInterval) -> Void)?
    var effects = LyricEffectLevel.full
    var fill = LyricFillStyle.sweep
    var textSize = LyricTextSize.medium
    var fontScale: Double = 1
    /// Reports the effect word being sung, so the background can react. Nil when none.
    var onMood: (LyricEffect?) -> Void = { _ in }

    @State private var activeIndex: Int?
    @State private var mood: LyricEffect?
    @State private var position = ScrollPosition(idType: Int.self)
    /// While the user is browsing the lyrics, auto-scroll and blur step aside.
    @State private var isBrowsing = false
    @State private var browsingTask: Task<Void, Never>?
    /// Top edge of every line inside the list, used to measure how far a line change travels.
    @State private var tops: [Int: CGFloat] = [:]
    /// The distance the list just jumped. Each line starts displaced by it and
    /// springs home on its own delay, which makes lines trail one after another.
    @State private var lag: CGFloat = 0
    @State private var followedID: Int?
    @State private var followTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Lines change a touch early, so the move finishes as the line begins.
    private let anticipation: TimeInterval = 0.16
    private let anchor = UnitPoint(x: 0.5, y: 0.14)
    private var isSynced: Bool { lyrics.timing != .unsynced }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if isSynced, let first = lyrics.lines.first, first.start > 3 {
                    IntroDots(end: first.start, clock: clock, isPlaying: isPlaying)
                        .opacity(activeIndex == nil ? 1 : 0)
                        .id(-1)
                }
                ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { index, line in
                    LyricLineView(line: line, state: lineState(index), isPlaying: isPlaying, effects: effects, fill: fill, textSize: textSize, fontScale: fontScale, clock: clock)
                        .offset(y: lag)
                        .transaction(value: lag) { transaction in
                            // Jumping to the displaced position is instant; returning home is a staggered spring.
                            let trailing = max(index - (activeIndex ?? 0), 0)
                            transaction.animation = lag == 0
                                ? .spring(duration: 0.62, bounce: 0.2).delay(min(Double(trailing) * 0.045, 0.36))
                                : nil
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("lyricLines")).minY } action: { tops[line.id] = $0 }
                        .id(line.id)
                        .contentShape(.rect)
                        .onTapGesture {
                            guard isSynced, let onSeek else { return }
                            onSeek(line.start)
                            endBrowsing()
                        }
                        .accessibilityAddTraits(isSynced && onSeek != nil ? .isButton : [])
                }
                VStack(alignment: .leading, spacing: 5) {
                    if let url = lyrics.sourceURL { Link(lyrics.source, destination: url) }
                    else { Text(lyrics.source) }
                    if let name = lyrics.contributor, let url = lyrics.contributorURL {
                        Link("Submitted by \(name)", destination: url)
                    }
                    if lyrics.estimatedWordTiming == true { Text("Word timing estimated") }
                }
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 16)
            }
            .scrollTargetLayout()
            .coordinateSpace(.named("lyricLines"))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 30)
            // Enough room above the first line for it to reach the reading position.
            .padding(.top, 104)
            .padding(.bottom, 420)
        }
        .scrollPosition($position, anchor: anchor)
        .scrollIndicators(.hidden)
        .mask {
            LinearGradient(stops: [
                .init(color: .clear, location: 0), .init(color: .black, location: 0.07),
                .init(color: .black, location: 0.72), .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .onScrollPhaseChange { _, phase in
            if phase == .interacting { beginBrowsing() }
        }
        .onDisappear {
            browsingTask?.cancel()
            followTask?.cancel()
            onMood(nil)
        }
        .task(id: lyrics) {
            followTask?.cancel()
            browsingTask?.cancel()
            lag = 0
            followedID = nil
            isBrowsing = false
            activeIndex = nil
            guard isSynced else { return }
            // Follow the song. Checking 30 times a second keeps line changes on the beat.
            var spans: [WordEffect] = []
            while !Task.isCancelled {
                let time = clock()
                let current = lyrics.activeIndex(at: time + anticipation)
                if current != activeIndex {
                    activeIndex = current
                    spans = current.map { lyrics.lines[$0].effectSpans } ?? []
                    if !isBrowsing { follow(current) }
                }
                let sung = effects == .full ? spans.first { time >= $0.start - 0.05 && time <= $0.end + 1.0 }?.effect : nil
                if sung != mood {
                    mood = sung
                    onMood(sung)
                }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func lineState(_ index: Int) -> LyricLineView.LineState {
        guard isSynced else { return .plain }
        guard let activeIndex else { return .away(distance: index + 1, focused: !isBrowsing) }
        if index == activeIndex { return .active }
        return .away(distance: abs(index - activeIndex), focused: !isBrowsing)
    }

    private func follow(_ index: Int?) {
        followTask?.cancel()
        let target = index.map { lyrics.lines[$0].id } ?? (lyrics.lines.first.map { $0.start > 3 ? -1 : $0.id } ?? 0)
        defer { followedID = target }
        // Staggered move: the list jumps to its new place at once, every line is
        // shifted back by the same distance, then each one springs home in turn.
        if !reduceMotion, let previous = followedID, previous != target,
           let from = tops[previous], let to = tops[target], abs(to - from) < 900 {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                position.scrollTo(id: target, anchor: anchor)
                lag = to - from
            }
            followTask = Task {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
                lag = 0
            }
        } else {
            lag = 0
            withAnimation(reduceMotion ? nil : .spring(duration: 0.75, bounce: 0.12)) {
                position.scrollTo(id: target, anchor: anchor)
            }
        }
    }

    private func beginBrowsing() {
        withAnimation(.easeOut(duration: 0.25)) { isBrowsing = true }
        browsingTask?.cancel()
        browsingTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            endBrowsing()
        }
    }

    private func endBrowsing() {
        browsingTask?.cancel()
        withAnimation(.easeInOut(duration: 0.4)) { isBrowsing = false }
        follow(activeIndex)
    }
}

struct LyricLineView: View {
    enum LineState: Equatable {
        /// Unsynced lyrics: every line reads the same.
        case plain
        case active
        /// `focused` is false while the user scrolls, which clears the blur.
        case away(distance: Int, focused: Bool)
    }

    let line: LyricLine
    let state: LineState
    let isPlaying: Bool
    var effects = LyricEffectLevel.full
    var fill = LyricFillStyle.sweep
    var textSize = LyricTextSize.medium
    var fontScale: Double = 1
    let clock: () -> TimeInterval

    /// The line as separate word runs, each tagged with its timing and effect.
    private var taggedText: (text: Text, isAnimated: Bool) {
        // Japanese and Chinese lines are written without spaces between words.
        let separator = line.preservesWordSpacing == true ? "" : (line.text.contains(" ") ? " " : "")
        let tokens: [(text: String, timing: WordTiming?)] = if let words = line.words, !words.isEmpty {
            words.map { ($0.text, WordTiming(start: $0.start, end: $0.end)) }
        } else {
            line.text.split(separator: " ").map { (String($0), nil) }
        }
        var hasEffect = false
        let text = tokens.enumerated().reduce(Text("")) { partial, entry in
            let token = entry.element
            var word = Text(token.text + (entry.offset == tokens.count - 1 ? "" : separator))
            if let timing = token.timing { word = word.customAttribute(timing) }
            if effects != .off, let effect = LyricEffectDetector.effect(for: token.text) {
                hasEffect = true
                word = word.customAttribute(WordEffect(effect: effect, start: token.timing?.start ?? line.start,
                                                       end: token.timing?.end ?? line.end))
            }
            return Text("\(partial)\(word)")
        }
        return (text, line.words?.isEmpty == false || hasEffect)
    }

    var body: some View {
        Group {
            switch state {
            case .active:
                let tagged = taggedText
                if tagged.isAnimated {
                    TimelineView(.animation(paused: !isPlaying)) { _ in
                        tagged.text.textRenderer(KaraokeRenderer(time: clock(), level: effects, fill: fill))
                    }
                } else {
                    Text(line.text)
                }
            case .plain:
                Text(line.text)
            case .away(let distance, let focused):
                Text(line.text)
                    .opacity(focused ? max(0.42 - Double(distance) * 0.05, 0.16) : 0.55)
                    .blur(radius: focused ? min(CGFloat(distance) * 1.3 + 0.6, 5) : 0)
            }
        }
        .font(.system(size: textSize.points * fontScale, weight: .bold))
        .lineSpacing(1)
        .foregroundStyle(.white)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.spring(duration: 0.6, bounce: 0.1), value: state)
    }
}

/// The three breathing dots shown during an instrumental introduction.
private struct IntroDots: View {
    let end: TimeInterval
    let clock: () -> TimeInterval
    let isPlaying: Bool

    var body: some View {
        TimelineView(.animation(paused: !isPlaying)) { _ in
            let time = clock()
            let progress = min(max(time / max(end, 0.1), 0), 1)
            let breath = 1 + 0.08 * sin(time * 2.2)
            HStack(spacing: 7) {
                ForEach(0..<3, id: \.self) { index in
                    let fill = min(max(progress * 3 - Double(index), 0), 1)
                    Circle()
                        .fill(.white.opacity(0.3 + 0.7 * fill))
                        .frame(width: 11, height: 11)
                }
            }
            .scaleEffect(breath, anchor: .leading)
            .frame(height: 30)
        }
        .accessibilityLabel("Instrumental")
    }
}
