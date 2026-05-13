import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsModel
    @Environment(\.dismiss) private var dismiss

    @State private var testResult: String?
    @State private var isTesting = false

    private let chunkOptions    = [1, 2, 3, 5, 10, 15, 20, 30, 60]
    private let cooldownOptions = [5, 10, 15, 30, 60, 120, 240]
    private let storageOptions  = [0, 1, 2, 5, 10, 20, 50]   // GB; 0 = unlimited

    var body: some View {
        NavigationStack {
            Form {

                // MARK: - Storage
                Section {
                    Picker("Storage", selection: $settings.storageBackend) {
                        ForEach(StorageBackend.allCases) { backend in
                            Label(backend.rawValue, systemImage: backend.systemImage)
                                .tag(backend)
                        }
                    }
                    .pickerStyle(.navigationLink)
                } header: {
                    Text("Storage")
                } footer: {
                    Text(settings.storageBackend.description)
                }

                // MARK: - This Device
                Section {
                    LabeledRow(label: "Device Name") {
                        TextField("e.g. Living Room", text: $settings.deviceName)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("This Device")
                } footer: {
                    Text(deviceNameFooter)
                }

                // MARK: - Recording
                Section {
                    Picker("Chunk Duration", selection: $settings.chunkDurationMinutes) {
                        ForEach(chunkOptions, id: \.self) { min in
                            Text(min == 1 ? "1 minute" : "\(min) minutes").tag(min)
                        }
                    }
                    Picker("Storage Limit", selection: $settings.maxStorageGB) {
                        ForEach(storageOptions, id: \.self) { gb in
                            Text(gb == 0 ? "Unlimited" : "\(gb) GB").tag(gb)
                        }
                    }
                } header: {
                    Text("Recording")
                } footer: {
                    Text(recordingFooter)
                }

                // MARK: - Motion Alerts
                Section {
                    Toggle("Send Email on Motion", isOn: $settings.emailEnabled)

                    if settings.emailEnabled {
                        LabeledRow(label: "Send To") {
                            TextField("recipient@example.com", text: $settings.recipientEmail)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.emailAddress)
                                .multilineTextAlignment(.trailing)
                        }

                        Picker("Email Cooldown", selection: $settings.emailCooldownMinutes) {
                            ForEach(cooldownOptions, id: \.self) { min in
                                Text(cooldownLabel(min)).tag(min)
                            }
                        }
                    }
                } header: {
                    Text("Motion Alerts")
                } footer: {
                    if settings.emailEnabled {
                        Text("An alert email is sent when motion is detected while the screen is off. At most one email every \(cooldownLabel(settings.emailCooldownMinutes).lowercased()).")
                    }
                }

                // MARK: - SMTP Server
                if settings.emailEnabled {
                    Section {
                        LabeledRow(label: "SMTP Host") {
                            TextField("smtp.gmail.com", text: $settings.smtpHost)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .multilineTextAlignment(.trailing)
                        }

                        LabeledRow(label: "Port") {
                            TextField("465", value: $settings.smtpPort, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                        }

                        LabeledRow(label: "From Address") {
                            TextField("you@example.com", text: $settings.smtpUsername)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.emailAddress)
                                .multilineTextAlignment(.trailing)
                        }

                        LabeledRow(label: "Password") {
                            SecureField("Password or App Password", text: $settings.smtpPassword)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .multilineTextAlignment(.trailing)
                        }
                    } header: {
                        Text("SMTP Server")
                    } footer: {
                        Text(smtpFooter)
                            .foregroundColor(settings.smtpPassword.isEmpty ? .orange : .secondary)
                    }
                }

                // MARK: - Test
                if settings.emailEnabled {
                    Section {
                        Button {
                            runTestEmail()
                        } label: {
                            HStack {
                                if isTesting { ProgressView().padding(.trailing, 4) }
                                Text(isTesting ? "Sending…" : "Send Test Email")
                            }
                        }
                        .disabled(isTesting || !settings.emailConfigured)

                        if let result = testResult {
                            Text(result)
                                .font(.caption)
                                .foregroundColor(result.hasPrefix("✅") ? .green : .red)
                        }
                    } footer: {
                        Text("Sends a test email to confirm everything is working.")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Helpers

    private var smtpFooter: String {
        if settings.smtpPassword.isEmpty {
            return "⚠️ Password required. Works with any SMTP provider — Gmail, Outlook, Yahoo, iCloud Mail, or your own server. For Gmail, create an App Password at myaccount.google.com → Security → App Passwords."
        }
        return "Alerts are sent via \(settings.smtpHost). Port 465 uses SSL; port 587 uses STARTTLS."
    }

    private var deviceNameFooter: String {
        switch settings.storageBackend {
        case .local:
            return "Recordings are saved on this device under VigilCam/\(settings.deviceName)/."
        case .icloud:
            return "This name identifies your recordings in the video browser on other devices. Recordings are stored in iCloud Drive under VigilCam/\(settings.deviceName)/."
        case .firebase:
            return "This name identifies your recordings in the video browser on other devices. Recordings are uploaded to Firebase under VigilCam/\(settings.deviceName)/."
        }
    }

    private var recordingFooter: String {
        let chunkPart = "Each video clip will be \(settings.chunkDurationMinutes == 1 ? "1 minute" : "\(settings.chunkDurationMinutes) minutes") long. Takes effect on the next clip."
        if settings.maxStorageGB == 0 {
            return chunkPart
        }
        return chunkPart + " Oldest clips are automatically deleted once recordings exceed \(settings.maxStorageGB) GB."
    }

    private func cooldownLabel(_ minutes: Int) -> String {
        if minutes < 60  { return "\(minutes) minutes" }
        let hours = minutes / 60
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }

    // MARK: - Test email

    private func runTestEmail() {
        isTesting  = true
        testResult = nil

        let config = SmtpSender.Config(
            host:     settings.smtpHost,
            port:     settings.smtpPort,
            username: settings.smtpUsername,
            password: settings.smtpPassword
        )

        SmtpSender().sendMotionAlert(config: config,
                                     to: settings.recipientEmail,
                                     at: Date()) { error in
            isTesting  = false
            testResult = error == nil
                ? "✅ Test email sent successfully"
                : "❌ \(error!.localizedDescription)"
        }
    }
}

// MARK: - Small helper view

private struct LabeledRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack {
            Text(label)
            content()
        }
    }
}
