// LiveKitTokenGenerator.swift
//
// LiveKit was replaced by direct P2P TCP streaming (see LiveStreamServer.swift).
// This stub is kept to avoid modifying the Xcode project file.
import Foundation

enum LiveKitTokenGenerator {
    static func publisherToken(deviceName: String) -> String? { nil }
    static func viewerToken(roomName: String, viewerIdentity: String) -> String? { nil }
    static func listRoomsToken() -> String? { nil }
    static func roomName(for deviceName: String) -> String {
        deviceName
            .lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}
