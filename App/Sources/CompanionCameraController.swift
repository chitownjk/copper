import Foundation
import AVFoundation
import CoreMedia
import Observation
import CompanionVideoCore

/// Synchronizes the two frame-queue consumers that are configured by the
/// main-actor controller and invoked by capture/timer queues.
private final class CameraFrameRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var preview: ((CMSampleBuffer) -> Void)?
    private var recorder: CameraLoopRecorder?
    private var sourceObserver: ((CameraFrameSource) -> Void)?

    var previewConsumer: ((CMSampleBuffer) -> Void)? {
        get { lock.withLock { preview } }
        set { lock.withLock { preview = newValue } }
    }

    var loopRecorder: CameraLoopRecorder? {
        get { lock.withLock { recorder } }
        set { lock.withLock { recorder = newValue } }
    }

    var frameSourceConsumer: ((CameraFrameSource) -> Void)? {
        get { lock.withLock { sourceObserver } }
        set { lock.withLock { sourceObserver = newValue } }
    }

    func appendToLoop(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        let currentRecorder: CameraLoopRecorder? = lock.withLock { self.recorder }
        currentRecorder?.append(pixelBuffer, presentationTime: presentationTime)
    }

    func deliverPreview(_ sampleBuffer: CMSampleBuffer, source: CameraFrameSource) {
        let consumers: (((CMSampleBuffer) -> Void)?, ((CameraFrameSource) -> Void)?) =
            lock.withLock { (self.preview, self.sourceObserver) }
        let currentPreview = consumers.0
        currentPreview?(sampleBuffer)
        consumers.1?(source)
    }
}

/// Owns the persistent go-live feed: real camera (or camera-off frames) →
/// FrameComposer → sink stream → virtual camera. This is the product path —
/// the timed `--camera-passthrough` probe remains only as a dev affordance.
///
/// Off at every launch. Opening the Camera settings pane starts the feed
/// (preview + sink). Stop stays on the menu extra, dock menu, and banner.
@MainActor
@Observable
final class CompanionCameraController {
    enum State: Equatable {
        case off
        case live
        case failed(String)
    }

    enum OutputMode: String, CaseIterable {
        case live
        case off

        var label: String {
            switch self {
            case .live: return "Live camera"
            case .off: return "Camera off"
            }
        }
    }

    enum LogoSize: String, CaseIterable {
        case small, medium, large

        var fraction: CGFloat {
            switch self {
            case .small: return 0.06
            case .medium: return 0.10
            case .large: return 0.16
            }
        }

        var label: String { rawValue.capitalized }
    }

    /// One HUD/settings control: None plus the three blur strengths.
    enum LiveBlur: String, CaseIterable, Identifiable {
        case none, light, medium, strong

        var id: String { rawValue }

        var label: String { rawValue.capitalized }
    }

    private(set) var state: State = .off
    private(set) var outputMode: OutputMode = .live
    private(set) var logoURL: URL?
    private(set) var savedLogos: [SavedLogo] = []
    private(set) var selectedLogoID: String?
    private(set) var logoSize: LogoSize = .medium
    private(set) var mirrorsOutput = false
    private(set) var backgroundMode: BackgroundMode = .none
    private(set) var blurStrength: BlurStrength = .medium
    private(set) var loopDisplayName: String?
    private(set) var stillDisplayName: String?
    private(set) var loopRecordSecondsLeft: Int?
    private(set) var loopIsPrecomposed = false
    private(set) var lastLoopError: String?

    /// Stored so @Observable publishes title edits immediately. A computed
    /// UserDefaults passthrough writes but never invalidates the TextField.
    var offCardTitle: String = CameraOffMedia.cardTitle {
        didSet {
            guard oldValue != offCardTitle else { return }
            CameraOffMedia.cardTitle = offCardTitle
            offSource?.updateCard(title: offCardTitle, subtitle: offCardSubtitle)
        }
    }

    var offCardSubtitle: String = CameraOffMedia.cardSubtitle {
        didSet {
            guard oldValue != offCardSubtitle else { return }
            CameraOffMedia.cardSubtitle = offCardSubtitle
            offSource?.updateCard(title: offCardTitle, subtitle: offCardSubtitle)
        }
    }

    var isRecordingLoop: Bool { loopRecordSecondsLeft != nil }

    var liveBlur: LiveBlur {
        guard backgroundMode == .blur else { return .none }
        switch blurStrength {
        case .light: return .light
        case .medium: return .medium
        case .strong: return .strong
        }
    }

