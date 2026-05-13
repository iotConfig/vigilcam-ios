import Foundation

/// Stores recordings directly in the app's iCloud Drive container.
/// Files sync automatically to every device on the same Apple ID via iCloud.
/// Requires the iCloud Documents capability (paid Apple Developer account).
///
/// Completion protocol:
///   After AVFoundation finishes a clip, finaliseRecording writes a zero-byte
///   "<clip>.ready" sidecar alongside the .mov. The browser only shows clips
///   whose .ready sidecar has already synced to iCloud — this prevents the
///   currently-recording file (and any partially-uploaded file from another
///   device) from appearing in the list.
final class iCloudStorageProvider: NSObject, StorageProvider {

    private var query:    NSMetadataQuery?
    private var onUpdate: (([RemoteClip]) -> Void)?

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
    }

    func nextRecordingURL(deviceName: String) -> URL {
        let now    = Date()
        let dayFmt = DateFormatter(); dayFmt.dateFormat = "yyyy-MM-dd"
        let timFmt = DateFormatter(); timFmt.dateFormat = "HH-mm-ss"

        let dir: URL
        if let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
            dir = container
                .appendingPathComponent("Documents/VigilCam")
                .appendingPathComponent(deviceName)
                .appendingPathComponent(dayFmt.string(from: now))
        } else {
            dir = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("VigilCam")
                .appendingPathComponent(dayFmt.string(from: now))
        }

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(timFmt.string(from: now)).mov")
    }

    func finaliseRecording(fileURL: URL, hasMotion: Bool) async {
        // Write .ready sidecar — signals to every device that this clip is
        // fully written and safe to download/play. Without it the clip is
        // hidden in the browser even if it already appears in iCloud.
        let readyURL = fileURL.deletingPathExtension().appendingPathExtension("ready")
        try? Data().write(to: readyURL)

        if hasMotion {
            let motionURL = fileURL.deletingPathExtension().appendingPathExtension("motion")
            try? Data().write(to: motionURL)
        }
    }

    // MARK: - Browsing

    func startBrowsing(onUpdate: @escaping ([RemoteClip]) -> Void) {
        self.onUpdate = onUpdate

        guard FileManager.default.url(forUbiquityContainerIdentifier: nil) != nil else {
            onUpdate([])
            return
        }

        let q = NSMetadataQuery()
        q.searchScopes    = [NSMetadataQueryUbiquitousDocumentsScope]
        // Match both .mov and .ready so processQuery can cross-reference them.
        q.predicate       = NSPredicate(format: "(%K LIKE[cd] '*.mov' OR %K LIKE[cd] '*.ready')",
                                        NSMetadataItemFSNameKey, NSMetadataItemFSNameKey)
        q.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSCreationDateKey,
                                              ascending: false)]

        NotificationCenter.default.addObserver(
            self, selector: #selector(queryFinished),
            name: .NSMetadataQueryDidFinishGathering, object: q)
        NotificationCenter.default.addObserver(
            self, selector: #selector(queryUpdated),
            name: .NSMetadataQueryDidUpdate, object: q)

        q.start()
        self.query = q
    }

    func stopBrowsing() {
        query?.stop()
        query = nil
        NotificationCenter.default.removeObserver(self)
        onUpdate = nil
    }

    func reload() {
        let saved = onUpdate
        stopBrowsing()
        if let saved { startBrowsing(onUpdate: saved) }
    }

    @objc private func queryFinished() { processQuery() }
    @objc private func queryUpdated()  { processQuery() }

    private func processQuery() {
        guard let q = query else { return }
        q.disableUpdates()
        defer { q.enableUpdates() }

        let dayFmt  = DateFormatter(); dayFmt.dateFormat  = "yyyy-MM-dd"
        let timeFmt = DateFormatter(); timeFmt.dateFormat = "HH-mm-ss"

        // First pass: collect all .ready base paths (without extension).
        // A .ready sidecar present in the query means it has synced to iCloud
        // on the recording device — i.e., the clip is complete.
        var readyBasePaths = Set<String>()
        var movItems: [(item: NSMetadataItem, path: String)] = []

        for i in 0..<q.resultCount {
            guard let item = q.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else { continue }

            let url = URL(fileURLWithPath: path)
            switch url.pathExtension.lowercased() {
            case "ready": readyBasePaths.insert(url.deletingPathExtension().path)
            case "mov":   movItems.append((item, path))
            default:      break
            }
        }

        // Second pass: build RemoteClip only for .mov files that are:
        //   1. Accompanied by a .ready sidecar (recording is complete)
        //   2. Fully uploaded to iCloud (not partially written/uploading)
        // This excludes the currently-recording file, files still being
        // uploaded from any device, and partially-written files.
        var clips: [RemoteClip] = []

        for (item, path) in movItems {
            let url      = URL(fileURLWithPath: path)
            let basePath = url.deletingPathExtension().path

            // Must have a .ready sidecar
            guard readyBasePaths.contains(basePath) else { continue }

            // Show the clip if it is either:
            //   • Fully uploaded to iCloud (playable from any device), OR
            //   • Already present locally on this device (recorded here, upload
            //     still in progress — we can play it immediately from disk).
            // We must NOT skip locally-present files just because they haven't
            // finished uploading; that would hide every freshly-recorded clip
            // until iCloud finishes the transfer.
            let isUploaded = (item.value(forAttribute:
                NSMetadataUbiquitousItemIsUploadedKey) as? Bool) ?? true
            let dlStatus = item.value(forAttribute:
                NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            let isLocallyAvailable =
                dlStatus == NSMetadataUbiquitousItemDownloadingStatusCurrent
            guard isUploaded || isLocallyAvailable else { continue }

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

            // .motion sidecar: check local presence (small file, eagerly downloaded)
            let motionURL = url.deletingPathExtension().appendingPathExtension("motion")
            let hasMotion = FileManager.default.fileExists(atPath: motionURL.path)

            let dlActive = (item.value(forAttribute:
                NSMetadataUbiquitousItemIsDownloadingKey) as? Bool) ?? false
            let status: DownloadStatus
            if dlActive                                                               { status = .downloading }
            else if dlStatus == NSMetadataUbiquitousItemDownloadingStatusCurrent     { status = .local }
            else                                                                     { status = .cloud }

            let remotePath = "VigilCam/\(deviceName)/\(dateKey)/\(url.lastPathComponent)"
            clips.append(RemoteClip(remotePath:     remotePath,
                                    deviceName:     deviceName,
                                    dateKey:        dateKey,
                                    date:           date,
                                    hasMotion:      hasMotion,
                                    downloadStatus: status))
        }

        onUpdate?(clips)
    }

    // MARK: - Playback

    func playbackURL(for clip: RemoteClip) async throws -> URL {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            throw StorageError.containerUnavailable
        }
        return container
            .appendingPathComponent("Documents")
            .appendingPathComponent(clip.remotePath)
    }

    func triggerDownload(for clip: RemoteClip) {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return }
        let url = container.appendingPathComponent("Documents/\(clip.remotePath)")
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    // MARK: - Storage quota enforcement

    func enforceStorageQuota(deviceName: String, maxBytes: Int64) async {
        guard maxBytes > 0 else { return }
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return }

        let deviceDir = container
            .appendingPathComponent("Documents/VigilCam")
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

        // Drain the enumerator with allObjects (synchronous, no iterator) to
        // avoid the Swift 6 "makeIterator unavailable from async contexts" error.
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
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            throw StorageError.containerUnavailable
        }
        let base = container.appendingPathComponent("Documents")
        for clip in clips {
            let url    = base.appendingPathComponent(clip.remotePath)
            let motion = url.deletingPathExtension().appendingPathExtension("motion")
            let ready  = url.deletingPathExtension().appendingPathExtension("ready")
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: motion)
            try? FileManager.default.removeItem(at: ready)
        }
    }
}
