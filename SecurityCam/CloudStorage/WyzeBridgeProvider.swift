import Foundation

/// Browses MP4 recordings served by docker-wyze-bridge's recording directory
/// via an nginx autoindex JSON endpoint.
///
/// ## Server-side setup
///
/// 1. Run docker-wyze-bridge with `RECORD_ALL=true` so it saves clips to disk.
///
/// 2. Serve that recording directory with nginx:
///    ```nginx
///    server {
///        listen 8088;
///        root /path/to/wyze-bridge/record;   # the RECORD_PATH volume
///        autoindex            on;
///        autoindex_format     json;
///        add_header Access-Control-Allow-Origin *;
///    }
///    ```
///
/// 3. In VigilCam Settings → Wyze Bridge, set Recordings URL to
///    `http://<server-ip>:8088` (no trailing slash).
///
/// ## Expected directory layout
///
/// ```
/// <recordingsURL>/
///   <camera_name>/           e.g. "front_door"  (ENV_CAM slug in the bridge)
///     <date>/                e.g. "2026-05-12"  or  "20260512"
///       <time>.mp4           e.g. "14-30-00.mp4"  or  "1747052400.mp4"
/// ```
///
/// Playback is done by handing AVPlayer a direct HTTP URL — no local
/// download step is required.
final class WyzeBridgeProvider: StorageProvider {

    private let recordingsURL: String   // e.g. "http://192.168.1.100:8088"
    private var onUpdate:  (([RemoteClip]) -> Void)?
    private var pollTimer: Timer?

    init(recordingsURL: String) {
        self.recordingsURL = recordingsURL
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: - Recording (no-op — Wyze provider is viewer-only)

    func nextRecordingURL(deviceName: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("wyze_noop.mov")
    }

    func finaliseRecording(fileURL: URL, hasMotion: Bool) async {}

    // MARK: - Browsing

    func startBrowsing(onUpdate: @escaping ([RemoteClip]) -> Void) {
        self.onUpdate = onUpdate
        Task { await scan() }

        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { await self?.scan() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    func stopBrowsing() {
        pollTimer?.invalidate()
        pollTimer = nil
        onUpdate = nil
    }

    func reload() {
        Task { await scan() }
    }

    // MARK: - Playback

    func playbackURL(for clip: RemoteClip) async throws -> URL {
        guard !recordingsURL.isEmpty,
              let url = URL(string: "\(recordingsURL)/\(clip.remotePath)") else {
            throw StorageError.notConfigured(
                "Wyze recordings URL is not configured. Open Settings → Wyze Bridge.")
        }
        return url
    }

    // MARK: - Delete (not supported — files live on the remote bridge server)

    func delete(clips: [RemoteClip]) async throws {}

    // MARK: - Directory scan

    private func scan() async {
        guard !recordingsURL.isEmpty,
              let rootURL = URL(string: recordingsURL) else {
            await MainActor.run { [weak self] in self?.onUpdate?([]) }
            return
        }

        var clips: [RemoteClip] = []

        // Level 1 — camera name directories
        let cameraEntries = (try? await fetchAutoindex(url: rootURL)) ?? []

        for cameraEntry in cameraEntries where cameraEntry.type == "directory" {
            let cameraSlug = cameraEntry.name
            guard let cameraURL = URL(string: "\(recordingsURL)/\(cameraSlug)") else { continue }

            // Level 2 — date directories
            let dateEntries = (try? await fetchAutoindex(url: cameraURL)) ?? []

            for dateEntry in dateEntries where dateEntry.type == "directory" {
                let dateKey = normaliseDate(dateEntry.name)
                guard !dateKey.isEmpty,
                      let dateURL = URL(string: "\(recordingsURL)/\(cameraSlug)/\(dateEntry.name)")
                else { continue }

                // Level 3 — video files
                let fileEntries = (try? await fetchAutoindex(url: dateURL)) ?? []

                for fileEntry in fileEntries where fileEntry.type == "file" {
                    let ext = (fileEntry.name as NSString).pathExtension.lowercased()
                    guard ext == "mp4" || ext == "mov" else { continue }

                    let stem = (fileEntry.name as NSString).deletingPathExtension
                    let date = parseDate(dateKey: dateKey, stem: stem, mtime: fileEntry.mtime)
                    let remotePath = "\(cameraSlug)/\(dateEntry.name)/\(fileEntry.name)"

                    clips.append(RemoteClip(
                        remotePath:     remotePath,
                        deviceName:     displayName(cameraSlug),
                        dateKey:        dateKey,
                        date:           date,
                        hasMotion:      false,
                        downloadStatus: .local
                    ))
                }
            }
        }

        let sorted = clips.sorted { $0.date > $1.date }
        await MainActor.run { [weak self] in self?.onUpdate?(sorted) }
    }

    // MARK: - nginx autoindex JSON

    private struct AutoindexEntry: Decodable {
        let name:  String
        let type:  String   // "file" | "directory"
        let mtime: String?
        let size:  Int64?
    }

    private func fetchAutoindex(url: URL) async throws -> [AutoindexEntry] {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "format", value: "json")]
        guard let jsonURL = comps.url else { return [] }

        var request = URLRequest(url: jsonURL, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return (try? JSONDecoder().decode([AutoindexEntry].self, from: data)) ?? []
    }

    // MARK: - Date helpers

    /// Normalises several bridge date-directory name formats to "yyyy-MM-dd".
    private func normaliseDate(_ name: String) -> String {
        // Already "2026-05-12"
        if name.count == 10,
           name.prefix(4).allSatisfy(\.isNumber),
           name.dropFirst(4).hasPrefix("-") { return name }

        // Compact "20260512"
        if name.count == 8, name.allSatisfy(\.isNumber) {
            return "\(name.prefix(4))-\(name.dropFirst(4).prefix(2))-\(name.dropFirst(6))"
        }
        return ""
    }

    /// Converts a camera slug like "front_door" → "Front Door".
    private func displayName(_ slug: String) -> String {
        slug.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    // DateFormatters are reused across calls to avoid repeated allocation.
    private let _dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale     = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private let _hmsFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH-mm-ss"
        f.locale     = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private let _mtimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        f.locale     = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func parseDate(dateKey: String, stem: String, mtime: String?) -> Date {
        let base = _dayFmt.date(from: dateKey) ?? Date.distantPast
        let cal  = Calendar.current

        // "HH-mm-ss" — matches the VigilCam filename convention
        if let t = _hmsFmt.date(from: stem) {
            return cal.date(bySettingHour: cal.component(.hour,   from: t),
                            minute:        cal.component(.minute, from: t),
                            second:        cal.component(.second, from: t),
                            of: base) ?? base
        }

        // Unix timestamp filename (e.g. docker-wyze-bridge segment naming)
        if let ts = TimeInterval(stem) {
            return Date(timeIntervalSince1970: ts)
        }

        // nginx mtime — last resort
        if let mtime, let d = _mtimeFmt.date(from: mtime) { return d }

        return base
    }
}
