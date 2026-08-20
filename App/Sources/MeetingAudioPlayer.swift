import AVFoundation
import Foundation
import Observation

/// Thin listen-back wrapper around `AVAudioPlayer`. Plays `mixed.wav` only —
/// no speeds, no waveform, no stem fallback.
@MainActor
@Observable
final class MeetingAudioPlayer {
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var isPlaying = false

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?

    /// Load a mix. Passing `nil` or a missing file stops and releases.
    func load(url: URL?) {
        stop()
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            self.player = player
            duration = player.duration
            currentTime = 0
            isPlaying = false
        } catch {
            print("MeetingAudioPlayer failed to load \(url.lastPathComponent): \(error)")
        }
    }

    func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
        startTimer()
    }

    /// True when a mix is loaded. The play button can be visible (mix
    /// exists on disk) before this is true — caller must reload.
    var isLoaded: Bool { player != nil }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
        syncTime()
    }

    func toggle() {
        if isPlaying { pause() } else { play() }
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = min(max(0, time), max(duration, 0))
        player.currentTime = clamped
        currentTime = clamped
    }

    /// Stop playback and release the file handle. Call when the meeting
    /// changes or the detail view disappears.
    func stop() {
        stopTimer()
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncTime()
            }
        }
        timer.tolerance = 1.0 / 30.0
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func syncTime() {
        guard let player else {
            isPlaying = false
            stopTimer()
            return
        }
        currentTime = player.currentTime
        if player.isPlaying {
            isPlaying = true
            return
        }
        isPlaying = false
        stopTimer()
        if duration > 0, currentTime >= duration - 0.05 {
            currentTime = duration
        }
    }
}
