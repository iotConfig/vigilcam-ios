import SwiftUI
import AVFoundation

// MARK: - OnboardingView (container)

/// Six-step walkthrough shown once on first launch.
/// Guides the user through: storage choice, device name,
/// camera/microphone permissions, motion-alert email, and a summary.
///
/// Persisted via `@AppStorage("hasCompletedOnboarding")` in RootView.
struct OnboardingView: View {
    @ObservedObject var settings: SettingsModel
    let onComplete: () -> Void

    @State private var step = 0
    private let pageCount = 6

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            // ── Progress strip ─────────────────────────────────────────
            HStack(spacing: 6) {
                ForEach(0..<pageCount, id: \.self) { i in
                    Capsule()
                        .fill(i <= step ? Color.white : Color.white.opacity(0.2))
                        .frame(width: i == step ? 24 : 6, height: 6)
                        .animation(.easeInOut(duration: 0.3), value: step)
                }
            }
            .padding(.top, 64)
            .zIndex(1)

            // ── Pages ──────────────────────────────────────────────────
            TabView(selection: $step) {
                OBWelcomePage(onNext: advance)
                    .tag(0)
                OBStoragePage(settings: settings, onBack: retreat, onNext: advance)
                    .tag(1)
                OBDeviceNamePage(settings: settings, onBack: retreat, onNext: advance)
                    .tag(2)
                OBPermissionsPage(onBack: retreat, onNext: advance)
                    .tag(3)
                OBEmailPage(settings: settings, onBack: retreat, onNext: advance)
                    .tag(4)
                OBDonePage(settings: settings, onDone: onComplete)
                    .tag(5)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
    }

    private func advance() {
        withAnimation(.easeInOut(duration: 0.35)) {
            step = min(step + 1, pageCount - 1)
        }
    }

    private func retreat() {
        withAnimation(.easeInOut(duration: 0.35)) {
            step = max(step - 1, 0)
        }
    }
}

// MARK: - Page scaffold

