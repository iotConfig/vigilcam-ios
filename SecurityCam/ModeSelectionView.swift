import SwiftUI

// MARK: - Mode selection screen

struct ModeSelectionView: View {
    @ObservedObject var settings: SettingsModel
    let onCameraTapped: () -> Void
    let onViewerTapped: () -> Void
    let onLiveTapped:   () -> Void
    let onIPCamTapped:  () -> Void

    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {

                // ── Settings button (top-right) ───────────────────────────
                HStack {
                    Spacer()
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.title3)
                            .foregroundColor(.white.opacity(0.7))
                            .padding(12)
                            .background(.white.opacity(0.08))
                            .clipShape(Circle())
                    }
                    .padding(.top, 56)
                    .padding(.trailing, 24)
                }

                // ── Header ────────────────────────────────────────────────
                VStack(spacing: 12) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 52, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.white, .white.opacity(0.7)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )

                    Text("VigilCam")
                        .font(.largeTitle.weight(.bold))
                        .foregroundColor(.white)

                    Text("How do you want to use this device?")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 80)

                Spacer()

                // ── Mode cards ────────────────────────────────────────────
                VStack(spacing: 16) {
                    ModeCard(
                        icon:     "video.fill",
                        title:    "Security Camera",
                        subtitle: "Record and monitor this device continuously",
                        accent:   .red,
                        action:   onCameraTapped
                    )

                    ModeCard(
                        icon:     "play.rectangle.fill",
                        title:    "Review Videos",
                        subtitle: "Browse recordings saved from all devices",
                        accent:   Color(red: 0.2, green: 0.5, blue: 1.0),
                        action:   onViewerTapped
                    )

                    ModeCard(
                        icon:     "dot.radiowaves.left.and.right",
                        title:    "Live Streams",
                        subtitle: "Watch any device currently recording on your network",
                        accent:   Color(red: 0.8, green: 0.3, blue: 0.9),
                        action:   onLiveTapped
                    )

                    ModeCard(
                        icon:     "camera.on.rectangle.fill",
                        title:    "Multi-Cam",
                        subtitle: "Record this phone + ESP32 / MJPEG cameras simultaneously",
                        accent:   Color(red: 0.2, green: 0.8, blue: 0.4),
                        action:   onIPCamTapped
                    )
                }
                .padding(.horizontal, 28)

                Spacer()

                // ── Footer note (iCloud only) ─────────────────────────────
                if settings.storageBackend == .icloud {
                    Text("Both devices must use the same iCloud account")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.3))
                }
                Spacer().frame(height: 36)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings)
        }
    }
}

// MARK: - Mode card

private struct ModeCard: View {
    let icon:     String
    let title:    String
    let subtitle: String
    let accent:   Color
    let action:   () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 18) {

                // Icon badge
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(accent.opacity(0.18))
                        .frame(width: 58, height: 58)
                    Image(systemName: icon)
                        .font(.title2.weight(.semibold))
                        .foregroundColor(accent)
                }

                // Labels
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.white.opacity(0.3))
            }
            .padding(20)
            .background(Color.white.opacity(isPressed ? 0.12 : 0.07))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            .scaleEffect(isPressed ? 0.97 : 1)
            .animation(.easeInOut(duration: 0.1), value: isPressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded   { _ in isPressed = false }
        )
    }
}
