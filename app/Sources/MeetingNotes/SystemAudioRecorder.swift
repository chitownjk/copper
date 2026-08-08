import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private let outputURL: URL
    private var stream: SCStream?
    private var file: AVAudioFile?

    init(outputURL: URL) {
        self.outputURL = outputURL
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            throw NSError(
                domain: "SystemAudioRecorder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No display found"]
            )
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // Minimal video config — required by API but unused.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 5

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(
            self,
            type: .audio,
            sampleHandlerQueue: .global(qos: .userInitiated)
        )
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async throws {
        try await stream?.stopCapture()
        stream = nil
        file = nil
    }

    // MARK: - SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid else { return }

        if file == nil {
            guard let formatDesc = sampleBuffer.formatDescription,
                  let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
                return
            }
            var asbd = asbdPtr.pointee
            guard let format = AVAudioFormat(streamDescription: &asbd) else { return }
            do {
                file = try AVAudioFile(
                    forWriting: outputURL,
                    settings: format.settings,
                    commonFormat: format.commonFormat,
                    interleaved: format.isInterleaved
                )
            } catch {
                print("SystemAudioRecorder: could not open file: \(error)")
                return
            }
        }

        do {
            try sampleBuffer.withAudioBufferList { audioBufferList, _ in
                guard let format = self.file?.processingFormat,
                      let pcmBuffer = AVAudioPCMBuffer(
                          pcmFormat: format,
                          bufferListNoCopy: audioBufferList.unsafePointer
                      ) else { return }
                pcmBuffer.frameLength = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
                try self.file?.write(from: pcmBuffer)
            }
        } catch {
            print("SystemAudioRecorder: write error: \(error)")
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("SystemAudioRecorder: stream stopped with error: \(error)")
    }
}
