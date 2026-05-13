import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var cameraManager       = CameraManager()
    @StateObject private var notificationManager = NotificationManager()
    @ObservedObject var settings: SettingsModel

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss)    private var dismiss

    @State private var showBrowser   = false
    @State private var isIdle        = false
    @State private var idleTimerTask: Task<Void, Never>?

    /// Saved so we can restore it exactly when the user wakes the screen.
    @State private var savedBrightness: CGFloat = UIScreen.main.brightness

    private let idleTimeout: TimeInterval = 30

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height

            ZStack {
                Color.black.ignoresSafeArea()

                CameraPreviewView(session: cameraManager.session,
                                  cameraPosition: cameraManager.cameraPosition)
                    .ignoresSafeArea()

                if isLandscape {
                    LandscapeOverlay(cameraManager: cameraManager,
                                     settings: settings,
                                     showBrowser: $showBrowser,
                                     onChangeMode: { dismiss() },
                                     onLockScreen: lockScreen)
                } else {
                    PortraitOverlay(cameraManager: cameraManager,
                                    settings: settings,
                                    showBrowser: $showBrowser,
                                    onChangeMode: { dismiss() },
                                    onLockScreen: lockScreen)
                }

                // ── Idle / locked dark overlay ────────────────────────────
                // Dims the display while the camera keeps recording.
                // App Store guideline 2.5.14: the app must not go blank during
                // recording and the indicator cannot be disabled — so the
                // LockScreenRecordingBadge is always shown on top while active.
                // Any touch wakes the screen.
                ZStack {
                    Color.black.ignoresSafeArea()
                    if cameraManager.isRecording {
                        LockScreenRecordingBadge()
                    }
                }
                .opacity(isIdle ? 1 : 0)
                .animation(.easeInOut(duration: 0.6), value: isIdle)
                .allowsHitTesting(isIdle)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in resetIdleTimer() }
                )

                // ── Camera startup splash ──────────────────────────────────
                // Covers the black preview layer while the session is
                // configuring, then fades away once frames are flowing.
                if !cameraManager.isCameraReady {
                    CameraStartupSplash(permissionDenied: cameraManager.cameraPermissionDenied)
                        .transition(.opacity)
                }
            }
            // Detect any touch on the camera/controls layer to reset idle timer
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in resetIdleTimer() }
            )
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.3), value: cameraManager.motionDetected)
        .animation(.easeInOut(duration: 0.5), value: cameraManager.isCameraReady)
        .sheet(isPresented: $showBrowser)  { VideoBrowserView(settings: settings) }
        .onAppear {
            notificationManager.requestPermission()
            cameraManager.notificationManager = notificationManager
            cameraManager.settings            = settings
            cameraManager.storageProvider     = StorageProviderFactory.make(backend: settings.storageBackend)
            cameraManager.setup()
            // Keep the display alive — we manage screen state ourselves.
            UIApplication.shared.isIdleTimerDisabled = true
            resetIdleTimer()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            restoreBrightness()
            idleTimerTask?.cancel()
            // Write .ready for the in-progress clip RIGHT NOW, synchronously,
            // so the browser finds it on its very first scan regardless of when
            // AVFoundation's async didFinishRecordingTo callback fires.
            // The .mov file already exists on disk; we're just committing the
            // sidecar that makes it visible in the browser.
            cameraManager.commitCurrentClip()
            // Then tell AVFoundation to properly finalise the file.
            cameraManager.stopRecording()
        }
        .onChange(of: isIdle) { newValue in
            cameraManager.isIdle = newValue
            if newValue {
                // Screen going dark: save brightness and dim the display.
                // Must not reach 0 — guideline 2.5.14 requires the recording
                // indicator to remain visible; a zero backlight would hide it.
                // isIdleTimerDisabled stays TRUE so iOS never auto-locks the
                // phone and sends the app to background while we're recording.
                savedBrightness = UIScreen.main.brightness
                UIScreen.main.brightness = 0.3
            } else {
                restoreBrightness()
                UIApplication.shared.isIdleTimerDisabled = true
            }
        }
        // Guideline 2.5.14: the app must never go blank while recording.
        // • Cancel the auto-dim timer while recording — guideline 2.5.14 prohibits
        //   the screen going blank *automatically* during recording.
        // • A user-initiated lock (lock button) is still allowed; the
        //   LockScreenRecordingBadge + brightness 0.3 keep the screen non-blank.
        // • Restart the timer when recording stops so the screen can still
        //   auto-dim during playback review or when the camera is stopped.
        .onChange(of: cameraManager.isRecording) { isNowRecording in
            if isNowRecording {
                idleTimerTask?.cancel()
                idleTimerTask = nil
            } else {
                resetIdleTimer()
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { resetIdleTimer() }
        }
        .onChange(of: settings.storageBackend) { _ in
            cameraManager.storageProvider = StorageProviderFactory.make(backend: settings.storageBackend)
        }
    }

    // MARK: - Screen lock / idle

    /// Dims the screen while keeping the app in the foreground so the camera
    /// pipeline runs uninterrupted.
    /// Allowed during recording — the LockScreenRecordingBadge + brightness 0.3
    /// keep the screen non-blank and the indicator visible (guideline 2.5.14).
    private func lockScreen() {
        idleTimerTask?.cancel()
        withAnimation(.easeOut(duration: 0.3)) { isIdle = true }
    }

    private func resetIdleTimer() {
        idleTimerTask?.cancel()
        if isIdle {
            withAnimation(.easeIn(duration: 0.3)) { isIdle = false }
        }
        idleTimerTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(idleTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // Never auto-dim while recording — guideline 2.5.14.
                guard !cameraManager.isRecording else { return }
                withAnimation(.easeOut(duration: 0.6)) { isIdle = true }
            }
        }
    }

    private func restoreBrightness() {
        // Never restore to exactly 0 — if the user had brightness at 0 before
        // entering the app, bring it up to a barely-visible 0.1 so they can see.
        UIScreen.main.brightness = max(savedBrightness, 0.1)
    }
}

