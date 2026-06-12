import SwiftUI
import AVKit

// MARK: - Recorder view

struct ESP32RecorderView: View {
    let camera:   ESP32Camera
    let settings: SettingsModel

    @StateObject private var manager = ESP32StreamManager()
    @Environment(\.dismiss)    private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var showBrowser  = false
    @State private var confirmStop  = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // ── Live preview ────────────────────────────────────────────────
            if let img = manager.previewImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea()
            } else {
                connectingPlaceholder
            }

            // ── HUD overlay ─────────────────────────────────────────────────
            VStack {
                topBar
                Spacer()
                bottomBar
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .navigationBarHidden(true)
        .onAppear  { manager.chunkDuration = settings.chunkDuration
                     manager.connect(camera: camera) }
        .onDisappear {
            Task { await manager.stopRecording() }
            manager.disconnect()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background && manager.isRecording {
                Task { await manager.stopRecording() }
            }
        }
        .sheet(isPresented: $showBrowser) {
            // Always browse local storage — that's where ESP32 recordings land.
            VideoBrowserView(provider: LocalStorageProvider(), backend: .local)
        }
        .confirmationDialog("Stop Recording?",
                            isPresented: $confirmStop,
                            titleVisibility: .visible) {
            Button("Stop & Save", role: .destructive) {
                Task { await manager.stopRecording() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current clip will be saved and recording will stop.")
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(12)
                    .background(.white.opacity(0.15))
                    .clipShape(Circle())
            }

            Spacer()

            // Camera name
            Text(camera.name)
                .font(.headline)
                .foregroundColor(.white)

            Spacer()

            // Review clips button
            Button { showBrowser = true } label: {
                Image(systemName: "play.rectangle.fill")
                    .font(.title3)
                    .foregroundColor(.white)
                    .padding(12)
                    .background(.white.opacity(0.15))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 56)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 16) {
            // Connection / recording status
            statusBadge

            // Record button
            Button {
                if manager.isRecording {
                    confirmStop = true
                } else {
                    manager.startRecording()
                }
            } label: {
                ZStack {
                    Circle()
                        .stroke(Color.white, lineWidth: 3)
                        .frame(width: 72, height: 72)
                    if manager.isRecording {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.red)
                            .frame(width: 28, height: 28)
                    } else {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 54, height: 54)
                    }
                }
            }
            .disabled(!manager.isConnected)
            .opacity(manager.isConnected ? 1 : 0.4)
            .padding(.bottom, 40)
        }
    }

    // MARK: - Status badge

    private var statusBadge: some View {
        Group {
            if manager.isRecording {
                RecordingBadge(duration: manager.clipDuration)
            } else if let err = manager.connectionError {
                Label(err, systemImage: "wifi.exclamationmark")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.6))
                    .clipShape(Capsule())
            } else if !manager.isConnected {
                Label("Connecting…", systemImage: "wifi")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.6))
                    .clipShape(Capsule())
            } else {
                Label("Live", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.green)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.6))
                    .clipShape(Capsule())
            }
        }
    }

    // MARK: - Connecting placeholder

    private var connectingPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.on.rectangle")
                .font(.system(size: 52))
                .foregroundColor(.white.opacity(0.3))
            Text("Connecting to \(camera.name)…")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.5))
            if manager.connectionError != nil {
                Text(manager.connectionError ?? "")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
    }
}

// MARK: - Recording badge

private struct RecordingBadge: View {
    let duration: TimeInterval
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .scaleEffect(pulsing ? 1.3 : 0.8)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                           value: pulsing)
                .onAppear { pulsing = true }
            Text("REC  \(formatDuration(duration))")
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.6))
        .clipShape(Capsule())
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600
        let m = (Int(t) % 3600) / 60
        let s = Int(t) % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}
