import Foundation
import AVFoundation
import UIKit

final class CameraManager: NSObject, ObservableObject {

    // MARK: - Published state

    @Published var isRecording = false
    @Published var motionDetected = false
    @Published var clipCount = 0          // current clip index (0-based while recording)
    @Published var savedClipCount = 0     // clips fully written to disk
    @Published var currentClipDuration = "0:00"
    @Published var cameraPosition: AVCaptureDevice.Position = .back
    /// True once the AVCaptureSession is running and producing frames.
    @Published var isCameraReady = false
    /// True if the user denied camera permission — lets the UI show a helpful prompt.
    @Published var cameraPermissionDenied = false

    // MARK: - Dependencies

    weak var notificationManager: NotificationManager?
    var settings:        SettingsModel?
    var storageProvider: StorageProvider?
    private let smtpSender = SmtpSender()

    // MARK: - Live streaming

    // Written on main thread (start/stop recording), read on motionQueue (pushBuffer).
    // A nil/stale read at most drops one frame — intentionally lock-free.
    nonisolated(unsafe) private var streamSender: P2PStreamSender?

    private var aliveTimer: Timer?   // heartbeat: writes sc_alive_ every 30 s
    private var pollTimer:  Timer?   // polls sc_req_ every 5 s for viewer requests
    private var kvObserver: NSObjectProtocol?  // fires immediately on external KV change

    /// Kept in sync with ContentView's idle state.
    /// Email is only queued when the screen is black (unattended monitoring).
    var isIdle: Bool = false

    // MARK: - AVFoundation

    let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private let motionQueue = DispatchQueue(label: "motion.detection.queue", qos: .utility)
    private var currentVideoInput: AVCaptureDeviceInput?

    // MARK: - Clip rotation

    private var clipTimer: Timer?
    private var durationTimer: Timer?
    private var motionRotationTimer: Timer?   // fires 5 s after idle-motion to cut the clip early
    private var clipStartTime: Date?          // used for the UI duration label (main thread)
    private var recordingStartTime: Date?     // set immediately on the AVFoundation queue for accurate math

    // MARK: - Motion detection

    // Store a small downsampled snapshot of the previous frame for comparison
    private var previousFrameSamples: [UInt8]?
    private let sampleCols = 80
    private let sampleRows = 45
    private let motionThreshold = 0.025   // 2.5% mean pixel change
    private var frameCounter = 0
    private let frameSkip = 10            // analyse every 10th frame (~3 checks/sec at 30fps)

    private var lastMotionAlertDate: Date?
    private let alertCooldown: TimeInterval = 30

    /// Tracks when the last alert email was sent so we respect the user's cooldown setting.
    private var lastEmailSentDate: Date?

    // Motion tracking per clip:
    //  • motionDetectedInCurrentClip — any motion → writes a .motion marker file
    //    so the video browser can highlight the clip.
    //  • motionWhileIdleInCurrentClip — motion that happened while the screen
    //    was black → triggers the email with the extracted video.
    private var motionDetectedInCurrentClip  = false
    private var motionTimeInCurrentClip: Date?
    private var motionWhileIdleInCurrentClip = false
    private var motionWhileIdleTime: Date?

    // MARK: - Background

    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    /// URL of the clip currently being recorded.
    /// Set in didStartRecordingTo so commitCurrentClip() can write the .ready
    /// sidecar synchronously when the user navigates away — before AVFoundation's
    /// async didFinishRecordingTo callback has a chance to fire.
    private(set) var currentClipURL: URL?

    /// Set to true when `didFinishRecordingTo` fires during an interruption
    /// (connections inactive) so the foreground/interruption-ended handler
    /// knows to restart the movie output automatically.
    private var needsRestartAfterInterruption = false
    /// True while the app is backgrounded (hardware lock pressed).
    /// Used in didFinishRecordingTo to prevent starting audio-only clips during
    /// a lock — those clips never gain video and take 5 min to appear in browser.
    private var isInBackground = false

    // MARK: - Public API

