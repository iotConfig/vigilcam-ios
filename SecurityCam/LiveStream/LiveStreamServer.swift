import Foundation
import AVFoundation
import Network
import UIKit
import ImageIO

/// Connects out to a viewer's TCP server and streams compressed JPEG frames at ~15 fps.
/// The viewer acts as TCP server (opens a listening port and writes IP:port to iCloud KV);
/// this sender is the TCP client that connects to that port.
final class P2PStreamSender {

    /// Set by CameraManager before connect() so handleStreamRequest can detect viewer changes.
    var viewerAddress: String = ""

    // Written and read across queues — nonisolated(unsafe) + simple Bool gives safe enough semantics.
    nonisolated(unsafe) private(set) var isConnected = false

    nonisolated(unsafe) private var connection: NWConnection?
    nonisolated(unsafe) private var isSending   = false
    nonisolated(unsafe) private var lastSentAt: TimeInterval = 0

    private let minInterval: TimeInterval = 1.0 / 15   // cap at 15 fps
    private let sendQueue = DispatchQueue(label: "p2p.sender", qos: .userInitiated)

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Lifecycle

    func connect(to ip: String, port: UInt16) {
        connection?.cancel()
        isConnected = false

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            dlog("P2PStreamSender: invalid port \(port)"); return
        }
        let conn = NWConnection(
            to: .hostPort(host: NWEndpoint.Host(ip), port: nwPort),
            using: .tcp)
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.isConnected = true
                dlog("P2PStreamSender: connected → \(ip):\(port)")
            case .failed(let err):
                dlog("P2PStreamSender: connection failed — \(err)")
                self?.isConnected = false
                self?.connection  = nil
            case .cancelled:
                self?.isConnected = false
                self?.connection  = nil
            default:
                break
            }
        }
        conn.start(queue: sendQueue)
    }

    func disconnect() {
        connection?.cancel()
        connection  = nil
        isConnected = false
    }

    // MARK: - Frame push  (hot path — called from camera's motionQueue)

    func pushBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isConnected, let conn = connection, !isSending else { return }

        let now = Date().timeIntervalSince1970
        guard now - lastSentAt >= minInterval else { return }

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Scale to 640 × 360 and encode as JPEG (quality ~35 %).
        // autoreleasepool ensures CIImage / CGImage and the pixel-buffer reference
        // they retain are released immediately after each frame rather than
        // accumulating in the thread's autorelease pool — prevents OOM over time.
        guard let jpeg: Data = autoreleasepool(invoking: {
            let ci     = CIImage(cvPixelBuffer: imageBuffer)
            let scaled = ci.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
            guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }
            let buf = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(
                buf, "public.jpeg" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(
                dest, cgImage,
                [kCGImageDestinationLossyCompressionQuality: 0.35] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return nil }
            return buf as Data
        }) else { return }
        isSending  = true
        lastSentAt = now

        var len = UInt32(jpeg.count).bigEndian
        var payload = Data(bytes: &len, count: 4)
        payload.append(jpeg)

        conn.send(content: payload, completion: .contentProcessed { [weak self] _ in
            self?.isSending = false
        })
    }
}
