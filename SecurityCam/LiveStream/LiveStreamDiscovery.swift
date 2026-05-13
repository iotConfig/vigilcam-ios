import Foundation
import Darwin   // getifaddrs, inet_ntop

// MARK: - StreamSignaling
//
// Uses iCloud Key-Value Store for device discovery and stream requests.
// No third-party cloud — all signaling stays within the user's iCloud account.
// Both phones must be signed into the same iCloud account.
//
// KV Store keys:
//   "sc_alive_{slug}"  = Double (unix timestamp) — recording device writes every 30 s
//   "sc_req_{slug}"    = "{viewerIP}:{port}:{timestamp}" — viewer writes to request stream

final class StreamSignaling {

    static let shared = StreamSignaling()
    private let kv = NSUbiquitousKeyValueStore.default

    private let alivePrefix = "sc_alive_"
    private let reqPrefix   = "sc_req_"

    // MARK: - Slug

    static func slug(for deviceName: String) -> String {
        deviceName
            .lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    // MARK: - Recording device side

    func announceAlive(deviceName: String) {
        kv.set(Date().timeIntervalSince1970,
               forKey: alivePrefix + StreamSignaling.slug(for: deviceName))
        kv.synchronize()
    }

    func clearAlive(deviceName: String) {
        kv.removeObject(forKey: alivePrefix + StreamSignaling.slug(for: deviceName))
        kv.synchronize()
    }

    /// Returns (ip, port) if a recent stream request exists for this device.
    func pendingRequest(for deviceName: String) -> (ip: String, port: UInt16)? {
        let key = reqPrefix + StreamSignaling.slug(for: deviceName)
        guard let value = kv.string(forKey: key) else { return nil }
        let parts = value.components(separatedBy: ":")
        guard parts.count == 3,
              let port = UInt16(parts[1]),
              let ts   = Double(parts[2]),
              Date().timeIntervalSince1970 - ts < 60  // expires after 60 s
        else { return nil }
        return (ip: parts[0], port: port)
    }

    // MARK: - Viewer side

    struct AliveDevice: Identifiable {
        var id: String { slug }
        let deviceName: String
        let slug: String
    }

    func aliveDevices() -> [AliveDevice] {
        let cutoff = Date().timeIntervalSince1970 - 300   // 5 minutes
        return kv.dictionaryRepresentation
            .compactMap { key, value -> AliveDevice? in
                guard key.hasPrefix(alivePrefix),
                      let ts = value as? Double, ts > cutoff
                else { return nil }
                let slug        = String(key.dropFirst(alivePrefix.count))
                let displayName = slug.replacingOccurrences(of: "-", with: " ").capitalized
                return AliveDevice(deviceName: displayName, slug: slug)
            }
            .sorted { $0.deviceName < $1.deviceName }
    }

    func requestStream(targetSlug: String, viewerIP: String, viewerPort: UInt16) {
        let value = "\(viewerIP):\(viewerPort):\(Date().timeIntervalSince1970)"
        kv.set(value, forKey: reqPrefix + targetSlug)
        kv.synchronize()
    }

    func cancelRequest(targetSlug: String) {
        kv.removeObject(forKey: reqPrefix + targetSlug)
        kv.synchronize()
    }

    // MARK: - Network utility

    /// Returns the device's current local IP — prefers Wi-Fi (en0), falls back to cellular.
    static func localIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var wifiIP: String?
        var cellIP: String?
        var ptr = ifaddr

        while let current = ptr {
            let iface = current.pointee
            if iface.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: iface.ifa_name)
                var sin  = iface.ifa_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var buf  = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
                let ip = String(cString: buf)
                if name == "en0"     { wifiIP = ip }
                if name == "pdp_ip0" { cellIP = ip }
            }
            ptr = iface.ifa_next
        }
        return wifiIP ?? cellIP
    }
}
