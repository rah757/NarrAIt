import Foundation

// Loads API keys from a bundled .env file at launch and caches them in UserDefaults.
// Despite living in Core/, this is plain UserDefaults — no macOS Keychain item
// management. Fine for the hackathon binary; if we ever distribute, swap to Keychain.
enum APIKeyStore {
    private static let geminiKeyUD = "narrait.geminiKey"
    private static let geminiRouterModelUD = "narrait.geminiRouterModel"
    private static let anthropicKeyUD = "narrait.anthropicKey"
    private static let anthropicModelUD = "narrait.anthropicModel"
    private static let groqKeyUD = "narrait.groqKey"

    static var geminiKey: String {
        get { UserDefaults.standard.string(forKey: geminiKeyUD) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: geminiKeyUD) }
    }

    static var geminiRouterModel: String {
        get { UserDefaults.standard.string(forKey: geminiRouterModelUD) ?? "gemini-3-flash-preview" }
        set { UserDefaults.standard.set(newValue, forKey: geminiRouterModelUD) }
    }

    static var anthropicKey: String {
        get { UserDefaults.standard.string(forKey: anthropicKeyUD) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: anthropicKeyUD) }
    }

    static var anthropicModel: String {
        get { UserDefaults.standard.string(forKey: anthropicModelUD) ?? "claude-sonnet-4-6" }
        set { UserDefaults.standard.set(newValue, forKey: anthropicModelUD) }
    }

    static var groqKey: String {
        get { UserDefaults.standard.string(forKey: groqKeyUD) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: groqKeyUD) }
    }

    // Call once at app launch. Reads a .env file bundled in the app (Resources/.env)
    // and refreshes UserDefaults so key rotations don't leave the app using stale keys.
    static func loadFromBundleIfNeeded() {
        guard let envURL = Bundle.main.url(forResource: ".env", withExtension: nil),
              let contents = try? String(contentsOf: envURL, encoding: .utf8) else {
            print("⚠️ Narrait: No .env file found in bundle")
            return
        }

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.components(separatedBy: "=")
            guard parts.count >= 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts.dropFirst().joined(separator: "=")
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

            switch key {
            case "GEMINI_API_KEY":
                if !value.isEmpty, geminiKey != value { geminiKey = value }
            case "GEMINI_ROUTER_MODEL", "GEMINI_MODEL":
                if !value.isEmpty, geminiRouterModel != value { geminiRouterModel = value }
            case "ANTHROPIC_API_KEY", "CLAUDE_API_KEY":
                if !value.isEmpty, anthropicKey != value { anthropicKey = value }
            case "ANTHROPIC_MODEL", "CLAUDE_MODEL":
                if !value.isEmpty, anthropicModel != value { anthropicModel = value }
            case "GROQ_API_KEY":
                if !value.isEmpty, groqKey != value { groqKey = value }
            default:
                break
            }
        }
        print("✅ Narrait: API keys loaded from .env")
    }
}