    func setup() {
        requestCameraPermission()
        registerBackgroundNotifications()
    }

    /// Writes the .ready (and optional .motion) sidecar for the clip that is
    /// currently being recorded, WITHOUT stopping the recording.
    ///
    /// Call this immediately when the user navigates away from the camera screen
    /// so the clip appears in the browser right away. The .mov file already
    /// exists on disk (AVFoundation creates it when startRecording is called);
    /// we just need the .ready sidecar so the browser's scan can find it.
    /// didFinishRecordingTo will call commitSync again later — that's a harmless
    /// no-op (it just overwrites the same zero-byte file).
    func commitCurrentClip() {
        guard let url = currentClipURL else { return }
        storageProvider?.commitSync(fileURL: url, hasMotion: motionDetectedInCurrentClip)
    }

    func startRecording() {
        guard !movieOutput.isRecording else { return }
        guard movieOutput.connections.contains(where: { $0.isActive && $0.isEnabled }) else {
            dlog("SecurityCam: no active capture connections — camera unavailable on this device/simulator")
            return
        }
        let url = nextClipURL()
        movieOutput.startRecording(to: url, recordingDelegate: self)

        DispatchQueue.main.async {
            self.isRecording = true
            self.clipStartTime = Date()
        }

        scheduleClipTimer()
        scheduleDurationTimer()

        // P2P live streaming: clear any stale viewer request, announce alive, start polling.
        let deviceName = settings?.deviceName ?? UIDevice.current.name
        StreamSignaling.shared.cancelRequest(targetSlug: StreamSignaling.slug(for: deviceName))
        StreamSignaling.shared.announceAlive(deviceName: deviceName)
        startAliveHeartbeat(deviceName: deviceName)
        startRequestPolling(deviceName: deviceName)
    }

    func switchCamera() {
        // Seal the current clip before swapping inputs so the pre-switch footage
        // gets its own complete file. Without this, removing the video input mid-
        // recording causes AVFoundation to interrupt the output unpredictably —
        // sometimes producing a mixed-camera clip, sometimes losing the tail end.
        if movieOutput.isRecording {
            rotateClip()
        }

        sessionQueue.async {
            let newPosition: AVCaptureDevice.Position = self.cameraPosition == .back ? .front : .back
            guard
                let newDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition),
                let newInput = try? AVCaptureDeviceInput(device: newDevice)
            else { return }

            self.session.beginConfiguration()
            if let current = self.currentVideoInput {
                self.session.removeInput(current)
            }
            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.currentVideoInput = newInput
            }
            self.session.commitConfiguration()

            // Reset motion baseline so a camera flip doesn't trigger a false alert
            self.previousFrameSamples = nil

