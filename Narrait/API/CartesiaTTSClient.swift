import AVFoundation
import Foundation

// Local macOS TTS for low-latency testing. Keeps the same client name used by
// the coordinator, but uses AVSpeechSynthesizer instead of an API call.
@MainActor
final class GeminiTTSClient: NSObject {
    private let modelID = "macos-avspeech"
    private let preferredVoiceIDs = [
        "com.apple.voice.premium.en-US.Zoe",
        "com.apple.eloquence.en-US.Flo",
        "com.apple.eloquence.en-US.Shelley",
        "com.apple.eloquence.en-US.Reed",
        "com.apple.eloquence.en-US.Sandy",
        "com.apple.eloquence.en-US.Eddy",
        "com.apple.voice.premium.en-US.Evan",
        "com.apple.voice.enhanced.en-US.Samantha",
        "com.apple.voice.enhanced.en-US.Alex",
        "com.apple.voice.compact.en-US.Samantha"
    ]

    private let synthesizer = AVSpeechSynthesizer()
    private var playbackContinuation: CheckedContinuation<Void, Error>?
    private var isCancelled = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, speed: Double = 1.0) async throws {
        isCancelled = false
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        synthesizer.stopSpeaking(at: .immediate)

        let startTime = Date()

        let utterance = AVSpeechUtterance(string: text)
        let voice = bestAvailableVoice()
        utterance.voice = voice
        utterance.rate = speechRate(for: speed)
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        APILogger.logGeminiTTS(APILogger.GeminiTTSEntry(
            timestamp: APILogger.isoTimestamp(),
            model: modelID,
            voiceID: voice?.identifier ?? "system-default-en-US",
            inputText: text,
            characterCount: text.count,
            speed: speedLabel(for: speed),
            output: "local macOS speech synthesis",
            audioSizeKB: 0,
            durationSeconds: Date().timeIntervalSince(startTime)
        ))

        print("🔊 macOS TTS (\(voice?.name ?? "default")): speaking \(text.count) chars")
        synthesizer.speak(utterance)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            if isCancelled {
                cont.resume(throwing: CancellationError())
                return
            }
            playbackContinuation = cont
        }
    }

    var isPlaying: Bool { synthesizer.isSpeaking }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    func cancel() {
        isCancelled = true
        stop()
        resumeContinuation(throwing: CancellationError())
    }

    // MARK: - Private

    private func finishPlayback() {
        resumeContinuation(throwing: nil)
    }

    private func resumeContinuation(throwing error: Error?) {
        guard let cont = playbackContinuation else { return }
        playbackContinuation = nil
        if let err = error {
            cont.resume(throwing: err)
        } else {
            cont.resume()
        }
    }

    private func speechRate(for speed: Double) -> Float {
        let base = AVSpeechUtteranceDefaultSpeechRate
        return max(0.35, min(0.65, Float(speed) * base))
    }

    private func bestAvailableVoice() -> AVSpeechSynthesisVoice? {
        for id in preferredVoiceIDs {
            if let voice = AVSpeechSynthesisVoice(identifier: id) {
                return voice
            }
        }
        return AVSpeechSynthesisVoice(language: "en-US")
    }

    private func speedLabel(for speed: Double) -> String {
        switch speed {
        case ..<0.8: return "slowest"
        case 0.8..<0.9: return "slow"
        case 0.9..<1.05: return "normal"
        case 1.05..<1.2: return "fast"
        default: return "fastest"
        }
    }
}

extension GeminiTTSClient: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishPlayback() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resumeContinuation(throwing: CancellationError()) }
    }
}
