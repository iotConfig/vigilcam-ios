import SwiftUI
import AVKit

// MARK: - Root: device picker

struct VideoBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser: StorageBrowser

    init(settings: SettingsModel) {
        let provider = StorageProviderFactory.make(backend: settings.storageBackend)
        _browser = StateObject(wrappedValue:
            StorageBrowser(provider: provider, backend: settings.storageBackend))
    }

    /// Use this initialiser when you need to force a specific provider regardless
    /// of the user's storage-backend setting — e.g. browsing ESP32 local recordings.
    init(provider: StorageProvider, backend: StorageBackend) {
        _browser = StateObject(wrappedValue:
            StorageBrowser(provider: provider, backend: backend))
    }

    var body: some View {
        NavigationStack {
            Group {
                if browser.isLoading {
                    ProgressView("Scanning \(browser.backendName)…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if browser.deviceSummaries.isEmpty {
                    emptyState
                } else {
                    deviceList
                }
            }
            .navigationTitle("Recordings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: String.self) { deviceName in
                DeviceRecordingsView(browser: browser, deviceName: deviceName)
            }
        }
    }

    // MARK: - Device list

    private var deviceList: some View {
        List {
            ForEach(browser.deviceSummaries) { summary in
                NavigationLink(value: summary.deviceName) {
                    DeviceRow(summary: summary)
                }
            }
            Section {
                HStack(spacing: 10) {
                    Image(systemName: browser.backend.systemImage)
                        .foregroundColor(.accentColor)
                    Text(LocalizedStringKey(browser.backendFooterNote))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { browser.reload() }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No Recordings Found")
                .font(.title2.weight(.semibold))
            Text("Recordings appear here once a device running VigilCam saves them to \(browser.backendName).")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button { browser.reload() } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Device list row

private struct DeviceRow: View {
    let summary: DeviceSummary

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 48, height: 48)
                Image(systemName: "camera.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.accentColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(summary.deviceName)
                    .font(.headline)
                    .foregroundColor(.primary)

                HStack(spacing: 6) {
                    Label("\(summary.clipCount) clip\(summary.clipCount == 1 ? "" : "s")",
                          systemImage: "video.fill")
                    Text("·")
                    Text("\(summary.dayCount) day\(summary.dayCount == 1 ? "" : "s")")
                    if summary.motionCount > 0 {
                        Text("·")
                        Label("\(summary.motionCount)", systemImage: "figure.walk.motion")
                            .foregroundColor(.orange)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)

                if let date = summary.latestDate {
                    (Text("Last: ") + Text(date, style: .relative))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Per-device recordings

struct DeviceRecordingsView: View {
    @ObservedObject var browser: StorageBrowser
    let deviceName: String

    @State private var showMotionOnly    = false
    @State private var playerItem:       RemoteClip?
    @State private var confirmDeleteDay: DayFolder?

    var body: some View {
        Group {
            if browser.isLoading {
                ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleDays.isEmpty {
                emptyState
            } else {
                clipList
            }
        }
        .navigationTitle(deviceName)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                HStack(spacing: 4) {
                    Image(systemName: browser.backend.systemImage)
                        .font(.caption).foregroundColor(.accentColor)
                    Text(clipCountLabel)
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    withAnimation { showMotionOnly.toggle() }
                } label: {
                    Image(systemName: "figure.walk.motion")
                        .symbolVariant(showMotionOnly ? .fill : .none)
                        .foregroundColor(showMotionOnly ? .orange : .primary)
                }
            }
        }
        .confirmationDialog(
            "Delete all clips for \(confirmDeleteDay?.name ?? "")?",
            isPresented: Binding(get: { confirmDeleteDay != nil },
                                 set: { if !$0 { confirmDeleteDay = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                if let day = confirmDeleteDay { browser.deleteDay(day); confirmDeleteDay = nil }
            }
            Button("Cancel", role: .cancel) { confirmDeleteDay = nil }
        }
        .sheet(item: $playerItem) { clip in
            CloudVideoPlayerSheet(clip: clip, browser: browser)
        }
    }

    private var clipList: some View {
        List {
            ForEach($browser.days) { $day in
                if day.deviceName == deviceName {
                    let clipsToShow = showMotionOnly ? day.clips.filter(\.hasMotion) : day.clips
                    if !clipsToShow.isEmpty {
                        Section {
                            if day.isExpanded {
                                ForEach(clipsToShow) { clip in
                                    ClipRow(clip: clip) { playerItem = clip }
                                }
                                .onDelete { offsets in
                                    browser.delete(clips: offsets.map { clipsToShow[$0] })
                                }
                            }
                        } header: {
                            DayHeader(day:         day,
                                      isExpanded:  $day.isExpanded,
                                      clipCount:   clipsToShow.count,
                                      motionCount: day.clips.filter(\.hasMotion).count)
                            { confirmDeleteDay = day }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { browser.reload() }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: showMotionOnly ? "figure.walk.motion" : "video.slash")
                .font(.system(size: 48)).foregroundColor(.secondary)
            Text(showMotionOnly ? "No Motion Clips" : "No Recordings")
                .font(.title2.weight(.semibold))
            Text(showMotionOnly
                 ? "No clips with detected motion."
                 : browser.backend == .local
                     ? "\(deviceName) hasn't saved any recordings yet."
                     : "\(deviceName) hasn't saved any recordings yet, or they're still syncing.")
                .font(.subheadline).foregroundColor(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var deviceDays: [DayFolder] { browser.days.filter { $0.deviceName == deviceName } }
    private var visibleDays: [DayFolder] {
        showMotionOnly ? deviceDays.filter { $0.clips.contains(where: \.hasMotion) } : deviceDays
    }
    private var clipCountLabel: String {
        let n = deviceDays.flatMap(\.clips).count
        return "\(n) clip\(n == 1 ? "" : "s")"
    }
}

// MARK: - Day section header

private struct DayHeader: View {
    let day: DayFolder
    @Binding var isExpanded: Bool
    let clipCount:   Int
    let motionCount: Int
    let onDeleteAll: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold)).frame(width: 14)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            Text(day.name).font(.subheadline.weight(.semibold)).foregroundColor(.primary)
            Text("(\(clipCount))").font(.caption).foregroundColor(.secondary)

            if motionCount > 0 {
                Label("\(motionCount)", systemImage: "figure.walk.motion")
                    .font(.caption.weight(.medium)).foregroundColor(.orange)
            }
            Spacer()
            Button(role: .destructive, action: onDeleteAll) {
                Image(systemName: "trash").font(.caption)
            }
            .buttonStyle(.plain).foregroundColor(.red)
        }
        .textCase(nil)
    }
}

// MARK: - Clip row

private struct ClipRow: View {
    let clip:   RemoteClip
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "video.fill")
                        .font(.title3).foregroundColor(.accentColor)
                        .frame(width: 36, height: 36)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    if clip.hasMotion {
                        Image(systemName: "figure.walk.motion")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white).padding(2)
                            .background(Color.orange).clipShape(Circle())
                            .offset(x: 5, y: -5)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(clip.displayTime).font(.body).foregroundColor(.primary)
                    HStack(spacing: 6) {
                        downloadBadge
                        if clip.hasMotion { Text("· Motion").foregroundColor(.orange) }
                    }
                    .font(.caption)
                }

                Spacer()
                Image(systemName: "play.circle.fill")
                    .font(.title2).foregroundColor(.accentColor.opacity(0.7))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var downloadBadge: some View {
        switch clip.downloadStatus {
        case .cloud:
            Label("iCloud", systemImage: "icloud").foregroundColor(.accentColor)
        case .downloading:
            Label("Downloading…", systemImage: "icloud.and.arrow.down").foregroundColor(.accentColor)
        case .local:
            EmptyView()
        }
    }
}

// MARK: - Cloud-agnostic video player sheet

private struct CloudVideoPlayerSheet: View {
    let clip:    RemoteClip
    let browser: StorageBrowser

    @Environment(\.dismiss) private var dismiss
    @State private var player:    AVPlayer?
    @State private var localURL:  URL?
    @State private var phase:     Phase = .loading
    @State private var error:     String?

    enum Phase { case loading, ready, failed }

    // MARK: - Orientation helpers

    /// Returns true if the video's display dimensions are wider than they are tall.
    /// Combines naturalSize + preferredTransform so it works for both old-style
    /// (sensor-landscape pixels + 90° transform) and modern-style (natively-oriented
    /// pixels + identity transform) recordings.
    private func isLandscape(url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let track       = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await track.load(.naturalSize),
              let transform   = try? await track.load(.preferredTransform)
        else { return false }   // safe default: don't force a rotation if unsure

        // If |b| > |a| the transform includes a 90°/270° rotation, which swaps axes.
        let axesSwapped  = abs(transform.b) > abs(transform.a)
        let displayWidth  = axesSwapped ? naturalSize.height : naturalSize.width
        let displayHeight = axesSwapped ? naturalSize.width  : naturalSize.height
        return displayWidth > displayHeight
    }

    private func rotateInterface(landscape: Bool) {
        if #available(iOS 16, *) {
            guard let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
            else { return }
            let mask: UIInterfaceOrientationMask = landscape ? .landscape : .portrait
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
            scene.keyWindow?.rootViewController?
                .setNeedsUpdateOfSupportedInterfaceOrientations()
        } else {
            let value = landscape
                ? UIInterfaceOrientation.landscapeRight.rawValue
                : UIInterfaceOrientation.portrait.rawValue
            UIDevice.current.setValue(value, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    VStack(spacing: 16) {
                        ProgressView()
                        Text(clip.downloadStatus == .cloud
                             ? "Downloading from cloud…"
                             : "Preparing video…")
                            .font(.subheadline).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .ready:
                    if let player {
                        AVPlayerView(player: player).ignoresSafeArea()
                    }

                case .failed:
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.icloud.fill")
                            .font(.system(size: 48)).foregroundColor(.orange)
                        Text("Playback Failed").font(.title3.weight(.semibold))
                        if let error {
                            Text(error).font(.subheadline).foregroundColor(.secondary)
                                .multilineTextAlignment(.center).padding(.horizontal)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(clip.displayTime)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if phase == .ready, let url = localURL {
                    ToolbarItem(placement: .navigationBarLeading) {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear    { prepare() }
        .onDisappear { rotateInterface(landscape: false) }
    }

    private func prepare() {
        browser.provider.triggerDownload(for: clip)
        Task {
            do {
                let url = try await browser.playbackURL(for: clip)

                // For iCloud cloud-only files, wait until the file is local.
                if clip.downloadStatus != .local {
                    try await waitForLocal(url: url)
                }

                let landscape = await isLandscape(url: url)
                await MainActor.run {
                    localURL = url
                    player   = AVPlayer(url: url)
                    player?.play()
                    phase    = .ready
                    rotateInterface(landscape: landscape)
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.phase = .failed
                }
            }
        }
    }

    /// Polls URLResourceValues until the file is fully downloaded (iCloud only).
    private func waitForLocal(url: URL) async throws {
        for _ in 0..<600 {   // up to 5 minutes
            try await Task.sleep(nanoseconds: 500_000_000)
            if let vals = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
               vals.ubiquitousItemDownloadingStatus == .current { return }
        }
        throw StorageError.downloadFailed(
            NSError(domain: "SecurityCam", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Download timed out."]))
    }
}

// MARK: - AVPlayerViewController wrapper
// Preferred over SwiftUI's VideoPlayer: handles aspect ratio, safe-area insets,
// and rotation correctly across both portrait and landscape recordings.

private struct AVPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = true
        vc.videoGravity = .resizeAspect
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: ()) {
        vc.player?.pause()
    }
}