// MARK: - Portrait overlay

private struct PortraitOverlay: View {
    @ObservedObject var cameraManager: CameraManager
    @ObservedObject var settings: SettingsModel
    @Binding var showBrowser: Bool
    let onChangeMode: () -> Void
    let onLockScreen: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // ── Top bar ───────────────────────────────────────────────────
            HStack(alignment: .center) {
                ChangeModeButton(action: onChangeMode)
                Spacer()
                RecIndicator(cameraManager: cameraManager)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Spacer()

            // ── Stats ─────────────────────────────────────────────────────
            StatsRow(cameraManager: cameraManager, settings: settings)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            // ── Bottom controls ───────────────────────────────────────────
            HStack {
                // Back
                OverlayIconButton(systemImage: "chevron.left",
                                  action: onChangeMode)

                Spacer()

                // Record
                RecordButton(cameraManager: cameraManager)

                Spacer()

                // Flip camera
                OverlayIconButton(systemImage: "arrow.triangle.2.circlepath.camera.fill",
                                  action: { cameraManager.switchCamera() })

                Spacer()

                // Lock screen (blacks out display while keeping camera running)
                OverlayIconButton(systemImage: "lock.fill", action: onLockScreen)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
    }
}

// MARK: - Landscape overlay

private struct LandscapeOverlay: View {
    @ObservedObject var cameraManager: CameraManager
    @ObservedObject var settings: SettingsModel
    @Binding var showBrowser: Bool
    let onChangeMode: () -> Void
    let onLockScreen: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Mode-switch pinned to top-left
            VStack(alignment: .leading, spacing: 6) {
                ChangeModeButton(action: onChangeMode)
                Spacer()
            }
            .padding(.top, 12)
            .padding(.leading, 16)

            Spacer()

