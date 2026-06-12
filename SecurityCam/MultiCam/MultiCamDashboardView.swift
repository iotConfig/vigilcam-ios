import SwiftUI
import AVFoundation

// MARK: - Dashboard

struct MultiCamDashboardView: View {
    @ObservedObject var settings: SettingsModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var session: MultiCamSession
    @State private var showManage  = false
    @State private var showBrowser = false

    init(settings: SettingsModel) {
        self.settings = settings
        _session = StateObject(wrappedValue: MultiCamSession(settings: settings))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            NavigationStack {
                ScrollView {
                    LazyVStack(spacing: 14) {

                        // ── Phone camera tile ────────────────────────────────
                        PhoneCamTile(manager: session.phoneCam, settings: settings)

                        // ── IP camera tiles ──────────────────────────────────
                        ForEach(session.ipCams) { slot in
                            IPCamTile(camera: slot.camera, manager: slot.manager)
                        }

                        // ── Empty IP camera call-to-action ───────────────────
                        if session.ipCams.isEmpty {
                            AddCameraPrompt { showManage = true }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                }
                // Record All / Stop All bar pinned above the tab-safe area
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    recordBar
                }
                .navigationTitle("Multi-Cam")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Done") {
                            Task { await session.deactivate() }
                            dismiss()
                        }
                    }
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        Button { showBrowser = true } label: {
                            Image(systemName: "play.rectangle.fill")
                        }
                        Button { showManage = true } label: {
                            Image(systemName: "video.badge.plus")
                        }
                    }
                }
                .toolbarColorScheme(.dark, for: .navigationBar)
            }
        }
        .onAppear     { session.activate() }
        .onDisappear  {
            Task { await session.deactivate() }
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background && session.isAnyRecording {
                // Keep recordings alive in background — idle timer stays
                // enabled (we leave it as-is); when foregrounded the user
                // can decide to stop.  But stop phone cam to avoid capture
                // session issues.
                session.phoneCam.commitCurrentClip()
                session.phoneCam.stopRecording()
            }
        }
        .onChange(of: session.isAnyRecording) { recording in
            // Guideline 2.5.4: only hold idle timer while actually recording.
            UIApplication.shared.isIdleTimerDisabled = recording
        }
        .onChange(of: settings.esp32Cameras) { cameras in
            session.syncCameras(cameras: cameras)
        }
        .sheet(isPresented: $showManage) {
            ESP32CameraListView(settings: settings)
        }
        .sheet(isPresented: $showBrowser) {
            VideoBrowserView(provider: LocalStorageProvider(), backend: .local)
        }
    }

    // MARK: - Record bar

    private var recordBar: some View {
        HStack(spacing: 16) {
            if session.isAnyRecording {
                Button {
                    Task { await session.stopAll() }
                } label: {
                    Label("Stop All", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button {
                    session.startAll()
                } label: {
                    Label("Record All", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.85, green: 0.1, blue: 0.1))
                .disabled(!session.phoneCam.isCameraReady)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.black.opacity(0.85))
        .overlay(alignment: .top) {
            Divider().background(.white.opacity(0.1))
        }
    }
}

// MARK: - Generic tile shell

private struct CamTileShell<Preview: View>: View {
    let name:        String
    let icon:        String
    let accentColor: Color
    let isRecording: Bool
    let duration:    String?
    let statusText:  String
    let isError:     Bool
    let canRecord:   Bool
    let onRecord:    () -> Void
    @ViewBuilder let preview: () -> Preview

    var body: some View {
        VStack(spacing: 0) {

            // ── Preview area ────────────────────────────────────────────────
            ZStack(alignment: .topLeading) {
                preview()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                // Recording badge
                if isRecording {
                    HStack(spacing: 5) {
                        RecordingPulse()
                        if let d = duration {
                            Text(d)
                                .font(.system(.caption, design: .monospaced).weight(.semibold))
                                .foregroundColor(.white)
                        }
                    }
                    .padding(8)
                    .background(.black.opacity(0.55))
                    .clipShape(Capsule())
                    .padding(8)
                }
            }
            .frame(height: 180)

            // ── Footer ──────────────────────────────────────────────────────
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(accentColor)

                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(statusText)
                        .font(.caption2)
                        .foregroundColor(isError ? .orange : (isRecording ? .red : .secondary))
                        .lineLimit(1)
                }

                Spacer()

                // Per-camera record button
                Button(action: onRecord) {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.35), lineWidth: 2)
                            .frame(width: 36, height: 36)
                        if isRecording {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.red)
                                .frame(width: 14, height: 14)
                        } else {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 24, height: 24)
                        }
                    }
                }
                .disabled(!canRecord)
                .opacity(canRecord ? 1 : 0.35)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(white: 0.1))
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isRecording ? Color.red.opacity(0.7) : Color.white.opacity(0.08),
                        lineWidth: 1.5)
        )
    }
}

