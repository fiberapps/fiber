import SwiftUI

nonisolated enum AppearanceChoice: String, CaseIterable, Identifiable, Sendable {
    case dark, light, system

    var id: String { rawValue }
    var title: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .system: "Match System"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }
}

nonisolated enum LibrarySection: String, CaseIterable, Identifiable, Codable, Sendable {
    case playlists, artists, albums, songs, downloaded

    var id: String { rawValue }
    var title: String {
        switch self {
        case .playlists: "Playlists"
        case .artists: "Artists"
        case .albums: "Albums"
        case .songs: "Songs"
        case .downloaded: "Downloaded"
        }
    }
    var symbol: String {
        switch self {
        case .playlists: "music.note.list"
        case .artists: "music.microphone"
        case .albums: "square.stack"
        case .songs: "music.note"
        case .downloaded: "arrow.down.circle"
        }
    }
}

/// User preferences, saved to UserDefaults the moment they change.
/// Account secrets never go here; those belong in the Keychain.
@Observable
final class SettingsStore {
    @ObservationIgnored private let defaults: UserDefaults

    /// Streaming services the user has switched on. A service that is off is
    /// never asked for authorization and never initialised.
    var enabledServices: Set<ServiceID> { didSet { save(enabledServices.map(\.rawValue).sorted(), "enabledServices") } }
    var isDemoCatalogEnabled: Bool { didSet { save(isDemoCatalogEnabled, "demoCatalog") } }
    var defaultService: ServiceID { didSet { save(defaultService.rawValue, "defaultService") } }
    var appearance: AppearanceChoice { didSet { save(appearance.rawValue, "appearance") } }
    /// Whether songs without their own lyrics are looked up on LRCLIB.
    var usesOnlineLyrics: Bool { didSet { save(usesOnlineLyrics, "onlineLyrics") } }
    var lyricFill: LyricFillStyle { didSet { save(lyricFill.rawValue, "lyricFill") } }
    var lyricTextSize: LyricTextSize { didSet { save(lyricTextSize.rawValue, "lyricTextSize") } }
    var lyricEffects: LyricEffectLevel { didSet { save(lyricEffects.rawValue, "lyricEffects") } }
    var equalizer: EqualizerSettings { didSet { saveJSON(equalizer, "equalizer") } }
    var hiddenLibrarySections: Set<LibrarySection> { didSet { save(hiddenLibrarySections.map(\.rawValue).sorted(), "hiddenLibrarySections") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let services = (defaults.stringArray(forKey: "enabledServices") ?? []).compactMap(ServiceID.init(rawValue:))
        enabledServices = Set(services)
        isDemoCatalogEnabled = defaults.object(forKey: "demoCatalog") as? Bool ?? true
        defaultService = defaults.string(forKey: "defaultService").flatMap(ServiceID.init(rawValue:)) ?? .demo
        appearance = defaults.string(forKey: "appearance").flatMap(AppearanceChoice.init(rawValue:)) ?? .dark
        usesOnlineLyrics = defaults.object(forKey: "onlineLyrics") as? Bool ?? true
        lyricFill = defaults.string(forKey: "lyricFill").flatMap(LyricFillStyle.init(rawValue:)) ?? .sweep
        lyricTextSize = defaults.string(forKey: "lyricTextSize").flatMap(LyricTextSize.init(rawValue:)) ?? .medium
        lyricEffects = defaults.string(forKey: "lyricEffects").flatMap(LyricEffectLevel.init(rawValue:)) ?? .full
        if let data = defaults.data(forKey: "equalizer"), let saved = try? JSONDecoder().decode(EqualizerSettings.self, from: data) {
            equalizer = saved
        } else {
            equalizer = EqualizerSettings()
        }
        let hidden = (defaults.stringArray(forKey: "hiddenLibrarySections") ?? []).compactMap(LibrarySection.init(rawValue:))
        hiddenLibrarySections = Set(hidden)
    }

    func isEnabled(_ service: ServiceID) -> Bool {
        switch service {
        case .local: true
        case .demo: isDemoCatalogEnabled
        default: enabledServices.contains(service)
        }
    }

    private func save(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }

    private func saveJSON(_ value: some Encodable, _ key: String) {
        // Encoding these plain value types cannot fail; a nil here would only skip the write.
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