            // Right-side control strip
            VStack(spacing: 20) {
                RecIndicator(cameraManager: cameraManager)

                Spacer()

                StatsColumn(cameraManager: cameraManager, settings: settings)

                Spacer()

                OverlayIconButton(systemImage: "chevron.left",
                                  action: onChangeMode)

                RecordButton(cameraManager: cameraManager)

                OverlayIconButton(systemImage: "arrow.triangle.2.circlepath.camera.fill",
                                  action: { cameraManager.switchCamera() })

                // Lock screen (blacks out display while keeping camera running)
                OverlayIconButton(systemImage: "lock.fill", action: onLockScreen)
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 16)
            .frame(width: 88)
            .background(.ultraThinMaterial.opacity(0.85))
        }
    }
}

// MARK: - Shared subviews

/// Prominent REC / STOPPED badge + motion alert.
///
/// Guideline 2.5.14: the recording indicator must be clearly visible and
/// non-disableable.  The red dot is 14 pt (with a 26 pt pulsing halo) and
/// the "● REC" text uses a subheadline-weight font so it is legible at a
/// glance on any screen size.
private struct RecIndicator: View {
    @ObservedObject var cameraManager: CameraManager

    var body: some View {
        HStack(spacing: 8) {
            // Red dot with pulsing halo when recording
            ZStack {
                if cameraManager.isRecording {
                    Circle()
                        .fill(Color.red.opacity(0.35))
                        .frame(width: 26, height: 26)
                        .scaleEffect(cameraManager.isRecording ? 1 : 0.5)
                        .animation(
                            .easeInOut(duration: 0.85).repeatForever(autoreverses: true),
                            value: cameraManager.isRecording)
                }
                Circle()
                    .fill(cameraManager.isRecording ? Color.red : Color.gray.opacity(0.7))
                    .frame(width: 14, height: 14)
            }

            Text(cameraManager.isRecording ? "REC" : "STOPPED")
                .font(.subheadline.weight(.bold))
                .foregroundColor(.white)

            if cameraManager.motionDetected {
                HStack(spacing: 3) {
                    Image(systemName: "figure.walk.motion")
                    Text("MOTION")
                }
                .font(.caption.weight(.bold))
                .foregroundColor(.yellow)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(cameraManager.isRecording
                    ? .red.opacity(0.18)
                    : .black.opacity(0.45))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(
                    cameraManager.isRecording ? Color.red.opacity(0.6) : Color.clear,
                    lineWidth: 1.5)
        )
    }
}

/// Compact stats for portrait
private struct StatsRow: View {
    @ObservedObject var cameraManager: CameraManager
    @ObservedObject var settings: SettingsModel

    var body: some View {
        HStack {
            statLabel("Clip \(cameraManager.clipCount + 1)", icon: "film")
            Spacer()
            statLabel(cameraManager.currentClipDuration, icon: "clock")
            Spacer()
            statLabel("\(cameraManager.savedClipCount) saved", icon: "tray.full")
            Spacer()
            statLabel("\(settings.chunkLabel) chunks", icon: "scissors")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func statLabel(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2)
            .foregroundColor(.white.opacity(0.85))
    }
}

/// Compact stats for landscape side panel
private struct StatsColumn: View {
    @ObservedObject var cameraManager: CameraManager
    @ObservedObject var settings: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            statLabel("Clip \(cameraManager.clipCount + 1)", icon: "film")
            statLabel(cameraManager.currentClipDuration, icon: "clock")
            statLabel("\(cameraManager.savedClipCount) saved", icon: "tray.full")
            statLabel("\(settings.chunkLabel) chunks", icon: "scissors")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statLabel(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2)
            .foregroundColor(.white.opacity(0.85))
    }
}

/// Subtle "change mode" button shown below the gear — lets the user return to
/// the mode-selection screen without cluttering the main camera UI.
private struct ChangeModeButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 10, weight: .medium))
                Text("Modes")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(.white.opacity(0.45))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.3))
            .clipShape(Capsule())
        }
    }
}

/// Floating gear button (top-left over image)
private struct GearButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape.fill")
                .font(.title3)
                .foregroundColor(.white)
                .padding(10)
                .background(.black.opacity(0.45))
                .clipShape(Circle())
        }
    }
}