// MARK: - Phone camera tile

private struct PhoneCamTile: View {
    @ObservedObject var manager: CameraManager
    let settings: SettingsModel

    var body: some View {
        CamTileShell(
            name:        settings.deviceName.isEmpty ? "iPhone Camera" : settings.deviceName,
            icon:        "iphone",
            accentColor: .blue,
            isRecording: manager.isRecording,
            duration:    manager.isRecording ? manager.currentClipDuration : nil,
            statusText:  phoneStatusText,
            isError:     manager.cameraPermissionDenied,
            canRecord:   manager.isCameraReady && !manager.cameraPermissionDenied,
            onRecord: {
                if manager.isRecording {
                    manager.commitCurrentClip()
                    manager.stopRecording()
                } else {
                    manager.startRecording()
                }
            }
        ) {
            if manager.isCameraReady {
                CameraPreviewView(session: manager.session,
                                  cameraPosition: manager.cameraPosition)
            } else if manager.cameraPermissionDenied {
                Color.black.overlay(
                    Label("Camera access denied", systemImage: "camera.slash.fill")
                        .foregroundColor(.secondary)
                )
            } else {
                Color.black.overlay(ProgressView().tint(.white))
            }
        }
    }

    private var phoneStatusText: String {
        if manager.cameraPermissionDenied { return "Access denied" }
        if !manager.isCameraReady         { return "Initialising…" }
        if manager.isRecording            { return "Recording" }
        return "Ready"
    }
}

// MARK: - IP camera tile

private struct IPCamTile: View {
    let camera: ESP32Camera
    @ObservedObject var manager: ESP32StreamManager

    var body: some View {
        CamTileShell(
            name:        camera.name,
            icon:        "camera.on.rectangle.fill",
            accentColor: .green,
            isRecording: manager.isRecording,
            duration:    manager.isRecording ? formatDuration(manager.clipDuration) : nil,
            statusText:  ipStatusText,
            isError:     manager.connectionError != nil && !manager.isConnected,
            canRecord:   manager.isConnected,
            onRecord: {
                if manager.isRecording {
                    Task { await manager.stopRecording() }
                } else {
                    manager.startRecording()
                }
            }
        ) {
            if let img = manager.previewImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.black.overlay(
                    VStack(spacing: 8) {
                        Image(systemName: "camera.on.rectangle")
                            .font(.largeTitle)
                            .foregroundColor(.white.opacity(0.15))
                        Text(camera.hostLabel)
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.25))
                    }
                )
            }
        }
    }

    private var ipStatusText: String {
        if let err = manager.connectionError, !manager.isConnected { return err }
        if manager.isRecording  { return "Recording" }
        if manager.isConnected  { return "Live · \(camera.hostLabel)" }
        return "Connecting…"
    }
}

// MARK: - Helpers

private func formatDuration(_ t: TimeInterval) -> String {
    let h = Int(t) / 3600, m = (Int(t) % 3600) / 60, s = Int(t) % 60
    return h > 0
        ? String(format: "%d:%02d:%02d", h, m, s)
        : String(format: "%02d:%02d", m, s)
}

private struct RecordingPulse: View {
    @State private var pulsing = false
    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 7, height: 7)
            .scaleEffect(pulsing ? 1.4 : 0.8)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                       value: pulsing)
            .onAppear { pulsing = true }
    }
}

// MARK: - Add camera prompt

private struct AddCameraPrompt: View {
    let onAdd: () -> Void
    var body: some View {
        Button(action: onAdd) {
            HStack(spacing: 14) {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundColor(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add IP Camera")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text("ESP32-CAM or any MJPEG stream")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .background(Color(white: 0.1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