            DispatchQueue.main.async {
                self.cameraPosition = newPosition
            }
        }
    }

    func stopRecording() {
        clipTimer?.invalidate(); clipTimer = nil
        durationTimer?.invalidate(); durationTimer = nil
        motionRotationTimer?.invalidate(); motionRotationTimer = nil
        needsRestartAfterInterruption = false

        if movieOutput.isRecording {
            movieOutput.stopRecording()
        }

        // Stop P2P streaming and remove the alive signal.
        aliveTimer?.invalidate(); aliveTimer = nil
        pollTimer?.invalidate();  pollTimer  = nil
        if let obs = kvObserver { NotificationCenter.default.removeObserver(obs) }
        kvObserver = nil
        streamSender?.disconnect()
        streamSender = nil
        let deviceName = settings?.deviceName ?? UIDevice.current.name
        StreamSignaling.shared.clearAlive(deviceName: deviceName)

        DispatchQueue.main.async {
            self.isRecording = false
            self.currentClipDuration = "0:00"
            self.clipStartTime = nil
        }
    }

    // MARK: - Private setup

    private func requestCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            sessionQueue.async { self.configureCaptureSession() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    self.sessionQueue.async { self.configureCaptureSession() }
                } else {
                    DispatchQueue.main.async { self.cameraPermissionDenied = true }
                }
            }
        default:
            DispatchQueue.main.async { self.cameraPermissionDenied = true }
        }
    }

    private func configureCaptureSession() {
        // Take manual control of the audio session so our configuration
        // (playAndRecord + mixWithOthers) is not overridden by the capture
        // session's automatic management. Must be set before beginConfiguration.
        session.automaticallyConfiguresApplicationAudioSession = false
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720

        // Video input
        guard
            let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
            session.canAddInput(videoInput)
        else {
            session.commitConfiguration()
            return
        }
        session.addInput(videoInput)
        currentVideoInput = videoInput

        // Audio input
        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }

        // Movie file output (for saving clips)
        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }

        // Video data output (for motion detection)
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoDataOutput.setSampleBufferDelegate(self, queue: motionQueue)
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
        }

        session.commitConfiguration()
        configureAudioSession()
        session.startRunning()

        DispatchQueue.main.async {
            self.isCameraReady = true
            self.startRecording()
        }
    }

    /// Use `.playAndRecord` / `.videoRecording` with `.mixWithOthers` so iOS
    /// keeps the app alive in the background via the `audio` background mode
    /// declared in Info.plist.
    private func configureAudioSession() {
        do {
            let s = AVAudioSession.sharedInstance()
            // .default mode has the most permissive background-audio priority;
            // .mixWithOthers lets music apps continue alongside our session.
            try s.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
            try s.setActive(true)
        } catch {
            dlog("AVAudioSession error: \(error)")
        }
    }

    // MARK: - Clip rotation helpers

    private func scheduleClipTimer() {
        clipTimer?.invalidate()
        let duration = settings?.chunkDuration ?? 300
        clipTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.rotateClip()
        }
    }

    private func scheduleDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshDurationLabel()
        }
    }

    private func rotateClip() {
        guard movieOutput.isRecording else { return }
        // stopRecording → didFinishRecordingTo → starts next clip
        movieOutput.stopRecording()
    }

    private func refreshDurationLabel() {
        guard let start = clipStartTime else { return }
        let elapsed  = Int(Date().timeIntervalSince(start))
        let totalMin = settings?.chunkDurationMinutes ?? 5
        let m = elapsed / 60
        let s = elapsed % 60
        currentClipDuration = String(format: "%d:%02d / %d:00", m, s, totalMin)
    }

    // MARK: - P2P live streaming helpers

    private func startAliveHeartbeat(deviceName: String) {
        aliveTimer?.invalidate()
        aliveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            StreamSignaling.shared.announceAlive(deviceName: deviceName)
        }
    }

    private func startRequestPolling(deviceName: String) {
        pollTimer?.invalidate()
        // Respond immediately to external KV changes (fast path).
        kvObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleStreamRequest(deviceName: deviceName)
        }
        // Also poll every 5 s in case the KV notification is delayed.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.handleStreamRequest(deviceName: deviceName)
        }
        // Check immediately in case a request was already waiting.
        handleStreamRequest(deviceName: deviceName)
    }

    private func handleStreamRequest(deviceName: String) {
        guard let req = StreamSignaling.shared.pendingRequest(for: deviceName) else { return }
        // Skip only if we already have a live connection to exactly this viewer.
        if let sender = streamSender,
           sender.isConnected,
           sender.viewerAddress == "\(req.ip):\(req.port)" { return }
        dlog("CameraManager: stream request from \(req.ip):\(req.port) — connecting")
        streamSender?.disconnect()
        let sender = P2PStreamSender()
        sender.viewerAddress = "\(req.ip):\(req.port)"
        streamSender = sender
        sender.connect(to: req.ip, port: req.port)
    }

    private func nextClipURL() -> URL {
        let deviceName = settings?.deviceName ?? UIDevice.current.name
        if let provider = storageProvider {
            return provider.nextRecordingURL(deviceName: deviceName)
        }
        // Fallback: local Documents (no cloud sync)
        let now    = Date()
        let dayFmt = DateFormatter(); dayFmt.dateFormat = "yyyy-MM-dd"
        let timFmt = DateFormatter(); timFmt.dateFormat = "HH-mm-ss"
        let dir    = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VigilCam/\(dayFmt.string(from: now))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(timFmt.string(from: now)).mov")
    }

    // MARK: - Motion detection

    private func analyse(sampleBuffer: CMSampleBuffer) {
        frameCounter += 1
        guard frameCounter % frameSkip == 0 else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        let current = downsample(pixelBuffer)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)

        defer { previousFrameSamples = current }
        guard let previous = previousFrameSamples else { return }

        let change = meanAbsDiff(current, previous)
        guard change > motionThreshold else { return }

        let now = Date()
        if let last = lastMotionAlertDate, now.timeIntervalSince(last) < alertCooldown { return }
        lastMotionAlertDate = now

        DispatchQueue.main.async {
            self.motionDetected = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.motionDetected = false
            }
        }
        notificationManager?.sendMotionAlert()

        // Always mark the clip — browser uses this to badge motion clips.
        if !motionDetectedInCurrentClip {
            motionDetectedInCurrentClip = true
            motionTimeInCurrentClip = now
        }
        // Only queue an email when the screen is black (device unattended)
        // and the per-email cooldown has elapsed.
        let emailCooldown = TimeInterval((settings?.emailCooldownMinutes ?? 10) * 60)
        let emailReady = lastEmailSentDate.map { now.timeIntervalSince($0) >= emailCooldown } ?? true
        if isIdle && !motionWhileIdleInCurrentClip && emailReady {
            motionWhileIdleInCurrentClip = true
            motionWhileIdleTime = now
            lastEmailSentDate = now          // mark now so back-to-back clips don't all send
            // Cut the clip 5 s after motion so the email goes out quickly
            // rather than waiting for the full chunk duration to elapse.
            DispatchQueue.main.async {
                self.motionRotationTimer?.invalidate()
                self.motionRotationTimer = Timer.scheduledTimer(
                    withTimeInterval: 5, repeats: false
                ) { [weak self] _ in
                    self?.rotateClip()
                }
            }
        }
    }

    /// Extract a small grid of luminance samples from a BGRA pixel buffer.
    private func downsample(_ buffer: CVPixelBuffer) -> [UInt8] {
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        var samples = [UInt8]()
        samples.reserveCapacity(sampleCols * sampleRows)

        for row in 0..<sampleRows {
            for col in 0..<sampleCols {
                let x = col * w / sampleCols
                let y = row * h / sampleRows
                let offset = y * bpr + x * 4
                // Approximate luma from BGRA: 0.114*B + 0.587*G + 0.299*R
                let b = Int(bytes[offset])
                let g = Int(bytes[offset + 1])
                let r = Int(bytes[offset + 2])
                let luma = UInt8((b * 29 + g * 150 + r * 77) >> 8)
                samples.append(luma)
            }
        }
        return samples
    }

    private func meanAbsDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var sum = 0
        for i in 0..<a.count { sum += abs(Int(a[i]) - Int(b[i])) }
        return Double(sum) / Double(a.count * 255)
    }

    // MARK: - Motion marker

    /// Creates an empty `<clip-name>.motion` sidecar file next to the clip.
    /// The video browser reads this to badge clips that contain motion.
    private func writeMotionMarker(for clipURL: URL) {
        let markerURL = clipURL.deletingPathExtension().appendingPathExtension("motion")
        try? Data().write(to: markerURL)
    }

    // MARK: - Motion clip extraction

    /// Extracts a ±2 s clip around the motion event, sends the alert email,
    /// and awaits completion.
    /// Called before `finaliseRecording` so the source file is still on disk.
    private func extractAndEmailAsync(sourceURL:  URL,
                                      motionTime: Date,
                                      clipStart:  Date,
                                      settings:   SettingsModel) async {
        let asset = AVURLAsset(url: sourceURL)
        // cancelLoading() releases all internal decode buffers held by the asset
        // and any associated export sessions once we're done — prevents OOM.
        defer { asset.cancelLoading() }

        // ── 1. Trim a ±2 s window around the motion event ─────────────────
        let trimmedURL: URL?
        if let cmDur = try? await asset.load(.duration) {
            let total    = CMTimeGetSeconds(cmDur)
            let offset   = motionTime.timeIntervalSince(clipStart)
            let startSec = max(0, offset - 2)
            let endSec   = min(total, offset + 2)

            if endSec > startSec,
               let session = AVAssetExportSession(asset: asset,
                                                  presetName: AVAssetExportPresetMediumQuality) {
                let tmp = sourceURL.deletingLastPathComponent()
                    .appendingPathComponent("motion_extract.mp4")
                try? FileManager.default.removeItem(at: tmp)
                session.outputURL      = tmp
                session.outputFileType = .mp4
                session.timeRange      = CMTimeRange(
                    start:    CMTime(seconds: startSec,          preferredTimescale: 600),
                    duration: CMTime(seconds: endSec - startSec, preferredTimescale: 600))
                await session.export()
                trimmedURL = session.status == .completed ? tmp : nil
            } else {
                trimmedURL = nil
            }
        } else {
            trimmedURL = nil
        }

        // ── 2. Send email and await its completion ────────────────────────
        let videoURL = trimmedURL ?? sourceURL
        let config   = SmtpSender.Config(host:     settings.smtpHost,
                                         port:     settings.smtpPort,
                                         username: settings.smtpUsername,
                                         password: settings.smtpPassword)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            smtpSender.sendMotionAlert(config:   config,
                                       to:       settings.recipientEmail,
                                       at:       motionTime,
                                       videoURL: videoURL) { error in
                if let error { dlog("📧 Motion email failed: \(error.localizedDescription)") }
                if let tmp = trimmedURL { try? FileManager.default.removeItem(at: tmp) }
                cont.resume()
            }
        }
    }

    // MARK: - Background & interruption handling

    /// Register for audio-session and capture-session interruption events so
    /// recording survives phone calls and continues when the phone is locked.
    private func registerBackgroundNotifications() {
        let nc = NotificationCenter.default

        // Audio session interrupted / resumed (e.g. incoming call)
        nc.addObserver(self,
                       selector: #selector(handleAudioInterruption(_:)),
                       name: AVAudioSession.interruptionNotification,
                       object: AVAudioSession.sharedInstance())

        // Capture session interrupted / resumed (e.g. another app takes camera)
        nc.addObserver(self,
                       selector: #selector(handleCaptureInterrupted(_:)),
                       name: .AVCaptureSessionWasInterrupted,
                       object: session)

        nc.addObserver(self,
                       selector: #selector(handleCaptureInterruptionEnded(_:)),
                       name: .AVCaptureSessionInterruptionEnded,
                       object: session)

        // App moves to background — re-assert the audio session so iOS keeps
        // the capture pipeline alive under the audio background mode.
        nc.addObserver(self,
                       selector: #selector(handleAppBackground),
                       name: UIApplication.didEnterBackgroundNotification,
                       object: nil)

        // App returns to foreground (didBecomeActive fires after the session is
        // fully ready, unlike willEnterForeground which is too early).
        nc.addObserver(self,
                       selector: #selector(handleAppForeground),
                       name: UIApplication.didBecomeActiveNotification,
                       object: nil)
    }

    @objc private func handleAudioInterruption(_ notification: Notification) {
        guard
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        switch type {
        case .began:
            dlog("CameraManager: audio session interrupted (e.g. phone call)")
        case .ended:
            dlog("CameraManager: audio interruption ended — reactivating audio session")
            configureAudioSession()
            if !session.isRunning {
                sessionQueue.async { self.session.startRunning() }
            }
        @unknown default:
            break
        }
    }

    @objc private func handleCaptureInterrupted(_ notification: Notification) {
        if let raw = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int {
            dlog("CameraManager: capture session interrupted — reason \(raw)")
        }
        guard isRecording else { return }
        // Keepalive is already running (started in startRecording).
        needsRestartAfterInterruption = true
    }

    @objc private func handleCaptureInterruptionEnded(_ notification: Notification) {
        dlog("CameraManager: capture interruption ended — resuming")
        // Re-assert the audio session on the main thread (AVAudioSession must
        // not be configured from a background queue) before restarting the
        // capture session on sessionQueue.
        configureAudioSession()
        sessionQueue.async {
            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async { self.restartRecordingIfNeeded() }
        }
    }

    @objc private func handleAppBackground() {
        isInBackground = true
        // Explicitly request background time BEFORE stopping the clip.
        // Covers the window between stopRecording() and didFinishRecordingTo,
        // where commitSync writes the .ready sidecar.
        beginBackgroundTask()
        // Do NOT call configureAudioSession() here — we set
        // automaticallyConfiguresApplicationAudioSession = false, so any manual
        // setCategory/setActive call here would briefly disrupt the audio session
        // and risk iOS suspending the app before didFinishRecordingTo fires.
        // The audio session is already active from when recording started.
        //
        // Rotate the current clip immediately so it appears in the browser after
        // unlock. didFinishRecordingTo sets needsRestartAfterInterruption so
        // recording resumes automatically when the screen is unlocked.
        if movieOutput.isRecording {
            rotateClip()
        }
    }

    @objc private func handleAppForeground() {
        isInBackground = false
        // Re-assert the audio session now that we're back in the foreground,
        // then restart the capture session if it stopped while locked.
        configureAudioSession()
        sessionQueue.async {
            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async { self.restartRecordingIfNeeded() }
        }
    }

    /// Restarts AVCaptureMovieFileOutput after a lock / interruption.
    /// Guards on `needsRestartAfterInterruption` so it only fires when the
    /// movie output was stopped by an interruption, not by the user.
    private func restartRecordingIfNeeded() {
        guard needsRestartAfterInterruption, isRecording, !movieOutput.isRecording else { return }

        // 1.5 s delay: the capture session needs time to fully warm up after
        // the video device becomes available again (0.5 s was often too tight).
        // A second attempt fires 3 s later in case connections aren't active yet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            if self.tryStartRecordingAfterInterruption() { return }
            // Connections not active yet — retry once more after another delay.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.tryStartRecordingAfterInterruption()
            }
        }
    }

    /// Returns true if recording was successfully restarted.
    @discardableResult
    private func tryStartRecordingAfterInterruption() -> Bool {
        guard needsRestartAfterInterruption,
              isRecording,
              !movieOutput.isRecording,
              movieOutput.connections.contains(where: { $0.isActive && $0.isEnabled })
        else { return false }

        needsRestartAfterInterruption = false
        let url = self.nextClipURL()
        self.movieOutput.startRecording(to: url, recordingDelegate: self)
        self.clipStartTime = Date()
        self.scheduleClipTimer()
        self.scheduleDurationTimer()
        self.clipCount += 1
        dlog("CameraManager: recording restarted after phone unlock")
        return true
    }

    // MARK: - Background task helpers

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "ClipSave") {
            self.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension CameraManager: AVCaptureFileOutputRecordingDelegate {

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        currentClipURL               = fileURL
        recordingStartTime           = Date()
        motionDetectedInCurrentClip  = false
        motionTimeInCurrentClip      = nil
        motionWhileIdleInCurrentClip = false
        motionWhileIdleTime          = nil
        motionRotationTimer?.invalidate()
        motionRotationTimer          = nil
        DispatchQueue.main.async {
            self.clipStartTime = Date()        // slight delay is fine — only drives the UI label
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        // Begin a background task to cover any email extraction that follows.
        // It is ended either inside sendClipEmail's completion handler (when
        // an email is sent) or immediately below (when no email is needed).
        beginBackgroundTask()

        DispatchQueue.main.async {
            self.savedClipCount += 1
        }

        // Start the next clip immediately — but ONLY in foreground with an
        // active video connection. Two cases require waiting for unlock instead:
        //
        //   1. isInBackground = true (hardware lock just pressed):
        //      The video device is being suspended; starting now would produce
        //      an audio-only clip that takes 5 minutes to appear in the browser.
        //
        //   2. Video connection inactive (device already suspended):
        //      Same problem — no point starting without the camera.
        //
        // In both cases set needsRestartAfterInterruption so the foreground
        // handler restarts recording with full video+audio after unlock.
        if isRecording {
            let videoConnectionActive = output.connections.contains(where: {
                $0.inputPorts.contains { $0.mediaType == .video }
                && $0.isActive && $0.isEnabled
            })
            if !isInBackground && videoConnectionActive {
                let url = nextClipURL()
                output.startRecording(to: url, recordingDelegate: self)
                DispatchQueue.main.async {
                    self.scheduleClipTimer()
                    self.clipCount += 1
                }
            } else {
                needsRestartAfterInterruption = true
                dlog("CameraManager: clip ended (background=\(isInBackground), videoActive=\(videoConnectionActive)) — will restart on unlock")
                // Race-condition safety: if handleAppForeground already fired
                // before this delegate ran (unlock was faster than the file was
                // written), restartRecordingIfNeeded() checked a false flag and
                // did nothing. Now the flag is true — kick it again so we don't
                // leave the app silently recording to no file.
                if !isInBackground {
                    DispatchQueue.main.async { self.restartRecordingIfNeeded() }
                }
            }
        }

        // Capture everything needed for async work before leaving this method.
        let capturedProvider   = storageProvider
        let hasMotion          = motionDetectedInCurrentClip
        let shouldEmail        = motionWhileIdleInCurrentClip && (settings?.emailConfigured ?? false)
        let capturedSettings   = settings
        let capturedMotionTime = motionWhileIdleTime
        let capturedClipStart  = recordingStartTime

        // Write .ready (and .motion) sidecars synchronously RIGHT NOW, before
        // launching the Task below. This guarantees the sidecar is on disk even
        // if the app is suspended before the Task ever gets CPU time — which
        // happens reliably when the phone is locked and the clip rotates.
        capturedProvider?.commitSync(fileURL: outputFileURL, hasMotion: hasMotion)
        dlog("CameraManager: .ready sidecar written synchronously for \(outputFileURL.lastPathComponent)")

        Task { [weak self] in
            guard let self else { return }

            // 1. Email first — it reads outputFileURL to extract a clip.
            //    Must run before finaliseRecording, which may delete the
            //    local file (Firebase uploads then removes the temp copy).
            if shouldEmail,
               let s          = capturedSettings,
               let motionTime = capturedMotionTime,
               let clipStart  = capturedClipStart {
                await self.extractAndEmailAsync(sourceURL:  outputFileURL,
                                                motionTime: motionTime,
                                                clipStart:  clipStart,
                                                settings:   s)
            }

            // 2. Finalise storage:
            //    • iCloud: writes .motion sidecar (file already in container)
            //    • Firebase: uploads .mov + .motion, then deletes the local temp
            await capturedProvider?.finaliseRecording(fileURL: outputFileURL,
                                                      hasMotion: hasMotion)

            // 3. Enforce storage quota — delete oldest clips if over the limit.
            let maxBytes = self.settings?.maxStorageBytes ?? 0
            if maxBytes > 0, let deviceName = self.settings?.deviceName {
                await capturedProvider?.enforceStorageQuota(deviceName: deviceName,
                                                            maxBytes: maxBytes)
            }

            self.endBackgroundTask()
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // autoreleasepool ensures CMSampleBuffer-derived Obj-C objects (CVPixelBuffer,
        // CIImage, etc.) are released after every frame rather than waiting for the
        // motionQueue's run-loop drain — the primary guard against OOM accumulation.
        autoreleasepool {
            streamSender?.pushBuffer(sampleBuffer)
            analyse(sampleBuffer: sampleBuffer)
        }
    }
}