    private var loopURL: URL?
    private var stillURL: URL?
    private var capture: CameraCaptureService?
    private var sink: CameraSinkClient?
    private var offSource: CameraOffFrameSource?
    private var offPump: DispatchSourceTimer?
    private var sourceTransitionTask: Task<Void, Never>?
    private var sourceTransitionRevision: UInt64 = 0
    private let offPumpQueue = DispatchQueue(
        label: "com.strongrise.meetingcompanion.camera-off",
        qos: .userInteractive
    )
    private let composer = FrameComposer()
    private let sourceGeneration = FrameSourceGeneration()
    @ObservationIgnored private let frameRelay = CameraFrameRelay()

    /// Preview tee: receives every composed sample buffer that reached the
    /// sink. Called on the capture / off-pump queue — consumers must be
    /// thread-safe (AVSampleBufferDisplayLayer's renderer is).
    var previewConsumer: ((CMSampleBuffer) -> Void)? {
        get { frameRelay.previewConsumer }
        set { frameRelay.previewConsumer = newValue }
    }

    /// Live-capture tee for a 5s loop recording. Capture-queue only.
    private var loopRecorder: CameraLoopRecorder? {
        get { frameRelay.loopRecorder }
        set { frameRelay.loopRecorder = newValue }
    }

    var frameSourceConsumer: ((CameraFrameSource) -> Void)? {
        get { frameRelay.frameSourceConsumer }
        set { frameRelay.frameSourceConsumer = newValue }
    }

    nonisolated static let logoDefaultsKey = "videoLogoPath"
    nonisolated static let logoSizeDefaultsKey = "videoLogoSize"
    nonisolated static let mirrorDefaultsKey = "videoMirrorOutput"
    nonisolated static let backgroundDefaultsKey = "videoBackgroundMode"
    nonisolated static let blurStrengthDefaultsKey = "videoBlurStrength"
    nonisolated static let outputModeDefaultsKey = "videoOutputMode"

