import Foundation

/// Stores recordings in the app's local Documents directory.
/// Nothing is uploaded — recordings stay on this device only.
/// Browsing is driven by a periodic filesystem scan that runs every 30 s
/// while the video library is open, plus an immediate scan on start/reload.
///
/// File layout mirrors the iCloud provider so both share the same clip paths:
///   Documents/VigilCam/<deviceName>/<yyyy-MM-dd>/<HH-mm-ss>.mov
///
/// Completion protocol:
///   After AVFoundation finishes a clip, finaliseRecording writes a zero-byte
///   "<clip>.ready" sidecar. The browser only shows clips whose .ready sidecar
///   is present — this prevents the currently-recording file from appearing.
final class LocalStorageProvider: StorageProvider {

    private var onUpdate:        (([RemoteClip]) -> Void)?
    private var pollTimer:       Timer?
    /// Retained token for the cross-instance new-clip notification.
    private var newClipObserver: NSObjectProtocol?

    // MARK: - Convenience

    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    // MARK: - Recording

    /// Writes the .ready (and optional .motion) sidecar files synchronously.
    /// Called directly from `didFinishRecordingTo` before any async Task so the
    /// clip is visible in the browser even when the app is suspended immediately
    /// after the recording delegate fires.
    func commitSync(fileURL: URL, hasMotion: Bool) {
        let readyURL = fileURL.deletingPathExtension().appendingPathExtension("ready")
        try? Data().write(to: readyURL)
        if hasMotion {
            let motionURL = fileURL.deletingPathExtension().appendingPathExtension("motion")
            try? Data().write(to: motionURL)
        }
        // Tell the browser's provider instance to rescan now.
        // Both this (CameraManager's) provider and the browser's provider are
        // separate instances; the browser's onUpdate won't fire unless it hears
        // about the new file via this cross-instance notification.
        NotificationCenter.default.post(name: .vigilCamNewClip, object: nil)
    }

    func nextRecordingURL(deviceName: String) -> URL {
        let now    = Date()
        let dayFmt = DateFormatter(); dayFmt.dateFormat = "yyyy-MM-dd"
        let timFmt = DateFormatter(); timFmt.dateFormat = "HH-mm-ss"

        let dir = documentsURL
            .appendingPathComponent("VigilCam")
            .appendingPathComponent(deviceName)
            .appendingPathComponent(dayFmt.string(from: now))

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(timFmt.string(from: now)).mov")
    }

    func finaliseRecording(fileURL: URL, hasMotion: Bool) async {
        // .ready and .motion are already written by commitSync (synchronously,
        // before this Task was even launched).  Write them again defensively in
        // case this path is ever called without a prior commitSync.
        let readyURL = fileURL.deletingPathExtension().appendingPathExtension("ready")
        try? Data().write(to: readyURL)

        if hasMotion {
            let motionURL = fileURL.deletingPathExtension().appendingPathExtension("motion")
            try? Data().write(to: motionURL)
        }
        // commitSync already posted .vigilCamNewClip; no second post needed here.
    }

    // MARK: - Browsing

