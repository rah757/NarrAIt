import Foundation

// Appends structured call records to per-API JSON log files.
// Files live in ~/Library/Logs/Narrait/{gemini,groq,gemini_tts}.json
// Each file is a JSON array; new entries are appended on every call.
//
// Thread-safe: all disk I/O is serialised through a dedicated serial queue.
enum APILogger {

    // MARK: - Public entry types

    struct GeminiEntry: Codable {
        let timestamp: String
        let model: String
        let systemPrompt: String
        let conversationHistory: [HistoryTurn]
        let userPrompt: String
        let imageCount: Int
        let output: String
        let finishReason: String
        let inputTokens: Int
        let outputTokens: Int
        let totalTokens: Int
        let durationSeconds: Double

        struct HistoryTurn: Codable {
            let user: String
            let assistant: String
        }
    }

    struct GroqEntry: Codable {
        let timestamp: String
        let model: String
        let audioSizeKB: Int
        let transcript: String
        let output: String
        let audioDurationSeconds: Double
        let durationSeconds: Double
    }

    struct GeminiTTSEntry: Codable {
        let timestamp: String
        let model: String
        let voiceID: String
        let inputText: String
        let characterCount: Int
        let speed: String
        let output: String
        let audioSizeKB: Int
        let durationSeconds: Double
    }

    // MARK: - Public append methods

    static func logGemini(_ entry: GeminiEntry) {
        append(entry, to: "gemini")
    }

    static func logGroq(_ entry: GroqEntry) {
        append(entry, to: "groq")
    }

    static func logGeminiTTS(_ entry: GeminiTTSEntry) {
        append(entry, to: "gemini_tts")
    }

    // MARK: - Private

    private static let queue = DispatchQueue(label: "narrait.apilogger", qos: .utility)

    private static var logDir: URL {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs", isDirectory: true)
        return logs.appendingPathComponent("Narrait", isDirectory: true)
    }

    private static func append<T: Encodable>(_ entry: T, to name: String) {
        queue.async {
            let dir = logDir
            let file = dir.appendingPathComponent("\(name).json")

            do {
                try FileManager.default.createDirectory(at: dir,
                    withIntermediateDirectories: true)

                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

                // Read existing array (or start fresh)
                var array: [[String: Any]] = []
                if let existing = try? Data(contentsOf: file),
                   let parsed = try? JSONSerialization.jsonObject(with: existing) as? [[String: Any]] {
                    array = parsed
                }

                // Encode new entry → round-trip through JSONSerialization so we can mix it in
                let entryData = try encoder.encode(entry)
                if let entryObj = try JSONSerialization.jsonObject(with: entryData) as? [String: Any] {
                    array.append(entryObj)
                }

                let output = try JSONSerialization.data(withJSONObject: array,
                    options: [.prettyPrinted, .sortedKeys])
                try output.write(to: file, options: .atomic)

            } catch {
                print("⚠️ APILogger: failed to write \(name).json — \(error)")
            }
        }
    }

    static func isoTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
