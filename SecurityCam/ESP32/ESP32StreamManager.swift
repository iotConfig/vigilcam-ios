import AVFoundation
import UIKit
import Foundation

// MARK: - MJPEG delegate

/// Handles URLSession data callbacks on a background queue, accumulates
/// bytes into a buffer, and emits complete JPEG frames via `onFrame`.
private final class MJPEGFeedDelegate: NSObject, URLSessionDataDelegate {

    /// Called on the URLSession private queue whenever a complete JPEG is found.
    var onFrame: ((Data) -> Void)?
    /// Called when the data task finishes (normally or with an error).
    var onDisconnected: ((Error?) -> Void)?

    private var buffer = Data(capacity: 200_000)

    // JPEG magic bytes
    private static let soi = Data([0xFF, 0xD8, 0xFF])   // Start of Image
    private static let eoi = Data([0xFF, 0xD9])          // End of Image

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        buffer.append(data)
        extractFrames()
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        onDisconnected?(error)
    }

    // Scan for SOI…EOI pairs and emit each as a complete JPEG.
    private func extractFrames() {
        while true {
            // Find the first SOI marker
            guard let soiRange = buffer.range(of: MJPEGFeedDelegate.soi) else {
                // No SOI yet — trim pre-SOI garbage, keeping 3 bytes in case
                // we're in the middle of receiving the SOI itself.
                if buffer.count > 4 { buffer = buffer.suffix(3) }
                return
            }

            // Discard bytes before SOI
            if soiRange.lowerBound > buffer.startIndex {
                buffer.removeSubrange(..<soiRange.lowerBound)
            }

            // Find EOI *after* the SOI
            let searchFrom = buffer.index(buffer.startIndex, offsetBy: 3)
            guard searchFrom < buffer.endIndex,
                  let eoiRange = buffer.range(of: MJPEGFeedDelegate.eoi,
                                              in: searchFrom..<buffer.endIndex)
            else {
                // Incomplete frame — keep accumulating; cap buffer to avoid OOM
                if buffer.count > 1_000_000 { buffer = Data() }
                return
            }

            let jpeg = buffer.subdata(in: buffer.startIndex..<eoiRange.upperBound)
            buffer.removeSubrange(buffer.startIndex..<eoiRange.upperBound)
            onFrame?(jpeg)
        }
    }
}

// MARK: - UIImage → CVPixelBuffer

private extension UIImage {
    /// Converts the image to a 32-BGRA pixel buffer suitable for AVAssetWriter.
    func pixelBuffer() -> CVPixelBuffer? {
        guard let cgImg = cgImage else { return nil }
        let w = cgImg.width, h = cgImg.height
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey         as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let pb else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        let ctx = CGContext(
            data:             CVPixelBufferGetBaseAddress(pb),
            width:            w, height: h,
            bitsPerComponent: 8,
            bytesPerRow:      CVPixelBufferGetBytesPerRow(pb),
            space:            CGColorSpaceCreateDeviceRGB(),
            bitmapInfo:       CGImageAlphaInfo.premultipliedFirst.rawValue
                            | CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.draw(cgImg, in: CGRect(x: 0, y: 0, width: w, height: h))
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }
}

// MARK: - ESP32StreamManager

/// Manages a live MJPEG stream from an ESP32-CAM and records it to local
/// storage using `AVAssetWriter`.
///
/// ## Thread safety
/// All mutable state (including `@Published` properties) is accessed exclusively
/// on the main actor.  The URLSession feed delegate runs on URLSession's private
/// background queue and dispatches frames back to the main actor via
/// `Task { @MainActor in … }`.
///
/// ## Clip rotation
/// Recording is automatically split into clips of `chunkDuration` seconds so
/// individual files stay a manageable size.  Clips are saved into the same
/// `Documents/VigilCam/<name>/<date>/` folder used by the built-in camera so
/// they appear in the "Review Videos" browser when "On-Device" storage is
/// selected.
@MainActor
final class ESP32StreamManager: ObservableObject {

    // MARK: - Published state

    @Published private(set) var previewImage:    UIImage?
    @Published private(set) var isConnected      = false
    @Published private(set) var isRecording      = false
    @Published private(set) var clipDuration:    TimeInterval = 0
    @Published private(set) var connectionError: String?

    // MARK: - Configuration

    /// Clip length in seconds.  Defaults to 5 minutes.
    var chunkDuration: TimeInterval = 300

    // MARK: - Internals

    private let storage    = LocalStorageProvider()
    private var camera:    ESP32Camera?
    private var reconnectTask: Task<Void, Never>?

    // Stream
    private var session:     URLSession?
    private var dataTask:    URLSessionDataTask?
    private var feedDelegate: MJPEGFeedDelegate?

    // Recording
    private var assetWriter: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var pixAdaptor:  AVAssetWriterInputPixelBufferAdaptor?
    private var clipURL:     URL?
    private var clipStart:   Date?
    private var durationTimer: Timer?
    private var rotationTimer: Timer?

