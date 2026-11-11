import SwiftUI

struct SettingsScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var isImporting = false
    @State private var message: String?

    var body: some View {
        @Bindable var settings = app.settings
        NavigationStack {
            Form {
                Section {
                    ForEach(AppModel.streamingServices) { service in
                        ServiceSettingsRow(service: service)
                    }
                } header: {
                    Text("Music Services")
                } footer: {
                    Text("A service that is off is never contacted and never asks for permission.")
                }

                Section {
                    Picker("Default Music Service", selection: $settings.defaultService) {
                        ForEach(app.defaultServiceChoices) { Text($0.displayName).tag($0) }
                    }
                    .disabled(app.defaultServiceChoices.count < 2)
                    Toggle("Demo Catalog", isOn: $settings.isDemoCatalogEnabled)
                } footer: {
                    Text("Home, New, Radio and Search show the default service. The demo catalog is invented music synthesized on this iPhone, for trying Fiber without an account. It is always labelled as a demo.")
                }

                Section {
                    NavigationLink {
                        EqualizerScreen()
                    } label: {
                        LabeledContent("Equalizer", value: settings.equalizer.isEnabled ? (settings.equalizer.presetName ?? "Custom") : "Off")
                    }
                } header: {
                    Text("Playback")
                } footer: {
                    Text("The equalizer shapes audio Fiber plays itself: your files and the demo catalog. Streaming services play through their own players, which Fiber cannot process.")
                }

                Section {
                    Toggle("Online Lyrics", isOn: $settings.usesOnlineLyrics)
                    NavigationLink {
                        LyricStyleScreen()
                    } label: {
                        LabeledContent("Word Fill", value: settings.lyricFill.title)
                    }
                    Picker("Text Size", selection: $settings.lyricTextSize) {
                        ForEach(LyricTextSize.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Word Effects", selection: $settings.lyricEffects) {
                        ForEach(LyricEffectLevel.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Lyrics")
                } footer: {
                    Text("Online Lyrics checks Unison for community word timing, then LRCLIB, sending song metadata. When only line timestamps exist, word filling is estimated and labelled beneath the lyrics. Plain lyrics remain unsynced.\n\nWords like fire, rain, star, heart, cold and gold come alive as they are sung, in English, Portuguese, Spanish, French, German, Italian, Korean, Japanese and Chinese. Subtle only recolours the word. Full adds particles and lets the background react. Reduce Motion always uses Subtle.")
                }

                Section {
                    LabeledContent("Songs on This iPhone", value: "\(app.library.localTracks.count)")
                    Button("Import Files or Folders") { isImporting = true }
                    Button("Rescan Music Folder") {
                        Task { message = await app.local.rescan().summary }
                    }
                } header: {
                    Text("Local Files")
                } footer: {
                    Text("MP3, AAC, ALAC, FLAC, WAV and AIFF. A .lrc file with the same name as a song gives it synced lyrics. Files live in Fiber's Music folder in the Files app.")
                }

                if let problem = app.library.storageProblem {
                    Section("Storage") {
                        Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                }
            }
            .tint(Theme.accent)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: LocalProvider.importTypes, allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): Task { message = await app.local.importItems(at: urls).summary }
                case .failure(let error): message = "The files couldn't be opened (\(error.localizedDescription))."
                }
            }
            .alert("Local Files", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// One streaming service: its switch, its real status, and account controls
/// once it is on.
private struct ServiceSettingsRow: View {
    let service: ServiceID

    @Environment(AppModel.self) private var app

    var body: some View {
        let row = app.serviceRow(service)
        let isOn = app.settings.enabledServices.contains(service)
        VStack(alignment: .leading, spacing: 6) {
            Toggle(service.displayName, isOn: Binding(
                get: { isOn },
                set: { enabled in
                    if enabled {
                        app.settings.enabledServices.insert(service)
                        app.syncStreamingProviders()
                    } else {
                        app.settings.enabledServices.remove(service)
                        Task { await app.serviceDisabled(service) }
                    }
                }))
            if isOn {
                Text(row.connection.statusText)
                    .font(.footnote)
                    .foregroundStyle(row.connection.isUsable ? Color.green : Color.secondary)
                if !row.capabilities.summary.isEmpty {
                    Text(row.capabilities.summary).font(.footnote).foregroundStyle(.secondary)
                }
                if service == .spotify, row.connection.isUsable {
                    Button("Open Browser Player") {
                        _ = try? app.provider(for: .spotify)?.makeEngine()
                        app.isSettingsPresented = false
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(400))
                            SpotifyWebEngine.shared.isPresented = true
                        }
                    }
                }
                switch row.connection {
                case .disconnected, .failed:
                    Button("Connect") { Task { await app.connect(service) } }
                case .connected, .limited:
                    Button("Disconnect", role: .destructive) { Task { await app.disconnect(service) } }
                case .connecting:
                    ProgressView()
                case .notRequired, .unavailable:
                    EmptyView()
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct EqualizerScreen: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Toggle("Equalizer", isOn: $settings.equalizer.isEnabled)
                Picker("Preset", selection: Binding(
                    get: { settings.equalizer.presetName ?? "Custom" },
                    set: { name in
                        guard let preset = EqualizerSettings.presets.first(where: { $0.name == name }) else { return }
                        settings.equalizer.gains = preset.gains
                        settings.equalizer.presetName = preset.name
                    })
                ) {
                    if settings.equalizer.presetName == nil { Text("Custom").tag("Custom") }
                    ForEach(EqualizerSettings.presets, id: \.name) { Text($0.name).tag($0.name) }
                }
            }
            Section("Bands") {
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(EqualizerSettings.frequencies.indices, id: \.self) { index in
                        BandSlider(
                            label: Self.label(EqualizerSettings.frequencies[index]),
                            value: Binding(
                                get: { settings.equalizer.gains[index] },
                                set: {
                                    settings.equalizer.gains[index] = $0
                                    settings.equalizer.presetName = nil
                                }))
                    }
                }
                .frame(height: 230)
                .padding(.vertical, 6)
                .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
            }
            Section {
                LabeledContent("Preamp") {
                    Slider(value: $settings.equalizer.preamp, in: EqualizerSettings.gainRange, step: 0.5)
                }
                LabeledContent("Preamp Gain", value: String(format: "%+.1f dB", settings.equalizer.preamp))
            } footer: {
                Text("Lower the preamp if boosted bands make loud songs distort.")
            }
        }
        .tint(Theme.accent)
        .disabled(false)
        .navigationTitle("Equalizer")
        .onChange(of: settings.equalizer) { app.applyEqualizer() }
    }

    private static func label(_ hertz: Float) -> String {
        hertz >= 1000 ? "\(Int(hertz / 1000))k" : "\(Int(hertz))"
    }
}

/// A vertical gain slider for one equalizer band.
private struct BandSlider: View {
    let label: String
    @Binding var value: Float

    private let range = EqualizerSettings.gainRange

    var body: some View {
        VStack(spacing: 6) {
            Text(String(format: "%+.0f", value))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
            GeometryReader { proxy in
                let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
                let y = proxy.size.height * (1 - fraction)
                ZStack(alignment: .top) {
                    Capsule().fill(Color(white: 0.25)).frame(width: 4)
                    Rectangle().fill(Color(white: 0.4)).frame(width: 12, height: 1).offset(y: proxy.size.height / 2)
                    Capsule().fill(Theme.accent)
                        .frame(width: 4, height: abs(y - proxy.size.height / 2))
                        .offset(y: min(y, proxy.size.height / 2))
                    Circle().fill(.white)
                        .frame(width: 20, height: 20)
                        .shadow(radius: 2)
                        .offset(y: y - 10)
                }
                .frame(maxWidth: .infinity)
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    let position = 1 - min(max(drag.location.y / proxy.size.height, 0), 1)
                    let raw = range.lowerBound + Float(position) * (range.upperBound - range.lowerBound)
                    value = (raw * 2).rounded() / 2
                })
            }
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel("\(label) hertz")
        .accessibilityValue(String(format: "%+.1f decibels", value))
        .accessibilityAdjustableAction { direction in
            value = min(max(value + (direction == .increment ? 1 : -1), range.lowerBound), range.upperBound)
        }
    }
}

/// Choose how words fill, with a looping sample of each style.
struct LyricStyleScreen: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            Section {
                ForEach(LyricFillStyle.allCases) { style in
                    Button {
                        app.settings.lyricFill = style
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(style.title).font(.headline)
                                Spacer()
                                if app.settings.lyricFill == style {
                                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Theme.accent)
                                }
                            }
                            FillPreview(style: style)
                            Text(style.summary).font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(app.settings.lyricFill == style ? .isSelected : [])
                }
            } footer: {
                Text("Styles apply wherever a song has word timing, whether supplied or estimated.")
            }
        }
        .navigationTitle("Word Fill")
        .sensoryFeedback(.selection, trigger: app.settings.lyricFill)
    }
}

/// A short phrase that keeps singing itself in the given style.
private struct FillPreview: View {
    let style: LyricFillStyle

    private static let words = ["Every", "word", "in", "its", "own", "time"]
    private static let step = 0.42

    private var text: Text {
        Self.words.enumerated().reduce(Text("")) { partial, entry in
            let start = 0.3 + Double(entry.offset) * Self.step
            let word = Text(entry.element + (entry.offset == Self.words.count - 1 ? "" : " "))
                .customAttribute(WordTiming(start: start, end: start + Self.step))
            return Text("\(partial)\(word)")
        }
    }

    var body: some View {
        let sample = text
        TimelineView(.animation) { timeline in
            let loop = 0.3 + Double(Self.words.count) * Self.step + 1.1
            let time = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: loop)
            sample.textRenderer(KaraokeRenderer(time: time, level: .off, fill: style))
        }
        .font(.system(size: 24, weight: .bold))
        .foregroundStyle(.white)
        .accessibilityHidden(true)
    }
}
