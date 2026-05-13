import SwiftUI
import Network
import UIKit

// MARK: - Root view

struct LiveStreamView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = AliveDevicesBrowser()
    @State private var selectedDevice: StreamSignaling.AliveDevice?

    var body: some View {
        NavigationStack {
            Group {
                if !browser.hasLoaded {
                    ProgressView("Looking for devices…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if browser.devices.isEmpty {
                    emptyState
                } else {
                    deviceList
                }
            }
            .navigationTitle("Live Streams")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear    { browser.start() }
        .onDisappear { browser.stop()  }
        .sheet(item: $selectedDevice) { device in
            LivePlayerView(device: device)
        }
    }

    private var deviceList: some View {
        List(browser.devices) { device in
            Button { selectedDevice = device } label: {
                LiveDeviceRow(device: device)
            }
            .buttonStyle(.plain)
        }
        .listStyle(.insetGrouped)
        .refreshable { browser.refresh() }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle().fill(Color.red.opacity(0.1)).frame(width: 80, height: 80)
                Image(systemName: "video.slash")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundColor(.red.opacity(0.7))
            }
            Text("No Live Streams").font(.title2.weight(.semibold))
            Text("Devices running VigilCam in Camera mode will appear here automatically.\nMake sure both phones are signed into the same iCloud account.")
                .font(.subheadline).foregroundColor(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            Button { browser.refresh() } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Browser ViewModel

@MainActor
final class AliveDevicesBrowser: ObservableObject {
    @Published var devices:   [StreamSignaling.AliveDevice] = []
    @Published var hasLoaded = false

    private var timer:    Timer?
    private var observer: NSObjectProtocol?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor [weak self] in self?.refresh() } }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let obs = observer { NotificationCenter.default.removeObserver(obs) }
        observer = nil
    }

    func refresh() {
        devices   = StreamSignaling.shared.aliveDevices()
        hasLoaded = true
    }
}

// MARK: - Device row

private struct LiveDeviceRow: View {
    let device: StreamSignaling.AliveDevice

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.red.opacity(0.12)).frame(width: 48, height: 48)
                Image(systemName: "record.circle.fill")
                    .font(.title3.weight(.semibold)).foregroundColor(.red)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(device.deviceName).font(.headline)
                HStack(spacing: 5) {
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                    Text("LIVE").font(.caption.weight(.bold)).foregroundColor(.red)
                }
            }
            Spacer()
            Image(systemName: "play.circle.fill")
                .font(.title2).foregroundColor(.accentColor.opacity(0.7))
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Player sheet

private struct LivePlayerView: View {
    let device: StreamSignaling.AliveDevice
    @Environment(\.dismiss) private var dismiss
    @StateObject private var client = P2PStreamClient()

