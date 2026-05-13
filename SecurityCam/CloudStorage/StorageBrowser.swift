import Foundation

// MARK: - Presentation models (shared by all views regardless of backend)

struct DayFolder: Identifiable {
    let id          = UUID()
    let name:       String      // "2026-03-28"
    let deviceName: String      // "Living Room"
    var clips:      [RemoteClip]
    var isExpanded  = true
}

struct DeviceSummary: Identifiable {
    var id: String  { deviceName }
    let deviceName:  String
    let clipCount:   Int
    let dayCount:    Int
    let motionCount: Int
    let latestDate:  Date?
}

// MARK: - StorageBrowser

/// Observable wrapper around any `StorageProvider`.
/// Converts `[RemoteClip]` into the `DayFolder` / `DeviceSummary` tree
/// that drives every view in VideoBrowserView — regardless of which
/// storage backend is active.
@MainActor
final class StorageBrowser: ObservableObject {

    @Published var days:         [DayFolder] = []
    @Published var isLoading     = true
    /// Set by the provider when iCloud is not accessible / Firebase not configured.
    @Published var unavailable   = false

    let provider:     StorageProvider
    let backend:      StorageBackend
    let backendName:  String   // e.g. "iCloud Drive" — shown in the UI

    init(provider: StorageProvider, backend: StorageBackend) {
        self.provider    = provider
        self.backend     = backend
        self.backendName = backend.rawValue
        start()
    }

    deinit {
        provider.stopBrowsing()
    }

    // MARK: - Lifecycle

    private func start() {
        provider.startBrowsing { [weak self] clips in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.days      = Self.buildDays(from: clips)
                self.isLoading = false
            }
        }
    }

    func reload() {
        isLoading = true
        provider.reload()
    }

    // MARK: - Derived properties

    /// Short note shown at the bottom of the device list.
    var backendFooterNote: String {
        switch backend {
        case .local:
            return "**\(backendName)** — stored only on this device."
        case .icloud:
            return "**\(backendName)** — syncs to all devices on the same Apple ID."
        case .firebase:
            return "**\(backendName)** — syncs to all devices via Firebase."
        case .wyze:
            return "**\(backendName)** — recordings streamed from your Wyze Bridge server."
        }
    }

    var deviceNames: [String] {
        Array(Set(days.map(\.deviceName))).sorted()
    }

    var deviceSummaries: [DeviceSummary] {
        deviceNames.map { name in
            let dd    = days.filter { $0.deviceName == name }
            let clips = dd.flatMap(\.clips)
            return DeviceSummary(
                deviceName:  name,
                clipCount:   clips.count,
                dayCount:    dd.count,
                motionCount: clips.filter(\.hasMotion).count,
                latestDate:  clips.map(\.date).max()
            )
        }
    }

    // MARK: - Actions

    func delete(clips: [RemoteClip]) {
        Task { try? await provider.delete(clips: clips) }
    }

    func deleteDay(_ day: DayFolder) {
        delete(clips: day.clips)
    }

    func playbackURL(for clip: RemoteClip) async throws -> URL {
        try await provider.playbackURL(for: clip)
    }

    // MARK: - Build presentation model from flat clip list

    static func buildDays(from clips: [RemoteClip]) -> [DayFolder] {
        var map: [String: (device: String, date: String, clips: [RemoteClip])] = [:]

        for clip in clips {
            let key = "\(clip.deviceName)|\(clip.dateKey)"
            if map[key] == nil { map[key] = (clip.deviceName, clip.dateKey, []) }
            map[key]!.clips.append(clip)
        }

        return map
            .map { _, v in
                DayFolder(name:       v.date,
                          deviceName: v.device,
                          clips:      v.clips.sorted { $0.remotePath > $1.remotePath })
            }
            .sorted { ($0.deviceName, $0.name) < ($1.deviceName, $1.name) }
            .reversed()   // newest first
    }
}
