import CoreGraphics
import Foundation

// Anthropic Messages client using Sonnet + Computer Use beta.
// Class name is kept temporarily so the coordinator can stay small during provider swap.
// The [POINT:x,y:label] / [BOX:x1,y1,x2,y2:label] tag parsing is model-agnostic.
class GeminiClient {
    private static let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)
        warmUpTLS()
    }

    // Anthropic call. Calls onTextChunk on main actor with the completed text.
    // Returns text plus a synthetic [POINT:] tag if Computer Use returned mouse_move.
    func stream(
        systemPrompt: String,
        images: [(data: Data, label: String)],
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        modelOverride: String? = nil,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let key = APIKeyStore.anthropicKey
        guard !key.isEmpty else {
            throw NSError(domain: "AnthropicClient", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No Anthropic API key set"])
        }

        let model = modelOverride ?? APIKeyStore.anthropicModel

        var request = URLRequest(url: Self.messagesURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(Self.computerUseBeta(for: model), forHTTPHeaderField: "anthropic-beta")

        var contents: [[String: Any]] = []
        for (placeholder, response) in conversationHistory {
            let userText = placeholder.trimmingCharacters(in: .whitespacesAndNewlines)
            let assistantText = response.trimmingCharacters(in: .whitespacesAndNewlines)
            if !userText.isEmpty {
                contents.append(["role": "user", "content": [["type": "text", "text": userText]]])
            }
            if !assistantText.isEmpty {
                contents.append(["role": "assistant", "content": [["type": "text", "text": assistantText]]])
            }
        }

        var currentParts: [[String: Any]] = []
        for image in images {
            currentParts.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": detectMimeType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            currentParts.append(["type": "text", "text": image.label])
        }
        if !userPrompt.isEmpty {
            currentParts.append(["type": "text", "text": userPrompt])
        }
        contents.append(["role": "user", "content": currentParts])

        let firstImageSize = extractImageSize(from: images.first?.label)
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "temperature": 0.2,
            "system": systemPrompt,
            "messages": contents,
            "tools": [
                [
                    "type": Self.computerToolType(for: model),
                    "name": "computer",
                    "display_width_px": firstImageSize.width,
                    "display_height_px": firstImageSize.height
                ],
                [
                    "type": "custom",
                    "name": "give_plan",
                    "description": "Use when the request requires 2 or more sequential steps — navigating through menus, opening an app then doing something inside it, going to a folder, changing a setting, visiting a website, or any multi-action task. Even if the first element is visible on screen, use give_plan if more steps follow after clicking it.",
                    "input_schema": [
                        "type": "object",
                        "properties": [
                            "steps": [
                                "type": "array",
                                "items": ["type": "string"],
                                "description": "ONLY the click steps — no explanation, no context, no intro sentence. Each step is a single concrete click/action. Must start with Click, Select, Open, Type, or Toggle. 5 words max. Example: ['Click Insert in menu', 'Click Cameo', 'Click Insert Cameo']"
                            ]
                        ],
                        "required": ["steps"]
                    ] as [String: Any]
                ]
            ]
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        print("🌐 Anthropic (\(model)) message: \(String(format: "%.1f", Double(bodyData.count) / 1_048_576.0))MB, \(images.count) image(s)")

        let startTime = Date()
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "AnthropicClient", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "AnthropicClient", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "API error \(httpResponse.statusCode): \(errorBody)"])
        }

        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "AnthropicClient", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid Anthropic JSON response"])
        }

        let parsed = parseAnthropicResponse(payload)
        let accumulated = parsed.text.isEmpty && parsed.pointTag != nil
            ? "i marked it on your screen."
            : parsed.text
        await MainActor.run { onTextChunk(accumulated) }

        let usage = payload["usage"] as? [String: Any]
        let inputTokens = usage?["input_tokens"] as? Int ?? 0
        let outputTokens = usage?["output_tokens"] as? Int ?? 0
        let stopReason = payload["stop_reason"] as? String ?? "unknown"
        print("🌐 Anthropic (\(model)) finished: \(stopReason), \(outputTokens) output tokens")
        let combined = parsed.pointTag.map { "\(accumulated) \($0)" } ?? accumulated
        print("🤖 Claude raw model output: \"\(truncateForXcodeLog(combined))\"")

        let elapsed = Date().timeIntervalSince(startTime)

        // Log asynchronously — don't block the caller.
        let historyEntries = conversationHistory.map {
            APILogger.GeminiEntry.HistoryTurn(user: $0.userPlaceholder, assistant: $0.assistantResponse)
        }
        APILogger.logGemini(APILogger.GeminiEntry(
            timestamp: APILogger.isoTimestamp(),
            model: model,
            systemPrompt: systemPrompt,
            conversationHistory: historyEntries,
            userPrompt: userPrompt,
            imageCount: images.count,
            output: accumulated,
            finishReason: stopReason,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            totalTokens: inputTokens + outputTokens,
            durationSeconds: elapsed
        ))

        return parsed.pointTag.map { "\(accumulated) \($0)" } ?? accumulated
    }

    // Plain Anthropic Messages call — no Computer Use tool.
    // Sonnet emits [POINT:y,x:label] as text when pointing. Used for the voice action path
    // so the model's Computer Use training bias can't override the prompt format.
    func streamText(
        systemPrompt: String,
        images: [(data: Data, label: String)],
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let key = APIKeyStore.anthropicKey
        guard !key.isEmpty else {
            throw NSError(domain: "AnthropicClient", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No Anthropic API key set"])
        }

        let model = APIKeyStore.anthropicModel

        var request = URLRequest(url: Self.messagesURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var contents: [[String: Any]] = []
        for (placeholder, response) in conversationHistory {
            let userText = placeholder.trimmingCharacters(in: .whitespacesAndNewlines)
            let assistantText = response.trimmingCharacters(in: .whitespacesAndNewlines)
            if !userText.isEmpty {
                contents.append(["role": "user", "content": [["type": "text", "text": userText]]])
            }
            if !assistantText.isEmpty {
                contents.append(["role": "assistant", "content": [["type": "text", "text": assistantText]]])
            }
        }

        var currentParts: [[String: Any]] = []
        for image in images {
            currentParts.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": detectMimeType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            currentParts.append(["type": "text", "text": image.label])
        }
        if !userPrompt.isEmpty {
            currentParts.append(["type": "text", "text": userPrompt])
        }
        contents.append(["role": "user", "content": currentParts])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "temperature": 0.2,
            "system": systemPrompt,
            "messages": contents
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        print("🌐 Anthropic (\(model)) message: \(String(format: "%.1f", Double(bodyData.count) / 1_048_576.0))MB, \(images.count) image(s)")

        let startTime = Date()
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "AnthropicClient", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "AnthropicClient", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "API error \(httpResponse.statusCode): \(errorBody)"])
        }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "AnthropicClient", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid Anthropic JSON response"])
        }

        let content = payload["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        await MainActor.run { onTextChunk(text) }

        let usage = payload["usage"] as? [String: Any]
        let inputTokens = usage?["input_tokens"] as? Int ?? 0
        let outputTokens = usage?["output_tokens"] as? Int ?? 0
        let stopReason = payload["stop_reason"] as? String ?? "unknown"
        print("🌐 Anthropic (\(model)) finished: \(stopReason), \(outputTokens) output tokens")
        print("🤖 Claude raw model output: \"\(truncateForXcodeLog(text))\"")

        let elapsed = Date().timeIntervalSince(startTime)
        let historyEntries = conversationHistory.map {
            APILogger.GeminiEntry.HistoryTurn(user: $0.userPlaceholder, assistant: $0.assistantResponse)
        }
        APILogger.logGemini(APILogger.GeminiEntry(
            timestamp: APILogger.isoTimestamp(),
            model: model,
            systemPrompt: systemPrompt,
            conversationHistory: historyEntries,
            userPrompt: userPrompt,
            imageCount: images.count,
            output: text,
            finishReason: stopReason,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            totalTokens: inputTokens + outputTokens,
            durationSeconds: elapsed
        ))

        return text
    }

    // MARK: - [POINT:x,y:label] / [BOX:x1,y1,x2,y2:label] parsing

    struct PointingResult {
        let spokenText: String
        let coordinate: CGPoint?
        let boundingBox: CGRect?
        let elementLabel: String?
        let screenNumber: Int?
    }

    static func parsePointing(from text: String) -> PointingResult {
        if let boxResult = parseBox(from: text) {
            return boxResult
        }

        // Accept integer or float coords; trailing :label and :screenN are optional.
        let pattern = #"\[POINT:(?:none|(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return PointingResult(spokenText: text, coordinate: nil, boundingBox: nil, elementLabel: nil, screenNumber: nil)
        }

        let tagRange = Range(match.range, in: text)!
        let spoken = String(text[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        guard match.numberOfRanges >= 3,
              let yRange = Range(match.range(at: 1), in: text),
              let xRange = Range(match.range(at: 2), in: text),
              let y = Double(text[yRange]),
              let x = Double(text[xRange]) else {
            return PointingResult(spokenText: spoken, coordinate: nil, boundingBox: nil, elementLabel: "none", screenNumber: nil)
        }

        var label: String? = nil
        if match.numberOfRanges >= 4, let lr = Range(match.range(at: 3), in: text) {
            label = String(text[lr]).trimmingCharacters(in: .whitespaces)
        }

        var screenNum: Int? = nil
        if match.numberOfRanges >= 5, let sr = Range(match.range(at: 4), in: text) {
            screenNum = Int(text[sr])
        }

        return PointingResult(
            spokenText: spoken,
            coordinate: CGPoint(x: x, y: y),
            boundingBox: nil,
            elementLabel: label,
            screenNumber: screenNum
        )
    }

    private static func parseBox(from text: String) -> PointingResult? {
        // Accept integer or float box coords; trailing :label and :screenN are optional.
        let pattern = #"\[BOX:(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }

        let tagRange = Range(match.range, in: text)!
        let spoken = String(text[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        guard let y1Range = Range(match.range(at: 1), in: text),
              let x1Range = Range(match.range(at: 2), in: text),
              let y2Range = Range(match.range(at: 3), in: text),
              let x2Range = Range(match.range(at: 4), in: text),
              let y1 = Double(text[y1Range]),
              let x1 = Double(text[x1Range]),
              let y2 = Double(text[y2Range]),
              let x2 = Double(text[x2Range]) else {
            return PointingResult(spokenText: spoken, coordinate: nil, boundingBox: nil, elementLabel: nil, screenNumber: nil)
        }

        var label: String? = nil
        if let lr = Range(match.range(at: 5), in: text) {
            label = String(text[lr]).trimmingCharacters(in: .whitespaces)
        }

        var screenNum: Int? = nil
        if let sr = Range(match.range(at: 6), in: text) {
            screenNum = Int(text[sr])
        }

        let minX = min(x1, x2)
        let minY = min(y1, y2)
        let width = abs(x2 - x1)
        let height = abs(y2 - y1)
        let box = CGRect(x: minX, y: minY, width: width, height: height)
        let center = CGPoint(x: box.midX, y: box.midY)

        return PointingResult(
            spokenText: spoken,
            coordinate: center,
            boundingBox: box,
            elementLabel: label,
            screenNumber: screenNum
        )
    }

    // MARK: - Private

    private static func computerUseBeta(for model: String) -> String {
        if model.contains("haiku-4-5")
            || model.contains("sonnet-4-5")
            || model.contains("opus-4-1")
            || model == "claude-sonnet-4"
            || model == "claude-opus-4"
            || model.contains("sonnet-3-7") {
            return "computer-use-2025-01-24"
        }
        return "computer-use-2025-11-24"
    }

    private static func computerToolType(for model: String) -> String {
        if computerUseBeta(for: model) == "computer-use-2025-01-24" {
            return "computer_20250124"
        }
        return "computer_20251124"
    }

    private func parseAnthropicResponse(_ payload: [String: Any]) -> (text: String, pointTag: String?) {
        guard let content = payload["content"] as? [[String: Any]] else {
            return ("", nil)
        }

        var textChunks: [String] = []
        var pointTag: String?

        for block in content {
            let type = block["type"] as? String
            if type == "text", let text = block["text"] as? String {
                textChunks.append(text)
                continue
            }

            guard type == "tool_use", let name = block["name"] as? String else { continue }

            if name == "give_plan",
               let input = block["input"] as? [String: Any],
               let stepsRaw = input["steps"] as? [String], !stepsRaw.isEmpty {
                print("🗂️ give_plan tool called: \(stepsRaw.count) steps")
                if stepsRaw.count == 1 {
                    // Single step — speak as a plain bubble, not a checklist.
                    textChunks.append(stepsRaw[0] + " [POINT:none]")
                } else {
                    let checklist = stepsRaw.prefix(4).map { "☐ \($0)" }.joined(separator: "\n")
                    textChunks.append(checklist + "\n[POINT:none]")
                }
                continue
            }

            if name == "computer",
               let input = block["input"] as? [String: Any],
               let action = input["action"] as? String,
               action == "mouse_move",
               let coordinate = input["coordinate"] as? [Any],
               coordinate.count >= 2,
               let x = number(from: coordinate[0]),
               let y = number(from: coordinate[1]) {
                pointTag = "[POINT:\(Int(y.rounded())),\(Int(x.rounded())):target]"
            }
        }

        let text = textChunks.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, pointTag)
    }

    private func number(from value: Any) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private func extractImageSize(from label: String?) -> (width: Int, height: Int) {
        guard let label else { return (1280, 800) }
        let pattern = #"(\d+)x(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)),
              let widthRange = Range(match.range(at: 1), in: label),
              let heightRange = Range(match.range(at: 2), in: label),
              let width = Int(label[widthRange]),
              let height = Int(label[heightRange]) else {
            return (1280, 800)
        }
        return (width, height)
    }

    private func detectMimeType(for data: Data) -> String {
        if data.count >= 4 {
            let pngSig: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            if [UInt8](data.prefix(4)) == pngSig { return "image/png" }
        }
        return "image/jpeg"
    }

    private func warmUpTLS() {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/")!)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 10
        session.dataTask(with: req) { _, _, _ in }.resume()
    }
}

final class GeminiFlashRouterClient {
    enum Route {
        case answer  // Gemini Flash answers directly (cheap, fast)
        case action  // Sonnet handles it — Sonnet decides between Computer Use point vs ☐ plan
    }

    private static let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 90
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)
    }

    func route(
        image: (data: Data, label: String),
        transcript: String,
        history: [(userPlaceholder: String, assistantResponse: String)]
    ) async throws -> Route {
        let key = APIKeyStore.geminiKey
        guard !key.isEmpty else {
            throw NSError(domain: "GeminiRouter", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No Gemini API key set"])
        }

        let model = APIKeyStore.geminiRouterModel
        guard let url = URL(string: "\(Self.baseURL)/\(model):generateContent?key=\(key)") else {
            throw NSError(domain: "GeminiRouter", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid Gemini router URL"])
        }

        let historyText = history.suffix(4).map {
            "user: \($0.userPlaceholder)\nassistant: \($0.assistantResponse)"
        }.joined(separator: "\n")

        let prompt = """
        You are a fast binary router for Narrait, an assistive screen-reading app for disabled users. Decide whether this voice request needs the visual reasoning model (Sonnet) or can be answered directly.

        Return ONLY compact JSON with no prose:
        {"route":"action"}
        or
        {"route":"answer"}

        ROUTE DEFINITIONS

        - "action": The user wants to DO something — find a UI element, click a button, change a setting, open an app, navigate to a folder, visit a website, configure something, walk through a multi-step task. Anything that requires the assistant to either point at the screen or produce a step-by-step plan. The downstream model (Sonnet) will decide whether to point or plan.

        - "answer": The user wants to UNDERSTAND — a description, definition, summary, explanation, or read-aloud of what's on screen. No clicking, navigation, settings change, or app-opening implied.

        RULES
        1. If the request involves "how do I", "how to", "where is", "where's", "find", "click", "open", "launch", "go to", "navigate", "change", "set", "configure", "enable", "disable", "turn on", "turn off", "save", "send", "search for", "open <app>", or names a website/folder → "action".
        2. If the request involves "what is", "what's", "what does", "why", "explain", "describe", "read", "tell me", "what's on my screen" with no action verb → "answer".
        3. When in doubt → "action" (Sonnet can still choose to just speak without acting).

        EXAMPLES
        "what's on my screen?" -> {"route":"answer"}
        "what does this error mean?" -> {"route":"answer"}
        "explain this dialog" -> {"route":"answer"}
        "read this paragraph to me" -> {"route":"answer"}
        "describe what i'm looking at" -> {"route":"answer"}
        "where's the settings button?" -> {"route":"action"}
        "click the blue submit button" -> {"route":"action"}
        "how do i change the background of this outlook app?" -> {"route":"action"}
        "how do i change my profile picture?" -> {"route":"action"}
        "how to navigate to downloads in finder?" -> {"route":"action"}
        "how do i close this popup?" -> {"route":"action"}
        "open spotify and play lofi" -> {"route":"action"}
        "go to youtube.com" -> {"route":"action"}
        "take me to my downloads folder" -> {"route":"action"}
        "navigate to system settings" -> {"route":"action"}
        "what do i press next?" -> {"route":"action"}
        "find the search bar" -> {"route":"action"}

        Recent context:
        \(historyText)

        User request:
        \(transcript)
        """

        let body: [String: Any] = [
            "contents": [[
                "role": "user",
                "parts": [
                    [
                        "inline_data": [
                            "mime_type": detectMimeType(for: image.data),
                            "data": image.data.base64EncodedString()
                        ]
                    ],
                    ["text": image.label],
                    ["text": prompt]
                ]
            ]],
            "generationConfig": [
                "maxOutputTokens": 96,
                "temperature": 0.0,
                "responseMimeType": "application/json"
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        print("🧭 Gemini router (\(model)): \(String(format: "%.1f", Double(bodyData.count) / 1_048_576.0))MB")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "GeminiRouter", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid Gemini router response"])
        }
        guard (200...299).contains(http.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "GeminiRouter", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Gemini router error \(http.statusCode): \(errorBody)"])
        }

        let text = try parseText(from: data).trimmingCharacters(in: .whitespacesAndNewlines)
        print("🧭 Gemini router model output: \(truncateForXcodeLog(text))")
        // Empty response (malformed JSON, empty candidates, etc.) → use local classifier
        // so we never silently default to .point without understanding the transcript.
        if text.isEmpty {
            print("🧭 Gemini router returned empty — using local fallback for: \"\(transcript)\"")
            return Self.localFallbackRoute(transcript: transcript)
        }
        return parseRoute(text)
    }

    func answer(
        systemPrompt: String,
        images: [(data: Data, label: String)],
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let key = APIKeyStore.geminiKey
        guard !key.isEmpty else {
            throw NSError(domain: "GeminiRouter", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No Gemini API key set"])
        }

        let model = APIKeyStore.geminiRouterModel
        guard let url = URL(string: "\(Self.baseURL)/\(model):generateContent?key=\(key)") else {
            throw NSError(domain: "GeminiRouter", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid Gemini URL"])
        }

        var contents: [[String: Any]] = []
        for (placeholder, response) in conversationHistory {
            let userText = placeholder.trimmingCharacters(in: .whitespacesAndNewlines)
            let assistantText = response.trimmingCharacters(in: .whitespacesAndNewlines)
            if !userText.isEmpty {
                contents.append(["role": "user", "parts": [["text": userText]]])
            }
            if !assistantText.isEmpty {
                contents.append(["role": "model", "parts": [["text": assistantText]]])
            }
        }

        var currentParts: [[String: Any]] = []
        for image in images {
            currentParts.append([
                "inline_data": [
                    "mime_type": detectMimeType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            currentParts.append(["text": image.label])
        }
        currentParts.append(["text": userPrompt])
        contents.append(["role": "user", "parts": currentParts])

        let body: [String: Any] = [
            "systemInstruction": [
                "parts": [["text": systemPrompt]]
            ],
            "contents": contents,
            "generationConfig": [
                "maxOutputTokens": 1024,
                "temperature": 0.2
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        print("🌐 Gemini Flash (\(model)) answer: \(String(format: "%.1f", Double(bodyData.count) / 1_048_576.0))MB, \(images.count) image(s)")

        let startTime = Date()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "GeminiRouter", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid Gemini response"])
        }
        guard (200...299).contains(http.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "GeminiRouter", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Gemini error \(http.statusCode): \(errorBody)"])
        }

        let text = try parseText(from: data).trimmingCharacters(in: .whitespacesAndNewlines)
        await MainActor.run { onTextChunk(text) }
        print("🤖 Gemini raw model output: \"\(truncateForXcodeLog(text))\"")

        let elapsed = Date().timeIntervalSince(startTime)
        let historyEntries = conversationHistory.map {
            APILogger.GeminiEntry.HistoryTurn(user: $0.userPlaceholder, assistant: $0.assistantResponse)
        }
        APILogger.logGemini(APILogger.GeminiEntry(
            timestamp: APILogger.isoTimestamp(),
            model: model,
            systemPrompt: systemPrompt,
            conversationHistory: historyEntries,
            userPrompt: userPrompt,
            imageCount: images.count,
            output: text,
            finishReason: "STOP",
            inputTokens: 0,
            outputTokens: 0,
            totalTokens: 0,
            durationSeconds: elapsed
        ))

        return text
    }

    private func parseText(from data: Data) throws -> String {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = payload["candidates"] as? [[String: Any]] else {
            return ""
        }

        return candidates.compactMap { candidate in
            guard let content = candidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { return nil }
            return parts.compactMap { $0["text"] as? String }.joined()
        }.joined()
    }

    private func parseRoute(_ text: String) -> Route {
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let data = cleaned.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let route = obj["route"] as? String {
            if route == "answer" { return .answer }
            if route == "action" || route == "point" || route == "plan" { return .action }
        }

        let lower = cleaned.lowercased()
        guard !lower.isEmpty else { return .action }
        if lower.contains("\"answer\"")
            || lower.range(of: #""route"\s*:\s*"answer"#, options: .regularExpression) != nil {
            return .answer
        }
        if lower.contains("answer") { return .answer }
        return .action
    }

    /// Keyword-based fallback used when the Gemini router call throws or returns empty.
    /// Binary: any action verb / navigation / setting change → .action; pure questions → .answer.
    static func localFallbackRoute(transcript: String) -> Route {
        let lower = transcript.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return .action }

        // ── Pure explanation prefixes ─────────────────────────────────────────
        let questionPrefixes = [
            "what is", "what's", "what does", "what do you see", "what am i looking",
            "why", "who", "when ", "does this", "is this", "can you explain",
            "explain", "describe", "read this", "tell me what", "tell me about"
        ]
        if questionPrefixes.contains(where: { lower.hasPrefix($0) }) {
            // Promote to .action if an action-y verb is also present (e.g. "what does this button do" stays answer; "what do i click" → action).
            let actionMixIns = ["click", "press", "open", "navigate", "go to", "find", "search"]
            if !actionMixIns.contains(where: { lower.contains($0) }) {
                return .answer
            }
        }

        // Default: anything else is an action — Sonnet decides between point and plan.
        return .action
    }

    private func detectMimeType(for data: Data) -> String {
        if data.count >= 4 {
            let pngSig: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            if [UInt8](data.prefix(4)) == pngSig { return "image/png" }
        }
        return "image/jpeg"
    }
}

/// Keeps Xcode console readable; full strings still go to APILogger JSON files.
private func truncateForXcodeLog(_ s: String, limit: Int = 240) -> String {
    var t = s.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
    while t.contains("  ") {
        t = t.replacingOccurrences(of: "  ", with: " ")
    }
    t = t.trimmingCharacters(in: .whitespacesAndNewlines)
    guard t.count > limit else { return t }
    let full = t.count
    return String(t.prefix(limit)) + "… (\(full) chars)"
}
