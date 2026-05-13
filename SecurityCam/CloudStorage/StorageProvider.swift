import Foundation

// MARK: - Download status (iCloud-specific; always .local for other providers)

enum DownloadStatus {
    case local, downloading, cloud
}

// MARK: - RemoteClip — universal clip model shared by all storage backends

struct RemoteClip: Identifiable {
    let id          = UUID()
    /// Relative path used by every backend: "VigilCam/<device>/<date>/<time>.mov"
    let remotePath:  String
    let deviceName:  String  // "Living Room"
    let dateKey:     String  // "2026-03-28"
    let date:        Date
    let hasMotion:   Bool
    var downloadStatus: DownloadStatus  // always .local for non-iCloud

    /// Filename: "14-32-05.mov"
    var clipName: String { URL(fileURLWithPath: remotePath).lastPathComponent }

    /// Display-friendly time: "14:32:05"
    var displayTime: String {
        URL(fileURLWithPath: remotePath)
            .deletingPathExtension()
            .lastPathComponent
            .replacingOccurrences(of: "-", with: ":")
    }
}

// MARK: - StorageBackend

enum StorageBackend: String, CaseIterable, Identifiable {
    case local    = "On-Device"
    case icloud   = "iCloud Drive"
    case firebase = "Firebase (Google Cloud)"
    case wyze     = "Wyze Cameras"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .local:    return "internaldrive.fill"
        case .icloud:   return "icloud.fill"
        case .firebase: return "flame.fill"
        case .wyze:     return "camera.on.rectangle.fill"
        }
    }

    var description: String {
        switch self {
        case .local:
            return "Stored only on this device. No iCloud account required. Recordings are not visible from other devices and will be lost if the app is deleted."
        case .icloud:
            return "Stored in your iCloud Drive. Syncs automatically to all devices on the same Apple ID. Requires a paid Apple Developer account."
        case .firebase:
            return "Uploaded to Firebase Storage (Google Cloud). Each installation needs its own Firebase project. See setup instructions."
        case .wyze:
            return "Browse recordings saved by docker-wyze-bridge on your local network. Requires a bridge server with nginx file-serving enabled."
        }
    }
}

// MARK: - StorageProvider protocol

protocol StorageProvider: AnyObject {

    // MARK: Recording

    /// URL where AVFoundation should write the next clip.
    /// - iCloud: path inside the ubiquitous container (written directly, no upload step).
    /// - Firebase: a local temp path; the clip is uploaded in finaliseRecording.
    func nextRecordingURL(deviceName: String) -> URL

    /// Writes the .ready (and optional .motion) sidecar files **synchronously**,
    /// with no async work. Called directly from `didFinishRecordingTo` — before
    /// any Task is launched — so the sidecars exist on disk even if the app is
    /// suspended immediately afterwards. Default implementation: no-op.
    func commitSync(fileURL: URL, hasMotion: Bool)

    /// Called after AVFoundation finishes a clip. Awaitable so callers can
    /// sequence it with other async work (e.g. email extraction).
    /// - iCloud: writes the optional .motion sidecar. No upload needed.
    /// - Firebase: uploads .mov + .motion to Firebase Storage, then deletes the
    ///   local temp file.
    func finaliseRecording(fileURL: URL, hasMotion: Bool) async

    // MARK: Browsing

    /// Start observing available clips. `onUpdate` may be called on any thread.
    /// - iCloud: driven by NSMetadataQuery notifications.
    /// - Firebase: polls every 30 s and immediately on reload().
    func startBrowsing(onUpdate: @escaping ([RemoteClip]) -> Void)
    func stopBrowsing()
    func reload()

    // MARK: Playback

    /// Returns a URL suitable for AVPlayer.
    /// - iCloud: local file URL (triggers download first if cloud-only).
    /// - Firebase: a signed HTTPS download URL.
    func playbackURL(for clip: RemoteClip) async throws -> URL

    // MARK: Download hint

    /// Ask the OS to start downloading this clip eagerly.
    /// Default implementation is a no-op (Firebase, etc. don't need it).
    func triggerDownload(for clip: RemoteClip)

    // MARK: Delete

    func delete(clips: [RemoteClip]) async throws

    // MARK: Storage quota

    /// Deletes the oldest clips recorded by `deviceName` until total used space
    /// is at or below `maxBytes - 100 MB`. Pass 0 to skip enforcement.
    func enforceStorageQuota(deviceName: String, maxBytes: Int64) async
}

// MARK: - Default no-ops

extension StorageProvider {
    func commitSync(fileURL: URL, hasMotion: Bool) {}
    func triggerDownload(for clip: RemoteClip) {}
    func enforceStorageQuota(deviceName: String, maxBytes: Int64) async {}
}

// MARK: - Cross-instance refresh notification

extension Notification.Name {
    /// Posted by any StorageProvider instance when it writes a .ready sidecar,
    /// so other instances (e.g. the browser's own provider) can rescan immediately
    /// instead of waiting for their poll timer.
    static let vigilCamNewClip = Notification.Name("VigilCamNewClipReady")
}

// MARK: - Factory

enum StorageProviderFactory {
    static func make(backend: StorageBackend) -> StorageProvider {
        switch backend {
        case .local:    return LocalStorageProvider()
        case .icloud:   return iCloudStorageProvider()
        case .firebase: return FirebaseStorageProvider()
        case .wyze:
            let url = UserDefaults.standard.string(forKey: "wyzeRecordingsURL") ?? ""
            return WyzeBridgeProvider(recordingsURL: url)
        }
    }
}

// MARK: - Errors

enum StorageError: LocalizedError {
    case containerUnavailable
    case fileNotFound
    case notConfigured(String)
    case uploadFailed(Error)
    case downloadFailed(Error)

    var errorDescription: String? {
        switch self {
        case .containerUnavailable:   return "iCloud Drive is not available on this device."
        case .fileNotFound:           return "The clip file could not be found."
        case .notConfigured(let msg): return msg
        case .uploadFailed(let e):    return "Upload failed: \(e.localizedDescription)"
        case .downloadFailed(let e):  return "Download failed: \(e.localizedDescription)"
        }
    }
}
