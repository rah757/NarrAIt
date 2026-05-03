@preconcurrency import AVFoundation
import Combine
import Foundation

// Simplified port of Clicky's BuddyDictationManager.
// Captures 16kHz PCM16 from the mic via AVAudioEngine.
// start() begins capture; stop() returns the raw PCM Data for Groq Whisper.
// Unlike AssemblyAI streaming, Groq is a batch REST call so we buffer locally.
@MainActor
final class MicRecorder {
    @Published private(set) var currentPowerLevel: CGFloat = 0

    private let audioEngine = AVAudioEngine()
    private var pcmBuffer: [Float] = []
    private var isRecording = false
    private let targetSampleRate: Double = 16_000

    func start() async throws {
        guard !isRecording else { return }
        try await requestMicPermission()

        pcmBuffer = []
        isRecording = true

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Converter from native format to 16kHz mono for Whisper
        let whisperFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )!

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // Convert to 16kHz mono
            guard let converted = Self.convert(buffer: buffer, from: inputFormat, to: whisperFormat) else { return }

            let channelData = converted.floatChannelData![0]
            let frameCount = Int(converted.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))

            DispatchQueue.main.async {
                self.pcmBuffer.append(contentsOf: samples)
                self.updatePowerLevel(from: samples)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
        print("🎙️ MicRecorder: started")
    }

    // Returns WAV-formatted Data ready to POST to Groq, or nil if nothing was captured.
    func stop() async -> Data? {
        guard isRecording else { return nil }
        isRecording = false
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        currentPowerLevel = 0

        let captured = pcmBuffer
        pcmBuffer = []

        guard !captured.isEmpty else { return nil }

        // Convert float32 PCM to 16-bit signed WAV
        let wavData = Self.buildWAV(samples: captured, sampleRate: Int(targetSampleRate))
        print("🎙️ MicRecorder: stopped, \(wavData.count / 1024)KB WAV")
        return wavData
    }

    // MARK: - Private

    private func requestMicPermission() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized { return }
        if status == .denied || status == .restricted {
            throw NSError(domain: "MicRecorder", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone access denied"])
        }
        let granted = await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
        }
        guard granted else {
            throw NSError(domain: "MicRecorder", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone access denied"])
        }
    }

    private func updatePowerLevel(from samples: [Float]) {
        guard !samples.isEmpty else { return }
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        let boosted = min(max(CGFloat(rms) * 10, 0), 1)
        currentPowerLevel = max(boosted, currentPowerLevel * 0.72)
    }

    private static func convert(
        buffer: AVAudioPCMBuffer,
        from srcFormat: AVAudioFormat,
        to dstFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else { return nil }

        let ratio = dstFormat.sampleRate / srcFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)

        guard let output = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: outputFrameCapacity) else { return nil }

        var error: NSError?
        var inputDone = false
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if inputDone {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputDone = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, error == nil else { return nil }
        return output
    }

    // Builds a minimal 16-bit PCM WAV file from float32 samples
    private static func buildWAV(samples: [Float], sampleRate: Int) -> Data {
        let numSamples = samples.count
        let dataSize = numSamples * 2  // 16-bit = 2 bytes per sample
        let fileSize = 44 + dataSize

        var wav = Data(capacity: fileSize)

        func append(_ str: String) { wav.append(contentsOf: str.utf8) }
        func appendLE<T: FixedWidthInteger>(_ val: T) {
            var v = val.littleEndian
            withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) }
        }

        append("RIFF")
        appendLE(UInt32(fileSize - 8))
        append("WAVE")
        append("fmt ")
        appendLE(UInt32(16))          // chunk size
        appendLE(UInt16(1))           // PCM
        appendLE(UInt16(1))           // mono
        appendLE(UInt32(sampleRate))
        appendLE(UInt32(sampleRate * 2)) // byte rate
        appendLE(UInt16(2))           // block align
        appendLE(UInt16(16))          // bits per sample
        append("data")
        appendLE(UInt32(dataSize))

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16 = Int16(clamped * 32767)
            appendLE(int16)
        }

        return wav
    }
}