/// Shared layout used by pages 1–4.
/// Reserves space for the progress-dot overlay, renders an icon badge,
/// title, body text, and slots custom content between the text and the buttons.
private struct OBShell<Content: View>: View {
    let icon:       String
    let iconColor:  Color
    let title:      String
    let bodyText:   String
    @ViewBuilder let content: () -> Content
    let primaryLabel:    String
    let primaryAction:   () -> Void
    var secondaryLabel:  String?       = nil
    var secondaryAction: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {

            Spacer().frame(height: 110)     // clears the progress-dot overlay

            // Icon badge
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 96, height: 96)
                Image(systemName: icon)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundColor(iconColor)
            }

            Text(title)
                .font(.title2.bold())
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.top, 20)
                .padding(.horizontal, 32)

            Text(bodyText)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.top, 10)
                .padding(.horizontal, 36)

            content()
                .padding(.top, 28)

            Spacer()

            // Primary button
            Button(action: primaryAction) {
                Text(primaryLabel)
                    .font(.headline)
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 28)

            // Optional back link
            if let sec = secondaryLabel, let secAction = secondaryAction {
                Button(action: secAction) {
                    Text(sec)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
                .padding(.top, 14)
            }

            Spacer().frame(height: 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Page 0: Welcome

private struct OBWelcomePage: View {
    let onNext: () -> Void

    private let features: [(icon: String, label: String, color: Color)] = [
        ("video.fill",                    "Continuous recording",     .red),
        ("play.rectangle.fill",           "Review from any device",   Color(red: 0.2, green: 0.5, blue: 1.0)),
        ("dot.radiowaves.left.and.right", "Live stream monitoring",   Color(red: 0.8, green: 0.3, blue: 0.9)),
    ]

    var body: some View {
        VStack(spacing: 0) {

            Spacer().frame(height: 110)

            // Large icon
            Image(systemName: "camera.fill")
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(colors: [.white, .white.opacity(0.55)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .padding(.bottom, 24)

            Text("Welcome to\nVigilCam")
                .font(.largeTitle.bold())
                .foregroundColor(.white)
                .multilineTextAlignment(.center)

            Text("Turn any iPhone into a 24/7 security system.")
                .font(.body)
                .foregroundColor(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.top, 12)
                .padding(.horizontal, 40)

            // Feature rows
            VStack(spacing: 14) {
                ForEach(features, id: \.icon) { f in
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(f.color.opacity(0.18))
                                .frame(width: 40, height: 40)
                            Image(systemName: f.icon)
                                .font(.body.weight(.semibold))
                                .foregroundColor(f.color)
                        }
                        Text(f.label)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.white.opacity(0.85))
                        Spacer()
                    }
                    .padding(.horizontal, 32)
                }
            }
            .padding(.top, 36)

            Spacer()

            // CTA
            Button(action: onNext) {
                Text("Get Started")
                    .font(.headline)
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 28)

            Spacer().frame(height: 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Page 1: Storage

private struct OBStoragePage: View {
    @ObservedObject var settings: SettingsModel
    let onBack: () -> Void
    let onNext: () -> Void

    var body: some View {
        OBShell(
            icon:      settings.storageBackend.systemImage,
            iconColor: backendColor,
            title:     "Where should recordings go?",
            bodyText:  "Choose where this device saves its video clips. You can change this later in Settings.",
            content: {
                VStack(spacing: 10) {
                    ForEach(StorageBackend.allCases) { backend in
                        OBBackendCard(
                            backend:    backend,
                            isSelected: settings.storageBackend == backend,
                            onTap:      { settings.storageBackend = backend }
                        )
                    }

                    if settings.storageBackend == .icloud {
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle")
                                .font(.caption)
                            Text("Both devices must be signed into the same Apple ID.")
                                .font(.caption)
                        }
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 28)
            },
            primaryLabel:    "Next",
            primaryAction:   onNext,
            secondaryLabel:  "Back",
            secondaryAction: onBack
        )
    }

    private var backendColor: Color {
        switch settings.storageBackend {
        case .local:    return Color(red: 0.3, green: 0.85, blue: 0.45)
        case .icloud:   return Color(red: 0.2, green: 0.6,  blue: 1.0)
        case .firebase: return Color(red: 1.0, green: 0.4,  blue: 0.2)
        }
    }
}

private struct OBBackendCard: View {
    let backend:    StorageBackend
    let isSelected: Bool
    let onTap:      () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Image(systemName: backend.systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(isSelected ? .white : .white.opacity(0.45))
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(backend.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(isSelected ? .white : .white.opacity(0.65))
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.white)
                }
            }
            .padding(16)
            .background(isSelected ? Color.white.opacity(0.12) : Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        isSelected ? Color.white.opacity(0.3) : Color.white.opacity(0.08),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - Page 2: Device Name

private struct OBDeviceNamePage: View {
    @ObservedObject var settings: SettingsModel
    let onBack: () -> Void
    let onNext: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        OBShell(
            icon:      "iphone",
            iconColor: Color(red: 0.2, green: 0.6, blue: 1.0),
            title:     "Name this device",
            bodyText:  "Give this iPhone a recognisable label. It appears in the recordings browser so you can tell devices apart.",
            content: {
                TextField("e.g. Living Room", text: $settings.deviceName)
                    .font(.body)
                    .padding(16)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(
                                focused ? Color.white.opacity(0.4) : Color.white.opacity(0.1),
                                lineWidth: 1
                            )
                    )
                    .foregroundColor(.white)
                    .tint(.white)
                    .focused($focused)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 28)
            },
            primaryLabel:    "Next",
            primaryAction:   { focused = false; onNext() },
            secondaryLabel:  "Back",
            secondaryAction: onBack
        )
        .contentShape(Rectangle())
        .onTapGesture { focused = false }
    }
}

// MARK: - Page 3: Permissions

private struct OBPermissionsPage: View {
    let onBack: () -> Void
    let onNext: () -> Void

    @State private var cameraStatus: AVAuthorizationStatus          = .notDetermined
    @State private var micStatus:    AVAudioSession.RecordPermission = .undetermined

    var body: some View {
        OBShell(
            icon:      "lock.shield.fill",
            iconColor: Color(red: 0.95, green: 0.75, blue: 0.1),
            title:     "Allow Access",
            bodyText:  "Camera and microphone access are required to record security footage on this device.",
            content: {
                VStack(spacing: 10) {
                    OBPermissionRow(
                        icon:        "camera.fill",
                        label:       "Camera",
                        statusText:  cameraStatusText,
                        statusColor: cameraStatusColor,
                        // "Settings" deep-link only shown when user has already denied
                        buttonLabel: cameraStatus == .denied || cameraStatus == .restricted
                                         ? "Settings" : nil,
                        onTap:       openSettings
                    )
                    OBPermissionRow(
                        icon:        "mic.fill",
                        label:       "Microphone",
                        statusText:  micStatusText,
                        statusColor: micStatusColor,
                        buttonLabel: micStatus == .denied ? "Settings" : nil,
                        onTap:       openSettings
                    )

                    if cameraStatus == .denied || micStatus == .denied {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                            Text("Go to Settings → VigilCam to grant access.")
                                .font(.caption)
                        }
                        .foregroundColor(.orange.opacity(0.85))
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 28)
            },
            // Always labelled "Continue" — tapping requests any outstanding
            // permissions in sequence before advancing to the next page.
            primaryLabel:    "Continue",
            primaryAction:   requestPermissionsThenAdvance,
            secondaryLabel:  "Back",
            secondaryAction: onBack
        )
        .onAppear { refreshStatus() }
    }

    // MARK: - Helpers

    private var cameraStatusText: String {
        switch cameraStatus {
        case .authorized:          return "Allowed"
        case .denied, .restricted: return "Denied"
        case .notDetermined:       return "Not yet requested"
        @unknown default:          return "Unknown"
        }
    }

    private var cameraStatusColor: Color {
        switch cameraStatus {
        case .authorized:          return .green
        case .denied, .restricted: return .red
        default:                   return .white.opacity(0.4)
        }
    }

    private var micStatusText: String {
        switch micStatus {
        case .granted:      return "Allowed"
        case .denied:       return "Denied"
        case .undetermined: return "Not yet requested"
        @unknown default:   return "Unknown"
        }
    }

    private var micStatusColor: Color {
        switch micStatus {
        case .granted: return .green
        case .denied:  return .red
        default:       return .white.opacity(0.4)
        }
    }

    private func refreshStatus() {
        cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        micStatus    = AVAudioSession.sharedInstance().recordPermission
    }

    /// Tapping "Continue" always walks through any undetermined permissions
    /// in sequence (camera first, then mic), then advances to the next page.
    private func requestPermissionsThenAdvance() {
        if cameraStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { _ in
                DispatchQueue.main.async {
                    refreshStatus()
                    requestMicThenAdvance()
                }
            }
        } else {
            requestMicThenAdvance()
        }
    }

    private func requestMicThenAdvance() {
        if micStatus == .undetermined {
            AVAudioSession.sharedInstance().requestRecordPermission { _ in
                DispatchQueue.main.async {
                    refreshStatus()
                    onNext()
                }
            }
        } else {
            onNext()
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct OBPermissionRow: View {
    let icon:        String
    let label:       String
    let statusText:  String
    let statusColor: Color
    let buttonLabel: String?     // nil = no button (already granted)
    let onTap:       () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.07))
                    .frame(width: 42, height: 42)
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundColor(.white.opacity(0.7))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(statusColor)
            }

            Spacer()

            if let btn = buttonLabel {
                Button(action: onTap) {
                    Text(btn)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Page 4: Email alerts

private struct OBEmailPage: View {
    @ObservedObject var settings: SettingsModel
    let onBack: () -> Void
    let onNext: () -> Void

    @FocusState private var focused: EmailField?
    enum EmailField { case recipient, username, password }

    var body: some View {
        OBShell(
            icon:      "envelope.badge.fill",
            iconColor: Color(red: 0.3, green: 0.75, blue: 0.45),
            title:     "Motion Alerts",
            bodyText:  "Receive an email when motion is detected. Works with Gmail, Outlook, Yahoo, iCloud Mail, or any SMTP server. You can also finish this in Settings.",
            content: {
                VStack(spacing: 10) {

                    // ── Enable toggle ──────────────────────────────────
                    HStack {
                        Text("Send email on motion")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.white)
                        Spacer()
                        Toggle("", isOn: $settings.emailEnabled)
                            .labelsHidden()
                            .tint(Color(red: 0.3, green: 0.75, blue: 0.45))
                    }
                    .padding(16)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    if settings.emailEnabled {

                        // ── Recipient ──────────────────────────────────
                        OBInputField(
                            label:       "Send alerts to",
                            placeholder: "recipient@example.com",
                            text:        $settings.recipientEmail,
                            focused:     $focused,
                            field:       .recipient,
                            keyboardType: .emailAddress
                        )

                        // ── From address (SMTP username) ───────────────
                        OBInputField(
                            label:       "From Address",
                            placeholder: "you@example.com",
                            text:        $settings.smtpUsername,
                            focused:     $focused,
                            field:       .username,
                            keyboardType: .emailAddress
                        )

                        // ── Password ───────────────────────────────────
                        OBSecureInputField(
                            label:       "Password",
                            placeholder: "Password or App Password",
                            text:        $settings.smtpPassword,
                            focused:     $focused,
                            field:       .password
                        )

                        Text("SMTP host and port can be changed in Settings. Defaults to Gmail (smtp.gmail.com:465). For Gmail, use an App Password rather than your regular password.")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.38))
                            .multilineTextAlignment(.leading)
                            .padding(.top, 2)
                    }
                }
                .padding(.horizontal, 28)
                .animation(.easeInOut(duration: 0.25), value: settings.emailEnabled)
            },
            primaryLabel:    "Next",
            primaryAction:   { focused = nil; onNext() },
            secondaryLabel:  settings.emailEnabled ? "Back" : "Skip",
            // "Back" retreats; "Skip" advances past email setup to the Done page
            secondaryAction: settings.emailEnabled ? onBack : { focused = nil; onNext() }
        )
        .contentShape(Rectangle())
        .onTapGesture { focused = nil }
    }
}

private struct OBInputField<F: Hashable>: View {
    let label:        String
    let placeholder:  String
    @Binding var text: String
    var focused:      FocusState<F?>.Binding
    let field:        F
    var keyboardType: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundColor(.white.opacity(0.5))
                .padding(.horizontal, 4)
            TextField(placeholder, text: $text)
                .font(.subheadline)
                .padding(14)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            focused.wrappedValue == field
                                ? Color.white.opacity(0.4)
                                : Color.white.opacity(0.1),
                            lineWidth: 1
                        )
                )
                .foregroundColor(.white)
                .tint(.white)
                .focused(focused, equals: field)
                .keyboardType(keyboardType)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }
}

