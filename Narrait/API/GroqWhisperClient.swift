import Foundation

// Groq Whisper Large v3 — batch REST transcription.
// Takes the WAV data from MicRecorder and returns the transcript string.
// Sub-200ms response time with Groq's inference.
class GroqWhisperClient {
    private static let apiURL = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config)
    }

    func transcribe(audioData: Data) async throws -> String {
        guard !APIKeyStore.groqKey.isEmpty else {
            throw NSError(domain: "GroqWhisper", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No Groq API key set"])
        }

        let boundary = "narrait-\(UUID().uuidString)"
        var request = URLRequest(url: Self.apiURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(APIKeyStore.groqKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        let crlf = "\r\n"

        // model field
        body.appendString("--\(boundary)\(crlf)")
        body.appendString("Content-Disposition: form-data; name=\"model\"\(crlf)\(crlf)")
        body.appendString("whisper-large-v3\(crlf)")

        // response_format
        body.appendString("--\(boundary)\(crlf)")
        body.appendString("Content-Disposition: form-data; name=\"response_format\"\(crlf)\(crlf)")
        body.appendString("json\(crlf)")

        // language
        body.appendString("--\(boundary)\(crlf)")
        body.appendString("Content-Disposition: form-data; name=\"language\"\(crlf)\(crlf)")
        body.appendString("en\(crlf)")

        // audio file
        body.appendString("--\(boundary)\(crlf)")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\(crlf)")
        body.appendString("Content-Type: audio/wav\(crlf)\(crlf)")
        body.append(audioData)
        body.appendString(crlf)
        body.appendString("--\(boundary)--\(crlf)")

        request.httpBody = body
        print("🎤 GroqWhisper: transcribing \(audioData.count / 1024)KB audio")

        let startTime = Date()
        let (data, response) = try await session.data(for: request)
        let elapsed = Date().timeIntervalSince(startTime)

        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "GroqWhisper", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw NSError(domain: "GroqWhisper", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Groq error \(http.statusCode): \(body)"])
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw NSError(domain: "GroqWhisper", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response format"])
        }

        // x_groq.usage.audio_duration is the seconds of speech processed.
        let audioDuration = (json["x_groq"] as? [String: Any])
            .flatMap { $0["usage"] as? [String: Any] }
            .flatMap { $0["audio_duration"] as? Double } ?? 0

        let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
        print("🎤 GroqWhisper: \"\(transcript)\"")

        APILogger.logGroq(APILogger.GroqEntry(
            timestamp: APILogger.isoTimestamp(),
            model: "whisper-large-v3",
            audioSizeKB: audioData.count / 1024,
            transcript: transcript,
            output: transcript,
            audioDurationSeconds: audioDuration,
            durationSeconds: elapsed
        ))

        return transcript
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}
