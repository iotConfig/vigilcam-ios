import Foundation

/// A single ESP32-based WiFi camera defined by the user.
///
/// Stored as a JSON array in UserDefaults via `SettingsModel.esp32Cameras`.
/// The stream URL should point to the camera's MJPEG endpoint — on most
/// standard ESP32-CAM Arduino sketches that is `http://<ip>/stream`.
struct ESP32Camera: Identifiable, Codable, Equatable {
    var id:        UUID   = UUID()
    var name:      String          // "Garage"
    var streamURL: String          // "http://192.168.1.50/stream"

    /// Human-readable host shown in the camera list.
    var hostLabel: String {
        URL(string: streamURL)?.host ?? streamURL
    }
}