    // MARK: - Connect / disconnect

    func connect(camera: ESP32Camera) {
        reconnectTask?.cancel(); reconnectTask = nil
        self.camera     = camera
        connectionError = nil
        isConnected     = false
        startStream(camera: camera)
    }

    func disconnect() {
        reconnectTask?.cancel(); reconnectTask = nil
        tearDownStream()
        isConnected = false
    }

    private func tearDownStream() {
        dataTask?.cancel()
        session?.invalidateAndCancel()
        dataTask     = nil
        session      = nil
        feedDelegate = nil
    }

    private func startStream(camera: ESP32Camera) {
        tearDownStream()
        guard let url = URL(string: camera.streamURL) else {
            connectionError = "Invalid URL: \(camera.streamURL)"
            return
        }

        let delegate = MJPEGFeedDelegate()
        delegate.onFrame = { [weak self] jpegData in
            Task { @MainActor [weak self] in self?.handleFrame(jpegData) }
        }
        delegate.onDisconnected = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isConnected    = false
                self.connectionError = error?.localizedDescription ?? "Stream ended"
                self.scheduleReconnect(camera: camera)
            }
        }

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 15
        cfg.timeoutIntervalForResource = .infinity
        let sess = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)

        var req        = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData

        feedDelegate = delegate
        session      = sess
        dataTask     = sess.dataTask(with: req)
        dataTask?.resume()
    }

    private func scheduleReconnect(camera: ESP32Camera) {
        reconnectTask?.cancel()
        reconnectTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)   // 3 s back-off
            guard !Task.isCancelled else { return }
            startStream(camera: camera)
        }
    }

    // MARK: - Recording controls

    func startRecording() {
        guard !isRecording, let camera else { return }
        isRecording  = true
        clipDuration = 0
        openClip(camera: camera)
        startTimers()
    }

    func stopRecording() async {
        guard isRecording else { return }
        isRecording = false
        stopTimers()
        clipDuration = 0
        await finaliseClip()
    }

    // MARK: - Clip lifecycle

    private func openClip(camera: ESP32Camera) {
        clipURL   = storage.nextRecordingURL(deviceName: camera.name)
        clipStart = Date()
        // AVAssetWriter is lazily created on the first frame so we know
        // the camera's actual pixel dimensions.
        assetWriter = nil
        writerInput = nil
        pixAdaptor  = nil
    }

    private func clearWriterState() {
        assetWriter = nil
        writerInput = nil
        pixAdaptor  = nil
        clipURL     = nil
        clipStart   = nil
    }

    private func finaliseClip() async {
        guard let url = clipURL,
              let w   = assetWriter,
              w.status == .writing else { clearWriterState(); return }

        // Nil out main-actor state *before* awaiting so that any handleFrame
        // calls during the suspension see nil and safely skip writing.
        let savedInput = writerInput
        clearWriterState()

        savedInput?.markAsFinished()
        await w.finishWriting()
        storage.commitSync(fileURL: url, hasMotion: false)
    }

    private func rotateClip() async {
        guard isRecording, let camera else { return }
        await finaliseClip()
        openClip(camera: camera)
    }

    // MARK: - Frame handling

    private func handleFrame(_ data: Data) {
        guard let image = UIImage(data: data) else { return }
        previewImage    = image
        isConnected     = true
        connectionError = nil

        guard isRecording else { return }

        // Lazily initialise the writer on the first frame.
        if assetWriter == nil, let url = clipURL {
            initWriter(url: url, size: image.size)
        }

        guard let w = assetWriter, w.status == .writing,
              let a = pixAdaptor,
              let i = writerInput, i.isReadyForMoreMediaData,
              let start = clipStart,
              let pb = image.pixelBuffer()
        else { return }

        let pts = CMTime(seconds: max(0, Date().timeIntervalSince(start)),
                         preferredTimescale: 600)
        a.append(pb, withPresentationTime: pts)
    }

    private func initWriter(url: URL, size: CGSize) {
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey:  AVVideoCodecType.h264,
            AVVideoWidthKey:  Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true

        let bufAttr: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey           as String: Int(size.width),
            kCVPixelBufferHeightKey          as String: Int(size.height),
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: bufAttr)

        w.add(input)
        guard w.startWriting() else { return }
        w.startSession(atSourceTime: .zero)
        assetWriter = w
        writerInput = input
        pixAdaptor  = adaptor
    }

    // MARK: - Timers

    private func startTimers() {
        let dur = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let s = self.clipStart else { return }
                self.clipDuration = Date().timeIntervalSince(s)
            }
        }
        RunLoop.main.add(dur, forMode: .common)
        durationTimer = dur

        let rot = Timer(timeInterval: chunkDuration, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.rotateClip() }
        }
        RunLoop.main.add(rot, forMode: .common)
        rotationTimer = rot
    }

    private func stopTimers() {
        durationTimer?.invalidate(); durationTimer = nil
        rotationTimer?.invalidate(); rotationTimer = nil
    }
}
