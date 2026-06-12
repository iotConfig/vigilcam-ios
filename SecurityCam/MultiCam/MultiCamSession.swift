import Foundation
import Combine

// MARK: - Camera slot

/// Pairs an ESP32Camera model with its live streaming + recording manager.
struct IPCameraSlot: Identifiable {
    let id:      UUID              // = camera.id
    var camera:  ESP32Camera
    let manager: ESP32StreamManager
}

// MARK: - Session

/// Owns one `CameraManager` (phone) and N `ESP32StreamManager` instances (IP
/// cameras).  Forwarding `objectWillChange` from every child to itself means
/// any `@ObservedObject` or `@StateObject` that references this session will
/// re-render whenever any child publishes a change — including recording state,
/// preview frames, and connection errors.
@MainActor
final class MultiCamSession: ObservableObject {

    // MARK: - Children

    let phoneCam: CameraManager
    @Published private(set) var ipCams: [IPCameraSlot] = []

    // MARK: - Derived (recalculated on every re-render triggered by child changes)

    var isAnyRecording: Bool {
        phoneCam.isRecording || ipCams.contains { $0.manager.isRecording }
    }

    // MARK: - Internals

    private let settings: SettingsModel
    /// Per-child Combine subscriptions that forward objectWillChange upward.
    private var fwdCancellables: [UUID: AnyCancellable] = [:]
    /// Session-level cancellable (phone cam + misc).
    private var phoneCamCancellable: AnyCancellable?

    // MARK: - Init

    init(settings: SettingsModel) {
        self.settings = settings

        // ── Phone camera ────────────────────────────────────────────────────
        phoneCam = CameraManager()
        phoneCam.settings        = settings
        // Don't use the Wyze backend for local recording.
        let recordBackend: StorageBackend = settings.storageBackend == .wyze
            ? .local : settings.storageBackend
        phoneCam.storageProvider = StorageProviderFactory.make(backend: recordBackend)

        // ── IP cameras ──────────────────────────────────────────────────────
        for camera in settings.esp32Cameras {
            let slot = makeSlot(camera: camera)
            ipCams.append(slot)
        }

        // ── Forward child changes to self ───────────────────────────────────
        phoneCamCancellable = phoneCam.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }

        for slot in ipCams {
            subscribeManager(slot)
        }
    }

    // MARK: - Lifecycle

    /// Call once the view has appeared — starts the phone camera session
    /// and connects all IP camera streams.
    func activate() {
        phoneCam.setup()
        for slot in ipCams {
            slot.manager.connect(camera: slot.camera)
        }
    }

    /// Stops all recordings and disconnects all IP streams.
    func deactivate() async {
        await stopAll()
        for slot in ipCams {
            slot.manager.disconnect()
        }
    }

    // MARK: - Record all / stop all

    func startAll() {
        phoneCam.startRecording()
        for slot in ipCams {
            slot.manager.startRecording()
        }
    }

    func stopAll() async {
        phoneCam.commitCurrentClip()
        phoneCam.stopRecording()
        await withTaskGroup(of: Void.self) { group in
            for slot in ipCams {
                group.addTask { await slot.manager.stopRecording() }
            }
        }
    }

    // MARK: - Camera list sync (called from view's onChange)

    func syncCameras(cameras: [ESP32Camera]) {
        // Remove deleted cameras
        for i in ipCams.indices.reversed() {
            if !cameras.contains(where: { $0.id == ipCams[i].id }) {
                ipCams[i].manager.disconnect()
                fwdCancellables.removeValue(forKey: ipCams[i].id)
                ipCams.remove(at: i)
            }
        }
        // Add new cameras
        for camera in cameras {
            if !ipCams.contains(where: { $0.id == camera.id }) {
                let slot = makeSlot(camera: camera)
                slot.manager.connect(camera: camera)
                subscribeManager(slot)
                ipCams.append(slot)
            }
        }
        // Update modified cameras (name or URL changed)
        for i in ipCams.indices {
            if let updated = cameras.first(where: { $0.id == ipCams[i].id }),
               updated != ipCams[i].camera {
                ipCams[i] = IPCameraSlot(id: updated.id,
                                          camera:  updated,
                                          manager: ipCams[i].manager)
                ipCams[i].manager.connect(camera: updated)   // reconnect with new URL
            }
        }
    }

    // MARK: - Helpers

    private func makeSlot(camera: ESP32Camera) -> IPCameraSlot {
        let mgr = ESP32StreamManager()
        mgr.chunkDuration = settings.chunkDuration
        return IPCameraSlot(id: camera.id, camera: camera, manager: mgr)
    }

    private func subscribeManager(_ slot: IPCameraSlot) {
        fwdCancellables[slot.id] = slot.manager.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
    }
}
