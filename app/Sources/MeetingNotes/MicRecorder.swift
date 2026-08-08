import Foundation
import AVFoundation

final class MicRecorder {
    private let engine = AVAudioEngine()
    private let file: AVAudioFile

    init(outputURL: URL) throws {
        let input = engine.inputNode

        // Acoustic echo cancellation + noise suppression + AGC.
        // Must be set before reading the input format.
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            // Non-fatal — fall back to raw mic if voice processing isn't available.
            print("MicRecorder: voice processing unavailable: \(error)")
        }

        let format = input.outputFormat(forBus: 0)
        self.file = try AVAudioFile(
            forWriting: outputURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            try? self?.file.write(from: buffer)
        }
    }

    func start() throws {
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