    func startBrowsing(onUpdate: @escaping ([RemoteClip]) -> Void) {
        self.onUpdate = onUpdate
        scan()

        // Listen for the cross-instance notification posted by commitSync on the
        // camera-manager's provider so we rescan immediately when a clip lands,
        // rather than waiting for the next 30-second poll.
        newClipObserver = NotificationCenter.default.addObserver(
            forName:  .vigilCamNewClip,
            object:   nil,
            queue:    .main) { [weak self] _ in self?.scan() }

        // Also schedule a repeating scan on the main run loop so the timer fires
        // even while a scroll view is tracking.
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.scan() }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    func stopBrowsing() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let obs = newClipObserver {
            NotificationCenter.default.removeObserver(obs)
            newClipObserver = nil
        }
        onUpdate = nil
    }

    func reload() {
        scan()
    }

    // MARK: - Filesystem scan

    private func scan() {
        let root = documentsURL.appendingPathComponent("VigilCam")

        let dayFmt  = DateFormatter(); dayFmt.dateFormat  = "yyyy-MM-dd"
        let timeFmt = DateFormatter(); timeFmt.dateFormat = "HH-mm-ss"

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            onUpdate?([])
            return
        }

        // First pass: collect .ready base paths and .mov URLs.
        var readyBasePaths = Set<String>()
        var movURLs: [URL] = []

        for case let url as URL in enumerator.allObjects {
            switch url.pathExtension.lowercased() {
            case "ready": readyBasePaths.insert(url.deletingPathExtension().path)
            case "mov":   movURLs.append(url)
            default:      break
            }
        }

        // Second pass: build RemoteClip only for completed recordings.
        var clips: [RemoteClip] = []

        for url in movURLs {
            let basePath = url.deletingPathExtension().path
            guard readyBasePaths.contains(basePath) else { continue }

            let parts = url.pathComponents
            guard let scIdx = parts.firstIndex(of: "VigilCam"),
                  scIdx + 3 < parts.count else { continue }

            let deviceName = parts[scIdx + 1]
            let dateKey    = parts[scIdx + 2]
            let timeStr    = url.deletingPathExtension().lastPathComponent

            guard let base = dayFmt.date(from: dateKey) else { continue }

            let cal = Calendar.current
            let date: Date = {
                guard let t = timeFmt.date(from: timeStr) else { return base }
                return cal.date(bySettingHour:   cal.component(.hour,   from: t),
                                minute:          cal.component(.minute, from: t),
                                second:          cal.component(.second, from: t),
                                of: base) ?? base
            }()

            let motionURL = url.deletingPathExtension().appendingPathExtension("motion")
            let hasMotion = FileManager.default.fileExists(atPath: motionURL.path)

            let remotePath = "VigilCam/\(deviceName)/\(dateKey)/\(url.lastPathComponent)"
            clips.append(RemoteClip(remotePath:     remotePath,
                                    deviceName:     deviceName,
                                    dateKey:        dateKey,
                                    date:           date,
                                    hasMotion:      hasMotion,
                                    downloadStatus: .local))
        }

        onUpdate?(clips)
    }

    // MARK: - Playback

    func playbackURL(for clip: RemoteClip) async throws -> URL {
        let url = documentsURL.appendingPathComponent(clip.remotePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StorageError.fileNotFound
        }
        return url
    }

    // MARK: - Storage quota enforcement

    func enforceStorageQuota(deviceName: String, maxBytes: Int64) async {
        guard maxBytes > 0 else { return }

        let deviceDir = documentsURL
            .appendingPathComponent("VigilCam")
            .appendingPathComponent(deviceName)

        guard let enumerator = FileManager.default.enumerator(
            at: deviceDir,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        struct FileInfo {
            let url:     URL
            let size:    Int64
            let created: Date
        }

        var files:     [FileInfo] = []
        var totalSize: Int64      = 0

        for case let url as URL in enumerator.allObjects {
            guard url.pathExtension.lowercased() == "mov" else { continue }
            let res     = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
            let size    = Int64(res?.fileSize ?? 0)
            let created = res?.creationDate ?? Date.distantPast
            files.append(FileInfo(url: url, size: size, created: created))
            totalSize += size
        }

        guard totalSize > maxBytes else { return }

        let headroom: Int64 = 100 * 1_048_576  // 100 MB breathing room
        let target          = maxBytes - headroom

        files.sort { $0.created < $1.created }  // oldest first

        for file in files {
            guard totalSize > target else { break }
            let base = file.url.deletingPathExtension()
            try? FileManager.default.removeItem(at: file.url)
            try? FileManager.default.removeItem(at: base.appendingPathExtension("ready"))
            try? FileManager.default.removeItem(at: base.appendingPathExtension("motion"))
            totalSize -= file.size
            dlog("StorageQuota: removed \(file.url.lastPathComponent) (\(file.size / 1_048_576) MB)")
        }
    }

    // MARK: - Delete

    func delete(clips: [RemoteClip]) async throws {
        for clip in clips {
            let url    = documentsURL.appendingPathComponent(clip.remotePath)
            let motion = url.deletingPathExtension().appendingPathExtension("motion")
            let ready  = url.deletingPathExtension().appendingPathExtension("ready")
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: motion)
            try? FileManager.default.removeItem(at: ready)
        }
    }
}
