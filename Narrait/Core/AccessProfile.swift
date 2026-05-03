import Foundation

enum AccessProfile: String, CaseIterable {
    case `default` = "default"
    case vision = "lowVision"
    case dyslexia = "dyslexia"
    case plainEnglish = "languageLearner"

    var displayName: String {
        switch self {
        case .default: return "Default"
        case .vision: return "Blind / Low Vision"
        case .dyslexia: return "Dyslexia"
        case .plainEnglish: return "Language Support"
        }
    }

    // Clause appended to base rubric in every Claude request.
    var systemPromptClause: String {
        switch self {
        case .default:
            return "Profile: Default. Use clear, practical language. Keep answers concise, but give enough context for the user to act confidently."
        case .vision:
            return "Profile: Blind / Low Vision. Emphasize spatial layout and relative positions. When pointing, Narrait shows a buddy cursor that moves from the user's cursor to the target. Give complete spoken visual descriptions with layout, colors, icons, visible text, and relative positions when helpful."
        case .dyslexia:
            return "Profile: Dyslexia. Use very short sentences. No long words if a short word works. No bullet points in TTS-delivered content. Keep it conversational and simple."
        case .plainEnglish:
            return "Profile: Language Support. Define idioms, jargon, technical terms, bureaucratic wording, and medical wording inline in everyday language. Use simple sentence structure."
        }
    }

    // TTS speed multiplier (1.0 = normal).
    var ttsSpeed: Double {
        switch self {
        case .dyslexia: return 0.5
        default: return 1.0
        }
    }

    // Whether the cursor should warp to point_to coordinates.
    var shouldWarpCursor: Bool {
        self == .vision
    }

    static var current: AccessProfile {
        get {
            let raw = UserDefaults.standard.string(forKey: "narrait.activeProfile") ?? AccessProfile.default.rawValue
            if let profile = AccessProfile(rawValue: raw) {
                return profile
            }

            switch raw {
            case "blind":
                return .vision
            case "cognitive":
                return .default
            default:
                return .default
            }
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "narrait.activeProfile")
        }
    }
}
