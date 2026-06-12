import SwiftUI

// MARK: - Camera list

struct ESP32CameraListView: View {
    @ObservedObject var settings: SettingsModel
    @Environment(\.dismiss) private var dismiss

    @State private var showAddSheet = false
    @State private var editCamera:  ESP32Camera?

    var body: some View {
        NavigationStack {
            Group {
                if settings.esp32Cameras.isEmpty {
                    emptyState
                } else {
                    cameraList
                }
            }
            .navigationTitle("IP Cameras")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showAddSheet = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                ESP32EditCameraSheet(camera: nil) { newCamera in
                    settings.esp32Cameras.append(newCamera)
                }
            }
            .sheet(item: $editCamera) { cam in
                ESP32EditCameraSheet(camera: cam) { updated in
                    if let idx = settings.esp32Cameras.firstIndex(where: { $0.id == updated.id }) {
                        settings.esp32Cameras[idx] = updated
                    }
                }
            }
        }
    }

    // MARK: - Camera list

    private var cameraList: some View {
        List {
            ForEach(settings.esp32Cameras) { camera in
                NavigationLink {
                    ESP32RecorderView(camera: camera, settings: settings)
                } label: {
                    CameraRow(camera: camera)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        settings.esp32Cameras.removeAll { $0.id == camera.id }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        editCamera = camera
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.orange)
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.on.rectangle")
                .font(.system(size: 52))
                .foregroundColor(.secondary)
            Text("No IP Cameras")
                .font(.title2.weight(.semibold))
            Text("Add an ESP32-CAM or any camera\nthat streams MJPEG over HTTP.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button { showAddSheet = true } label: {
                Label("Add Camera", systemImage: "plus.circle")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Camera row

private struct CameraRow: View {
    let camera: ESP32Camera

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.green.opacity(0.15))
                    .frame(width: 48, height: 48)
                Image(systemName: "camera.on.rectangle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.green)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(camera.name)
                    .font(.headline)
                Text(camera.hostLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Add / edit sheet

struct ESP32EditCameraSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let isNew: Bool
    @State private var name:      String
    @State private var streamURL: String
    let onSave: (ESP32Camera) -> Void

    private let existingID: UUID

    init(camera: ESP32Camera?, onSave: @escaping (ESP32Camera) -> Void) {
        isNew         = camera == nil
        existingID    = camera?.id ?? UUID()
        _name         = State(initialValue: camera?.name      ?? "")
        _streamURL    = State(initialValue: camera?.streamURL ?? "http://")
        self.onSave   = onSave
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
        && URL(string: streamURL)?.scheme?.hasPrefix("http") == true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Name") {
                        TextField("e.g. Garage", text: $name)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                    }
                    LabeledContent("Stream URL") {
                        TextField("http://192.168.1.50/stream", text: $streamURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .multilineTextAlignment(.trailing)
                    }
                } footer: {
                    Text("On most ESP32-CAM Arduino sketches the MJPEG stream is at http://<ip>/stream. Other common paths: /mjpeg, /video, /cam.mjpeg.")
                }
            }
            .navigationTitle(isNew ? "Add Camera" : "Edit Camera")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(ESP32Camera(id: existingID, name: name.trimmingCharacters(in: .whitespaces), streamURL: streamURL))
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }
}
