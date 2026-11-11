import Foundation

/// A visual treatment for a sung word that names something vivid.
nonisolated enum LyricEffect: Int, CaseIterable, Sendable {
    // The raw values are the `kind` the Metal shader switches on.
    case fire = 0, cold, rain, star, heart, light
}

nonisolated enum LyricEffectLevel: String, CaseIterable, Identifiable, Sendable {
    case off, subtle, full

    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "Off"
        case .subtle: "Subtle"
        case .full: "Full"
        }
    }
}

/// Finds effect words in lyrics. Latin-script languages match whole words
/// (after removing accents), so "star" never fires on "start". Chinese and
/// Japanese match on the leading character; Korean matches a noun plus an
/// optional particle, so 비 (rain) doesn't fire on 비춰요 (shines).
nonisolated enum LyricEffectDetector {
    private static let words: [LyricEffect: Set<String>] = [
        .fire: ["fire", "fires", "flame", "flames", "burn", "burns", "burning", "burned", "blaze", "ember", "embers", "wildfire",
                "fogo", "chama", "chamas", "queima", "queimar", "queimando", "arde", "ardendo", "brasa", "incendio",
                "fuego", "llama", "llamas", "arder", "ardiendo", "quema", "quemar", "quemando",
                "feu", "flamme", "flammes", "brule", "bruler", "feuer", "brennt", "brennen", "fuoco", "fiamma", "brucia"],
        .cold: ["cold", "ice", "icy", "frozen", "freeze", "freezing", "frost", "snow", "winter",
                "frio", "fria", "gelo", "gelado", "gelada", "neve", "inverno",
                "hielo", "helado", "helada", "nieve", "invierno",
                "froid", "glace", "neige", "hiver", "kalt", "eis", "schnee", "freddo", "ghiaccio"],
        .rain: ["rain", "rains", "raining", "rainy", "storm", "tears", "teardrops", "crying",
                "chuva", "chove", "chovendo", "tempestade", "lagrimas", "chorar", "chorando",
                "lluvia", "llueve", "lloviendo", "tormenta", "llorar", "llorando",
                "pluie", "larmes", "orage", "regen", "tranen", "pioggia", "lacrime"],
        .star: ["star", "stars", "starlight", "starry", "galaxy", "constellation",
                "estrela", "estrelas", "estrella", "estrellas", "etoile", "etoiles", "stern", "sterne", "stella", "stelle"],
        .heart: ["heart", "hearts", "heartbeat", "coracao", "coracoes", "corazon", "corazones", "coeur", "herz", "cuore"],
        .light: ["gold", "golden", "sun", "sunlight", "sunshine", "sunrise", "shine", "shining", "glow", "glowing", "dawn",
                 "ouro", "dourado", "dourada", "sol", "brilha", "brilho", "amanhecer",
                 "oro", "dorado", "dorada", "brilla", "amanecer", "soleil", "sonne", "sole", "luce"],
    ]

    private static let leadingCharacters: [LyricEffect: [String]] = [
        .fire: ["火", "炎", "燃", "焔"],
        .cold: ["冷", "氷", "雪", "凍", "寒", "冰"],
        .rain: ["雨", "涙", "泪", "淚"],
        .star: ["星"],
        .heart: ["心", "ハート"],
        .light: ["光", "太陽", "太阳", "輝", "金"],
    ]

    private static let koreanNouns: [LyricEffect: [String]] = [
        .fire: ["불", "불꽃", "불길", "불빛"],
        .cold: ["차가운", "추운", "얼음", "눈꽃", "겨울"],
        .rain: ["비", "빗물", "빗방울", "눈물"],
        .star: ["별", "별빛"],
        .heart: ["심장", "마음", "가슴"],
        .light: ["빛", "햇살", "태양", "황금"],
    ]

    private static let koreanParticles: Set<String> = [
        "", "이", "가", "은", "는", "을", "를", "에", "도", "의", "과", "와", "로", "으로", "만", "처럼", "같이", "이야", "야", "에서",
    ]

    static func effect(for word: String) -> LyricEffect? {
        let folded = word.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let cleaned = folded.trimmingCharacters(in: .punctuationCharacters.union(.symbols).union(.whitespaces))
        guard !cleaned.isEmpty else { return nil }

        for effect in LyricEffect.allCases {
            if words[effect]?.contains(cleaned) == true { return effect }
        }
        // Possessives and elisions: "fire's", "l'étoile".
        if let apostrophe = cleaned.firstIndex(where: { "'’".contains($0) }) {
            let before = String(cleaned[..<apostrophe])
            let after = String(cleaned[cleaned.index(after: apostrophe)...])
            for effect in LyricEffect.allCases where words[effect]?.contains(before) == true || words[effect]?.contains(after) == true {
                return effect
            }
        }
        for effect in LyricEffect.allCases {
            if leadingCharacters[effect]?.contains(where: cleaned.hasPrefix) == true { return effect }
            for noun in koreanNouns[effect] ?? [] where cleaned.hasPrefix(noun) {
                if koreanParticles.contains(String(cleaned.dropFirst(noun.count))) { return effect }
            }
        }
        return nil
    }
}

/// How a word lights up while it is sung.
nonisolated enum LyricFillStyle: String, CaseIterable, Identifiable, Sendable {
    case sweep, word, glow, lift, bounce

    var id: String { rawValue }
    var title: String {
        switch self {
        case .sweep: "Sweep"
        case .word: "Word by Word"
        case .glow: "Glow"
        case .lift: "Lift"
        case .bounce: "Bounce"
        }
    }
    var summary: String {
        switch self {
        case .sweep: "Light moves across each word from left to right."
        case .word: "Each word lights up whole, the moment it starts."
        case .glow: "The sweep, with a soft halo on the word being sung."
        case .lift: "Words rise slightly as they fill and stay raised."
        case .bounce: "Each word swells and settles as it is sung."
        }
    }
}

nonisolated enum LyricTextSize: String, CaseIterable, Identifiable, Sendable {
    case small, medium, large

    var id: String { rawValue }
    var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }
    var points: Double {
        switch self {
        case .small: 25
        case .medium: 31
        case .large: 37
        }
    }
}
