import Foundation
import UIKit

/// Persists all user-configurable settings via UserDefaults.
final class SettingsModel: ObservableObject {

    private enum Key {
        static let chunkMinutes   = "chunkDurationMinutes"
        static let emailEnabled   = "emailEnabled"
        static let recipient      = "recipientEmail"
        static let emailCooldown  = "emailCooldownMinutes"
        static let deviceName     = "deviceName"
        static let storageBackend = "storageBackend"
        static let maxStorageGB   = "maxStorageGB"
        // SMTP — stored in UserDefaults, never hardcoded.
        static let smtpHost       = "smtpHost"
        static let smtpPort       = "smtpPort"
        static let smtpUsername   = "smtpUsername"
        static let smtpPassword   = "smtpPassword"
    }

    private let ud = UserDefaults.standard

    @Published var chunkDurationMinutes: Int  { didSet { ud.set(chunkDurationMinutes, forKey: Key.chunkMinutes)  } }
    @Published var emailEnabled: Bool         { didSet { ud.set(emailEnabled,         forKey: Key.emailEnabled)  } }
    @Published var recipientEmail: String     { didSet { ud.set(recipientEmail,       forKey: Key.recipient)     } }
    /// Minimum gap between alert emails (minutes). Prevents inbox flooding.
    @Published var emailCooldownMinutes: Int  { didSet { ud.set(emailCooldownMinutes, forKey: Key.emailCooldown) } }
    /// Human-readable name for this device, shown in the video browser on other devices.
    @Published var deviceName: String         { didSet { ud.set(deviceName,           forKey: Key.deviceName)   } }
    /// Which cloud backend stores recordings.
    @Published var storageBackend: StorageBackend {
        didSet { ud.set(storageBackend.rawValue, forKey: Key.storageBackend) }
    }
    /// Maximum total recording storage in GB. 0 = unlimited.
    @Published var maxStorageGB: Int {
        didSet { ud.set(maxStorageGB, forKey: Key.maxStorageGB) }
    }
    // SMTP — user-entered in Settings, never hardcoded in source.
    @Published var smtpHost:     String { didSet { ud.set(smtpHost,     forKey: Key.smtpHost)     } }
    @Published var smtpPort:     Int    { didSet { ud.set(smtpPort,     forKey: Key.smtpPort)     } }
    @Published var smtpUsername: String { didSet { ud.set(smtpUsername, forKey: Key.smtpUsername) } }
    @Published var smtpPassword: String { didSet { ud.set(smtpPassword, forKey: Key.smtpPassword) } }

    init() {
        chunkDurationMinutes = ud.object(forKey: Key.chunkMinutes)  as? Int ?? 5
        emailEnabled         = ud.bool(forKey: Key.emailEnabled)
        recipientEmail       = ud.string(forKey: Key.recipient)              ?? ""
        emailCooldownMinutes = ud.object(forKey: Key.emailCooldown) as? Int ?? 10
        deviceName           = ud.string(forKey: Key.deviceName)             ?? UIDevice.current.name
        storageBackend       = StorageBackend(rawValue:
                                    ud.string(forKey: Key.storageBackend) ?? "") ?? .icloud
        maxStorageGB         = ud.object(forKey: Key.maxStorageGB) as? Int ?? 0
        smtpHost             = ud.string(forKey: Key.smtpHost)               ?? "smtp.gmail.com"
        smtpPort             = ud.object(forKey: Key.smtpPort)    as? Int    ?? 465
        smtpUsername         = ud.string(forKey: Key.smtpUsername)           ?? ""
        smtpPassword         = ud.string(forKey: Key.smtpPassword)           ?? ""
    }

    /// Chunk duration as a `TimeInterval` for use in timers.
    var chunkDuration: TimeInterval { Double(chunkDurationMinutes) * 60 }

    /// Maximum storage in bytes, or 0 if unlimited.
    var maxStorageBytes: Int64 {
        maxStorageGB == 0 ? 0 : Int64(maxStorageGB) * 1_073_741_824
    }

    /// Short human-readable label shown in the camera HUD.
    var chunkLabel: String { chunkDurationMinutes == 1 ? "1 min" : "\(chunkDurationMinutes) min" }

    /// True when all required email fields are filled in.
    var emailConfigured: Bool {
        emailEnabled
            && !recipientEmail.isEmpty
            && !smtpUsername.isEmpty
            && !smtpPassword.isEmpty
    }
}