    init() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: Self.logoSizeDefaultsKey), let size = LogoSize(rawValue: raw) {
            logoSize = size
        }
        mirrorsOutput = defaults.bool(forKey: Self.mirrorDefaultsKey)
        composer.setMirrorOutput(mirrorsOutput)
        if let raw = defaults.string(forKey: Self.backgroundDefaultsKey), let mode = BackgroundMode(rawValue: raw) {
            backgroundMode = mode
            composer.setBackgroundMode(mode)
        }
        if let raw = defaults.string(forKey: Self.blurStrengthDefaultsKey), let strength = BlurStrength(rawValue: raw) {
            blurStrength = strength
            composer.setBlurStrength(strength)
        }
        if let raw = defaults.string(forKey: Self.outputModeDefaultsKey), let mode = OutputMode(rawValue: raw) {
            outputMode = mode
        }
        if let item = CameraOffMedia.loop {
            loopURL = item.url
            loopDisplayName = item.displayName
            loopIsPrecomposed = CameraOffMedia.loopIsPrecomposed
        }
        if let item = CameraOffMedia.still {
            stillURL = item.url
            stillDisplayName = item.displayName
        }
        savedLogos = LogoLibrary.load()
        migrateLegacySingleLogoIfNeeded()
        if let id = LogoLibrary.selectedID, let logo = savedLogos.first(where: { $0.id == id }) {
            selectedLogoID = id
            applyLogoFile(logo.url)
        } else if let path = defaults.string(forKey: Self.logoDefaultsKey) {
            // Library empty / nothing selected, but a legacy path still works.
            applyLogoFile(URL(fileURLWithPath: path))
        }
    }

    var isLive: Bool { state == .live }

    func goLive() async {
        guard state != .live else { return }
        if let inFlight = sourceTransitionTask {
            await inFlight.value
            if state == .live { return }
        }
        let transition = scheduleSourceTransition(for: outputMode)
        await transition.value
    }

    func stopLive() {
        sourceTransitionTask?.cancel()
        sourceTransitionTask = nil
        sourceTransitionRevision &+= 1
        stopSource()
        sink?.disconnect()
        sink = nil
        state = .off
    }

    func setOutputMode(_ mode: OutputMode) {
        outputMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.outputModeDefaultsKey)
        if state == .live || sink != nil || sourceTransitionTask != nil {
            scheduleSourceTransition(for: mode)
        }
    }

    /// HUD / settings toggle: persist the mode and make sure the sink is
    /// pushing so Meet never falls back to the extension TestCard.
    func applyOutputMode(_ mode: OutputMode) {
        setOutputMode(mode)
        if state != .live, sourceTransitionTask == nil {
            Task { await goLive() }
        }
    }

    func waitForSourceTransition() async {
        await sourceTransitionTask?.value
    }

    func setLoop(from url: URL) {
        do {
            let item = try CameraOffMedia.importLoop(from: url)
            loopURL = item.url
            loopDisplayName = item.displayName
            loopIsPrecomposed = false
            reloadOffSourceIfNeeded()
        } catch {
            if state != .live {
                state = .failed("Could not save loop: \(error.localizedDescription)")
            }
        }
    }

    func clearLoop() {
        CameraOffMedia.clearLoop()
        loopURL = nil
        loopDisplayName = nil
        loopIsPrecomposed = false
        reloadOffSourceIfNeeded()
    }

    func setStill(from url: URL) {
        do {
            let item = try CameraOffMedia.importStill(from: url)
            stillURL = item.url
            stillDisplayName = item.displayName
            reloadOffSourceIfNeeded()
        } catch {
            if state != .live {
                state = .failed("Could not save still: \(error.localizedDescription)")
            }
        }
    }

    func clearStill() {
        CameraOffMedia.clearStill()
        stillURL = nil
        stillDisplayName = nil
        reloadOffSourceIfNeeded()
    }

    /// Record ~5 seconds from the physical camera and make that clip the
    /// current loop. Re-record replaces the last one.
    func recordLoop() async {
        guard loopRecordSecondsLeft == nil else { return }
        lastLoopError = nil
        loopRecordSecondsLeft = Int(CameraLoopRecorder.durationSeconds)

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("mc-loop-\(UUID().uuidString).mov")
        let recorder = CameraLoopRecorder()
        var dedicatedCapture: CameraCaptureService?

        do {
            try recorder.start(writingTo: dest)
            let usingLiveCapture = state == .live && outputMode == .live && capture != nil
            if usingLiveCapture {
                loopRecorder = recorder
            } else {
                guard await CameraCaptureService.requestAccess() else {
                    throw CameraCaptureService.CaptureError.cameraAccessDenied
                }
                let extra = CameraCaptureService()
                let composer = self.composer
                extra.onFrame = { sampleBuffer in
                    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                          let composed = composer.compose(pixelBuffer) else { return }
                    recorder.append(
                        composed,
                        presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    )
                }
                try extra.start(excludingUniqueID: CameraSinkClient.deviceUID)
                dedicatedCapture = extra
            }

            let seconds = Int(CameraLoopRecorder.durationSeconds)
            for remaining in stride(from: seconds, through: 1, by: -1) {
                loopRecordSecondsLeft = remaining
                try await Task.sleep(for: .seconds(1))
            }

            loopRecorder = nil
            dedicatedCapture?.stop()
            try await recorder.finish()

            let item = try CameraOffMedia.importLoop(from: dest, displayName: "Recorded loop", precomposed: true)
            loopURL = item.url
            loopDisplayName = item.displayName
            loopIsPrecomposed = true
            reloadOffSourceIfNeeded()
            try? FileManager.default.removeItem(at: dest)
            loopRecordSecondsLeft = nil
        } catch {
            loopRecorder = nil
            dedicatedCapture?.stop()
            try? FileManager.default.removeItem(at: dest)
            loopRecordSecondsLeft = nil
            lastLoopError = error.localizedDescription
            if state != .live {
                state = .failed("Could not record loop: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Source switching

    @discardableResult
    private func scheduleSourceTransition(for mode: OutputMode) -> Task<Void, Never> {
        sourceTransitionTask?.cancel()
        sourceTransitionRevision &+= 1
        let revision = sourceTransitionRevision

        // Invalidate and stop the old producer synchronously with the HUD
        // selection. This prevents any queued live callback from winning the
        // race before the transition task gets its main-actor turn.
        stopSource()
        if mode == .off, let sink {
            // Replace the final physical-camera frame before loop discovery or
            // decoding can block. The off pump will overwrite this immediately.
            pushPlaceholder(to: sink)
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performSourceTransition(to: mode, revision: revision)
        }
        sourceTransitionTask = task
        return task
    }

    private func performSourceTransition(to mode: OutputMode, revision: UInt64) async {
        guard transitionIsCurrent(revision, mode: mode) else { return }
        do {
            if sink == nil {
                let sink = CameraSinkClient()
                try sink.connect()
                guard transitionIsCurrent(revision, mode: mode) else {
                    sink.disconnect()
                    return
                }
                self.sink = sink
                // Fill startup before the selected producer emits its first frame.
                pushPlaceholder(to: sink)
            }
            if mode == .off, let sink {
                pushPlaceholder(to: sink)
            }
            try await startSource(for: mode, revision: revision)
            guard transitionIsCurrent(revision, mode: mode) else { return }
            state = .live
        } catch is CancellationError {
            return
        } catch {
            guard transitionIsCurrent(revision, mode: mode) else { return }
            tearDownLive(failed: error.localizedDescription)
        }
    }

    private func transitionIsCurrent(_ revision: UInt64, mode: OutputMode) -> Bool {
        !Task.isCancelled
            && sourceTransitionRevision == revision
            && outputMode == mode
    }

    private func pushPlaceholder(to sink: CameraSinkClient) {
        let card = CameraOffCard.makePixelBuffer(title: offCardTitle, subtitle: offCardSubtitle)
        guard let card else { return }
        if let composed = composer.compose(card, effects: .overlayOnly) {
            sink.pushPixelBuffer(composed)
        } else {
            sink.pushPixelBuffer(card)
        }
    }

    private func startSource(for mode: OutputMode, revision: UInt64) async throws {
        switch mode {
        case .live:
            guard await CameraCaptureService.requestAccess() else {
                throw CameraCaptureService.CaptureError.cameraAccessDenied
            }
            try Task.checkCancellation()
            guard transitionIsCurrent(revision, mode: mode) else { throw CancellationError() }
            try startCapture()
        case .off:
            try Task.checkCancellation()
            guard transitionIsCurrent(revision, mode: mode) else { throw CancellationError() }
            startOffStatePump()
        }
    }

    private func stopSource() {
        sourceGeneration.invalidate()
        capture?.onFrame = nil
        capture?.stop()
        capture = nil
        offPump?.cancel()
        offPump = nil
        offSource?.stop()
        offSource = nil
    }

    private func tearDownLive(failed message: String) {
        stopSource()
        sink?.disconnect()
        sink = nil
        state = .failed(message)
    }

    private func startCapture() throws {
        guard let sink else {
            throw CameraCaptureService.CaptureError.deviceNotFound
        }
        let capture = CameraCaptureService()
        let composer = self.composer
        let frameRelay = self.frameRelay
        let generation = sourceGeneration.activate(.live)
        let sourceGeneration = self.sourceGeneration
        capture.onFrame = { [weak sink] sampleBuffer in
            guard sourceGeneration.routes(.live, token: generation), let sink else { return }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                  let composed = composer.compose(pixelBuffer) else { return }
            frameRelay.appendToLoop(
                composed,
                presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            )
            if let pushed = sink.pushPixelBuffer(composed) {
                frameRelay.deliverPreview(pushed, source: .live)
            }
        }
        try capture.start(excludingUniqueID: CameraSinkClient.deviceUID)
        self.capture = capture
    }

    private func startOffStatePump() {
        guard let sink else { return }
        let composer = self.composer
        let frameRelay = self.frameRelay
        let passThroughLoop = loopIsPrecomposed
        let generation = sourceGeneration.activate(.cameraOff)
        let sourceGeneration = self.sourceGeneration
        let source = CameraOffFrameSource(
            loopURL: loopURL,
            stillURL: stillURL,
            cardTitle: offCardTitle,
            cardSubtitle: offCardSubtitle
        )
        offSource = source
        let push = {
            guard sourceGeneration.routes(.cameraOff, token: generation) else { return }
            guard let pixelBuffer = source.nextPixelBuffer() else { return }
            let effects: FrameComposer.Effects =
                (passThroughLoop && source.isServingLoop) ? .passthrough : .overlayOnly
            guard let composed = composer.compose(pixelBuffer, effects: effects) else { return }
            if let pushed = sink.pushPixelBuffer(composed) {
                frameRelay.deliverPreview(pushed, source: .cameraOff)
            }
        }
        push()
        let timer = DispatchSource.makeTimerSource(queue: offPumpQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30.0, leeway: .milliseconds(2))
        timer.setEventHandler { push() }
        timer.resume()
        offPump = timer
    }

    private func reloadOffSourceIfNeeded() {
        guard state == .live, outputMode == .off else { return }
        sourceGeneration.invalidate()
        offPump?.cancel()
        offSource?.stop()
        offPump = nil
        offSource = nil
        startOffStatePump()
    }

    /// Applies a logo file immediately (including mid-stream) and records
    /// the path for the passthrough probe. Prefer `addLogo` / `selectLogo`
    /// so the library keeps every upload.
    func setLogo(url: URL?) {
        if let url {
            applyLogoFile(url)
        } else {
            clearAppliedLogo()
            selectedLogoID = nil
            LogoLibrary.selectedID = nil
        }
    }

    /// Copies `url` into Application Support, appends it to the library, and
    /// selects it. Replacing is no longer destructive.
    @discardableResult
    func addLogo(from url: URL) -> SavedLogo? {
        do {
            let logo = try LogoLibrary.importLogo(from: url)
            savedLogos.append(logo)
            LogoLibrary.save(savedLogos)
            selectLogo(id: logo.id)
            return logo
        } catch {
            state = state == .live ? .live : .failed("Could not save logo: \(error.localizedDescription)")
            return nil
        }
    }

    func selectLogo(id: String?) {
        guard let id, let logo = savedLogos.first(where: { $0.id == id }) else {
            setLogo(url: nil)
            return
        }
        selectedLogoID = id
        LogoLibrary.selectedID = id
        applyLogoFile(logo.url)
    }

    func removeLogo(id: String) {
        guard let index = savedLogos.firstIndex(where: { $0.id == id }) else { return }
        let logo = savedLogos.remove(at: index)
        LogoLibrary.deleteFile(logo)
        LogoLibrary.save(savedLogos)
        if selectedLogoID == id {
            selectedLogoID = nil
            LogoLibrary.selectedID = nil
            clearAppliedLogo()
        }
    }

    private func applyLogoFile(_ url: URL) {
        guard composer.setLogo(url: url, heightFraction: logoSize.fraction) else {
            state = state == .live ? .live : .failed("Could not load logo image")
            return
        }
        UserDefaults.standard.set(url.path, forKey: Self.logoDefaultsKey)
        logoURL = url
    }

    private func clearAppliedLogo() {
        composer.setLogo(url: nil)
        UserDefaults.standard.removeObject(forKey: Self.logoDefaultsKey)
        logoURL = nil
    }

    /// One-time: the old single-path setting becomes the first library entry
    /// so Jay's existing Islo logo is not stranded.
    private func migrateLegacySingleLogoIfNeeded() {
        let defaults = UserDefaults.standard
        guard savedLogos.isEmpty,
              let path = defaults.string(forKey: Self.logoDefaultsKey) else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if let logo = try? LogoLibrary.importLogo(from: url, displayName: url.deletingPathExtension().lastPathComponent) {
            savedLogos = [logo]
            LogoLibrary.save(savedLogos)
            selectedLogoID = logo.id
            LogoLibrary.selectedID = logo.id
        }
    }

    func setLogoSize(_ size: LogoSize) {
        logoSize = size
        UserDefaults.standard.set(size.rawValue, forKey: Self.logoSizeDefaultsKey)
        if let logoURL {
            composer.setLogo(url: logoURL, heightFraction: size.fraction)
        }
    }

    /// Flips the outgoing frames horizontally — including for remote
    /// participants. Meeting apps mirror only your local self-view, so most
    /// people want this OFF; it exists for those who want their self-view
    /// to read correctly and don't mind the flip on the far side.
    func setMirrorOutput(_ enabled: Bool) {
        mirrorsOutput = enabled
        UserDefaults.standard.set(enabled, forKey: Self.mirrorDefaultsKey)
        composer.setMirrorOutput(enabled)
    }

    func setBackgroundMode(_ mode: BackgroundMode) {
        backgroundMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.backgroundDefaultsKey)
        composer.setBackgroundMode(mode)
    }

    func setBlurStrength(_ strength: BlurStrength) {
        blurStrength = strength
        UserDefaults.standard.set(strength.rawValue, forKey: Self.blurStrengthDefaultsKey)
        composer.setBlurStrength(strength)
    }

    func setLiveBlur(_ blur: LiveBlur) {
        switch blur {
        case .none:
            setBackgroundMode(.none)
        case .light:
            setBackgroundMode(.blur)
            setBlurStrength(.light)
        case .medium:
            setBackgroundMode(.blur)
            setBlurStrength(.medium)
        case .strong:
            setBackgroundMode(.blur)
            setBlurStrength(.strong)
        }
    }
}