/// Generic floating icon button (folder, flip, etc.)
private struct OverlayIconButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundColor(.white)
                .frame(width: 52, height: 52)
                .background(.black.opacity(0.45))
                .clipShape(Circle())
        }
    }
}

/// Large central record / stop button (native camera app style)
private struct RecordButton: View {
    @ObservedObject var cameraManager: CameraManager

    var body: some View {
        Button(action: {
            if cameraManager.isRecording { cameraManager.stopRecording() }
            else                         { cameraManager.startRecording() }
        }) {
            ZStack {
                // Outer white ring
                Circle()
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 72, height: 72)

                // Inner indicator: red circle (recording) or red dot (stopped)
                if cameraManager.isRecording {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.red)
                        .frame(width: 28, height: 28)
                } else {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 56, height: 56)
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: cameraManager.isRecording)
    }
}

// MARK: - Lock screen recording badge

/// Shown centred on the dark idle overlay while the camera is recording.
///
/// App Store guideline 2.5.14 requires a clear, non-disableable visual
/// indicator that the app is recording; the app must not go blank while
/// recording is active.
private struct LockScreenRecordingBadge: View {
    @State private var pulsing = false

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                // Outer breathing ring
                Circle()
                    .fill(Color.red.opacity(0.25))
                    .frame(width: 72, height: 72)
                    .scaleEffect(pulsing ? 1.2 : 0.85)
                    .animation(
                        .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                        value: pulsing)
                // Solid core
                Circle()
                    .fill(Color.red)
                    .frame(width: 28, height: 28)
            }

            Text("RECORDING")
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .tracking(3)

            Text("Tap to wake")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.4))
        }
        .onAppear { pulsing = true }
    }
}

// MARK: - Camera Preview

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let cameraPosition: AVCaptureDevice.Position

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.session = session
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        uiView.cameraPosition = cameraPosition
    }
}

// MARK: - Camera startup splash

/// Shown while AVCaptureSession is configuring. Matches the launch screen
/// so there is no jarring black flash between app launch and first frame.
private struct CameraStartupSplash: View {
    let permissionDenied: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 24) {
                // App icon — same image used on the launch screen
                Image("LaunchLogo")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .shadow(color: .red.opacity(0.4), radius: 20)

                if permissionDenied {
                    VStack(spacing: 10) {
                        Text("Camera Access Required")
                            .font(.headline)
                            .foregroundColor(.white)
                        Text("Enable camera access in Settings to use VigilCam.")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .padding(.top, 4)
                    }
                } else {
                    VStack(spacing: 8) {
                        ProgressView()
                            .tint(.white)
                        Text("Starting camera…")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
            }
        }
    }
}

// MARK: - Camera Preview

final class CameraPreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    var session: AVCaptureSession? {
        didSet { previewLayer.session = session }
    }

    var cameraPosition: AVCaptureDevice.Position = .back {
        didSet { updateVideoOrientation() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = bounds
        updateVideoOrientation()
    }

    private func updateVideoOrientation() {
        guard let connection = previewLayer.connection else { return }
        let orientation = UIDevice.current.orientation
        let isFront = cameraPosition == .front

        if #available(iOS 17.0, *) {
            let angle: CGFloat
            switch orientation {
            case .landscapeLeft:       angle = isFront ? 180 : 0
            case .landscapeRight:      angle = isFront ? 0   : 180
            case .portraitUpsideDown:  angle = 270
            default:                   angle = 90
            }
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        } else {
            guard connection.isVideoOrientationSupported else { return }
            switch orientation {
            case .landscapeLeft:       connection.videoOrientation = isFront ? .landscapeLeft  : .landscapeRight
            case .landscapeRight:      connection.videoOrientation = isFront ? .landscapeRight : .landscapeLeft
            case .portraitUpsideDown:  connection.videoOrientation = .portraitUpsideDown
            default:                   connection.videoOrientation = .portrait
            }
        }
    }
}