private struct OBSecureInputField<F: Hashable>: View {
    let label:       String
    let placeholder: String
    @Binding var text: String
    var focused:     FocusState<F?>.Binding
    let field:       F

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundColor(.white.opacity(0.5))
                .padding(.horizontal, 4)
            SecureField(placeholder, text: $text)
                .font(.subheadline)
                .padding(14)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            focused.wrappedValue == field
                                ? Color.white.opacity(0.4)
                                : Color.white.opacity(0.1),
                            lineWidth: 1
                        )
                )
                .foregroundColor(.white)
                .tint(.white)
                .focused(focused, equals: field)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }
}

// MARK: - Page 5: Done

private struct OBDonePage: View {
    @ObservedObject var settings: SettingsModel
    let onDone: () -> Void

    var body: some View {
        OBShell(
            icon:      "checkmark.seal.fill",
            iconColor: Color(red: 0.3, green: 0.85, blue: 0.45),
            title:     "You're all set!",
            bodyText:  "Here's a summary of your setup.",
            content: {
                VStack(spacing: 10) {
                    OBSummaryRow(icon: "iphone",
                                 label: "Device Name",
                                 value: settings.deviceName)
                    OBSummaryRow(icon: settings.storageBackend.systemImage,
                                 label: "Storage",
                                 value: settings.storageBackend.rawValue)
                    OBSummaryRow(icon: "envelope.fill",
                                 label: "Motion Alerts",
                                 value: settings.emailEnabled
                                     ? (settings.recipientEmail.isEmpty ? "Enabled" : settings.recipientEmail)
                                     : "Off")
                    OBSummaryRow(icon: "video.fill",
                                 label: "Camera Mode",
                                 value: "Tap Security Camera to start")

                    // ── Settings hint ──────────────────────────────────
                    HStack(spacing: 10) {
                        Image(systemName: "gearshape.fill")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.4))
                        Text("You can change any of these settings later by tapping the **⚙︎** icon on the main screen.")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.07), lineWidth: 1)
                    )
                }
                .padding(.horizontal, 28)
            },
            primaryLabel:  "Start Using VigilCam",
            primaryAction: onDone
        )
    }
}

private struct OBSummaryRow: View {
    let icon:  String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white.opacity(0.5))
                .frame(width: 20)
            Text(label)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.55))
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
                .multilineTextAlignment(.trailing)
        }
        .padding(16)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
