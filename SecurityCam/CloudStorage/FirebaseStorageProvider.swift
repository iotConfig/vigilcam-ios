import Foundation

// MARK: - FirebaseStorageProvider
//
// Setup (do this once before switching to Firebase in Settings):
//
//  1. Go to console.firebase.google.com → create a project → add an iOS app
//     with your bundle ID (com.securitycam.app)
//  2. Download GoogleService-Info.plist and drag it into the Xcode project
//  3. Add the Firebase SDK via Xcode → File → Add Package Dependencies:
//       https://github.com/firebase/firebase-ios-sdk.git
//     Select the "FirebaseStorage" product only.
//  4. In VigilCamApp.swift uncomment the FirebaseApp.configure() line
//  5. In Firebase console → Storage → Rules, set authenticated read/write
//     (or for private use: allow read, write: if true)
//
// Until those steps are done the stub below compiles and shows a
// "Not Configured" empty state in the browser.

#if canImport(FirebaseStorage)
import FirebaseStorage

final class FirebaseStorageProvider: StorageProvider {

    private let storage   = Storage.storage()
    private var onUpdate: (([RemoteClip]) -> Void)?
    private var pollTask:  Task<Void, Never>?

    // MARK: - Recording

    func nextRecordingURL(deviceName: String) -> URL {
        // Firebase uploads after recording finishes, so we record to a local
        // temp file first.
        let now    = Date()
        let dayFmt = DateFormatter(); dayFmt.dateFormat = "yyyy-MM-dd"
        let timFmt = DateFormatter(); timFmt.dateFormat = "HH-mm-ss"

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VigilCam/\(deviceName)/\(dayFmt.string(from: now))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(timFmt.string(from: now)).mov")
    }

    func finaliseRecording(fileURL: URL, hasMotion: Bool) async {
        let parts = fileURL.pathComponents
        guard let scIdx = parts.firstIndex(of: "VigilCam"),
              scIdx + 3 < parts.count else { return }

        let deviceName = parts[scIdx + 1]
        let dateKey    = parts[scIdx + 2]
        let timeFile   = fileURL.lastPathComponent
        let remotePath = "VigilCam/\(deviceName)/\(dateKey)/\(timeFile)"

        // Upload .mov
        let meta = StorageMetadata()
        meta.contentType = "video/quicktime"
        _ = try? await storage.reference().child(remotePath).putFileAsync(from: fileURL, metadata: meta)

        // Upload empty .motion marker
        if hasMotion {
            let motionPath = remotePath.replacingOccurrences(of: ".mov", with: ".motion")
            _ = try? await storage.reference().child(motionPath).putDataAsync(Data(), metadata: nil)
        }

        // Delete local temp file — it's now in Firebase
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Browsing

    func startBrowsing(onUpdate: @escaping ([RemoteClip]) -> Void) {
        self.onUpdate = onUpdate
        schedulePoll()
    }

    func stopBrowsing() {
        pollTask?.cancel()
        pollTask = nil
        onUpdate = nil
    }

    func reload() {
        pollTask?.cancel()
        schedulePoll()
    }

    private func schedulePoll() {
        pollTask = Task {
            while !Task.isCancelled {
                await fetchAndNotify()
                try? await Task.sleep(nanoseconds: 30_000_000_000)  // 30 s
            }
        }
    }

    private func fetchAndNotify() async {
        let clips = await listAll(ref: storage.reference().child("VigilCam"),
                                  prefix: "VigilCam")
        onUpdate?(clips)
    }

    /// Recursively list all .mov files under a given StorageReference.
    private func listAll(ref: StorageReference, prefix: String) async -> [RemoteClip] {
        guard let result = try? await ref.listAll() else { return [] }

        let dayFmt  = DateFormatter(); dayFmt.dateFormat  = "yyyy-MM-dd"
        let timeFmt = DateFormatter(); timeFmt.dateFormat = "HH-mm-ss"

        // Collect .motion paths at this prefix for O(1) lookup
        let motionPaths = Set(result.items
            .filter { $0.name.hasSuffix(".motion") }
            .map    { "\(prefix)/\($0.name)" })

        var clips: [RemoteClip] = []

        for item in result.items where item.name.hasSuffix(".mov") {
            let remotePath = "\(prefix)/\(item.name)"
            let pathParts  = remotePath.components(separatedBy: "/")
            // "VigilCam/<device>/<date>/<time>.mov"
            guard pathParts.count >= 4 else { continue }
            let deviceName = pathParts[pathParts.count - 3]
            let dateKey    = pathParts[pathParts.count - 2]
            let timeStr    = item.name.replacingOccurrences(of: ".mov", with: "")

            guard let base = dayFmt.date(from: dateKey) else { continue }
            let cal = Calendar.current
            let date: Date = {
                guard let t = timeFmt.date(from: timeStr) else { return base }
                return cal.date(bySettingHour:   cal.component(.hour,   from: t),
                                minute:          cal.component(.minute, from: t),
                                second:          cal.component(.second, from: t),
                                of: base) ?? base
            }()

            let motionPath = remotePath.replacingOccurrences(of: ".mov", with: ".motion")
            clips.append(RemoteClip(remotePath:     remotePath,
                                    deviceName:     deviceName,
                                    dateKey:        dateKey,
                                    date:           date,
                                    hasMotion:      motionPaths.contains(motionPath),
                                    downloadStatus: .local))   // Firebase: stream on demand
        }

        // Recurse into sub-prefixes (device folders, date folders)
        for sub in result.prefixes {
            let subClips = await listAll(ref: sub, prefix: "\(prefix)/\(sub.name)")
            clips.append(contentsOf: subClips)
        }

        return clips
    }

    // MARK: - Playback

    func playbackURL(for clip: RemoteClip) async throws -> URL {
        // Firebase returns a signed HTTPS URL — AVPlayer can stream from it directly.
        return try await storage.reference().child(clip.remotePath).downloadURL()
    }

    // MARK: - Delete

    func delete(clips: [RemoteClip]) async throws {
        for clip in clips {
            try? await storage.reference().child(clip.remotePath).delete()
            let motionPath = clip.remotePath.replacingOccurrences(of: ".mov", with: ".motion")
            try? await storage.reference().child(motionPath).delete()
        }
    }
}

#else

// MARK: - Stub (compiles when firebase-ios-sdk is not yet added to the project)

final class FirebaseStorageProvider: StorageProvider {

    func nextRecordingURL(deviceName: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("VigilCam-Unconfigured")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(Int(Date().timeIntervalSince1970)).mov")
    }

    func finaliseRecording(fileURL: URL, hasMotion: Bool) async {
        try? FileManager.default.removeItem(at: fileURL)   // discard — Firebase not configured
    }

    func startBrowsing(onUpdate: @escaping ([RemoteClip]) -> Void) {
        onUpdate([])   // nothing to show
    }

    func stopBrowsing() {}
    func reload()        {}

    func playbackURL(for clip: RemoteClip) async throws -> URL {
        throw StorageError.notConfigured(
            "Firebase SDK is not added to this project yet.\n\n" +
            "See the setup instructions inside FirebaseStorageProvider.swift.")
    }

    func delete(clips: [RemoteClip]) async throws {}
}

#endif