    enum Phase { case requesting, connecting, watching, failed }
    @State private var phase:        Phase  = .requesting
    @State private var errorMsg:     String?
    @State private var requestTimer: Timer?   // re-writes KV request every 10 s until connected

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .requesting:
                    statusView(label: "Requesting stream from \(device.deviceName)…")
                case .connecting:
                    statusView(label: "Waiting for \(device.deviceName) to connect…")
                case .watching:
                    FrameDisplayView(client: client).ignoresSafeArea(edges: .bottom)
                case .failed:
                    failureView
                }
            }
            .navigationTitle(device.deviceName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear    { startStream() }
        .onDisappear { tearDown() }
        .onChange(of: client.isConnected) { connected in
            if connected {
                stopRequestTimer()
                phase = .watching
            }
        }
    }

    private func statusView(label: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(label).font(.subheadline).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var failureView: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash").font(.system(size: 48)).foregroundColor(.orange)
            Text("Stream Unavailable").font(.title3.weight(.semibold))
            if let msg = errorMsg {
                Text(msg).font(.subheadline).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal)
            }
            Button("Try Again") { startStream() }.buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Stream setup

    private func startStream() {
        stopRequestTimer()
        phase    = .requesting
        errorMsg = nil
        client.stop()

        guard let ip = StreamSignaling.localIPAddress() else {
            phase    = .failed
            errorMsg = "Could not determine local IP address. Make sure Wi-Fi is enabled."
            return
        }

        do {
            try client.startListening()
        } catch {
            phase    = .failed
            errorMsg = "Could not open local socket: \(error.localizedDescription)"
            return
        }

        // The NWListener assigns a port asynchronously once it reaches .ready.
        // Poll main thread until the port is known (up to ~2 s).
        waitForPort(ip: ip, attemptsLeft: 20)
    }

    private func waitForPort(ip: String, attemptsLeft: Int) {
        guard attemptsLeft > 0 else {
            phase    = .failed
            errorMsg = "Timed out opening local socket."
            return
        }
        if client.listeningPort > 0 {
            writeRequest(ip: ip, port: client.listeningPort)
            phase = .connecting
            // Re-write the request every 10 s to keep the 60 s expiry fresh
            // and catch camera devices that sync the KV key a little late.
            let port = client.listeningPort
            requestTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
                writeRequest(ip: ip, port: port)
            }
            // Timeout after 60 s.
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                guard phase == .connecting else { return }
                stopRequestTimer()
                phase    = .failed
                errorMsg = "The camera did not connect. Make sure both devices are on the same Wi-Fi network and signed into the same iCloud account."
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                waitForPort(ip: ip, attemptsLeft: attemptsLeft - 1)
            }
        }
    }

    private func writeRequest(ip: String, port: UInt16) {
        StreamSignaling.shared.requestStream(targetSlug: device.slug,
                                             viewerIP:   ip,
                                             viewerPort: port)
    }

    private func stopRequestTimer() {
        requestTimer?.invalidate()
        requestTimer = nil
    }

    private func tearDown() {
        stopRequestTimer()
        StreamSignaling.shared.cancelRequest(targetSlug: device.slug)
        client.stop()
    }
}

// MARK: - Frame display  (UIImageView wrapper avoids per-frame SwiftUI layout)

private struct FrameDisplayView: UIViewRepresentable {
    @ObservedObject var client: P2PStreamClient

    func makeUIView(context: Context) -> UIImageView {
        let iv = UIImageView()
        iv.contentMode    = .scaleAspectFit
        iv.backgroundColor = .black
        return iv
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        if let frame = client.latestFrame {
            uiView.image = frame
        }
    }
}

// MARK: - TCP frame receiver  (viewer side)

@MainActor
final class P2PStreamClient: ObservableObject {
    @Published var latestFrame: UIImage?
    @Published var isConnected = false

    private var listener:    NWListener?
    private var connection:  NWConnection?
    private let receiveQueue = DispatchQueue(label: "p2p.receive", qos: .userInitiated)

    private(set) var listeningPort: UInt16 = 0

    // MARK: - Lifecycle

    /// Opens a TCP listener on a random OS-assigned port.
    func startListening() throws {
        stop()
        let l = try NWListener(using: .tcp)
        listener = l

        l.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in self?.accept(conn) }
        }
        l.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                Task { @MainActor in
                    self?.listeningPort = self?.listener?.port?.rawValue ?? 0
                    dlog("P2PStreamClient: listening on port \(self?.listeningPort ?? 0)")
                }
            }
        }
        l.start(queue: .global(qos: .utility))
    }

    func stop() {
        connection?.cancel(); connection   = nil
        listener?.cancel();   listener     = nil
        listeningPort = 0
        isConnected   = false
        latestFrame   = nil
    }

    // MARK: - Connection handling

    private func accept(_ conn: NWConnection) {
        connection?.cancel()
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.isConnected = true
                    dlog("P2PStreamClient: recording device connected")
                case .failed(let err):
                    dlog("P2PStreamClient: connection error — \(err)")
                    self?.isConnected = false
                case .cancelled:
                    self?.isConnected = false
                default:
                    break
                }
            }
        }
        conn.start(queue: receiveQueue)
        readLength(on: conn)
    }

    // MARK: - Frame reading  (length-prefixed: 4-byte big-endian uint32 + JPEG body)

    nonisolated private func readLength(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard error == nil, let data, data.count == 4 else { return }
            let length = data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            self?.readBody(length: Int(length), on: conn)
        }
    }

    nonisolated private func readBody(length: Int, on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard error == nil, let data, data.count >= length else { return }
            let jpeg = data.prefix(length)
            if let image = UIImage(data: jpeg) {
                Task { @MainActor [weak self] in self?.latestFrame = image }
            }
            self?.readLength(on: conn)   // loop — read next frame
        }
    }
}
