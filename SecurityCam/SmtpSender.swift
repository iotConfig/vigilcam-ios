import Foundation

/// Minimal SMTP client.
/// Supports port 465 (direct TLS / SMTPS) and port 587 (STARTTLS).
/// Runs entirely on a background thread — never blocks the main thread.
final class SmtpSender {

    struct Config {
        let host:     String
        let port:     Int       // 465 = SSL, 587 = STARTTLS
        let username: String    // also used as the From address
        let password: String    // use an App Password for Gmail / iCloud
    }

    enum SmtpError: LocalizedError {
        case cannotConnect
        case unexpectedResponse(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .cannotConnect:              return "Could not connect to SMTP server"
            case .unexpectedResponse(let r): return "Unexpected response: \(r.prefix(80))"
            case .timeout:                   return "SMTP connection timed out"
            }
        }
    }

    /// Maximum video file size that will be attached (bytes).
    /// Files larger than this are still reported but without the video.
    private let maxAttachmentBytes = 20 * 1024 * 1024   // 20 MB

    // MARK: - Public

    func sendMotionAlert(config: Config,
                         to recipient: String,
                         at date: Date,
                         videoURL: URL? = nil,
                         completion: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            do {
                try self.smtp(config: config, to: recipient, date: date, videoURL: videoURL)
                DispatchQueue.main.async { completion(nil) }
            } catch {
                dlog("📧 SMTP error: \(error.localizedDescription)")
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    // MARK: - Synchronous SMTP conversation

    private func smtp(config: Config, to recipient: String,
                      date: Date, videoURL: URL?) throws {

        // 1. Create TCP stream pair
        var readRef:  Unmanaged<CFReadStream>?
        var writeRef: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocketToHost(
            kCFAllocatorDefault,
            config.host as CFString,
            UInt32(config.port),
            &readRef,
            &writeRef
        )
        guard let cfRead  = readRef?.takeRetainedValue(),
              let cfWrite = writeRef?.takeRetainedValue() else { throw SmtpError.cannotConnect }

        let input  = cfRead  as InputStream
        let output = cfWrite as OutputStream

        // Port 465 → enable TLS before opening
        if config.port == 465 { applySsl(cfRead, cfWrite, host: config.host) }

        input.open()
        output.open()
        defer { input.close(); output.close() }

        try waitOpen(input: input, output: output)

        // 2. Helpers
        func send(_ cmd: String) throws {
            var data = Data((cmd + "\r\n").utf8)
            while !data.isEmpty {
                let n = data.withUnsafeBytes {
                    output.write($0.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                 maxLength: data.count)
                }
                guard n > 0 else { throw SmtpError.cannotConnect }
                data = data.dropFirst(n)
            }
        }

        func recv() throws -> String {
            var buf    = [UInt8](repeating: 0, count: 8192)
            var result = ""
            let deadline = Date().addingTimeInterval(15)
            repeat {
                if input.hasBytesAvailable {
                    let n = input.read(&buf, maxLength: buf.count)
                    if n > 0 { result += String(bytes: buf[0..<n], encoding: .utf8) ?? "" }
                } else {
                    Thread.sleep(forTimeInterval: 0.05)
                }
            } while !isComplete(result) && Date() < deadline
            guard !result.isEmpty else { throw SmtpError.timeout }
            return result
        }

        func expect(_ code: String) throws -> String {
            let r = try recv()
            guard r.hasPrefix(code) else { throw SmtpError.unexpectedResponse(r) }
            return r
        }

        let domain = config.username.components(separatedBy: "@").last ?? "localhost"

        // 3. Greeting + EHLO
        _ = try expect("220")
        try send("EHLO \(domain)")
        _ = try recv()

        // 4. STARTTLS for port 587
        if config.port == 587 {
            try send("STARTTLS")
            _ = try expect("220")
            applySsl(cfRead, cfWrite, host: config.host)
            Thread.sleep(forTimeInterval: 1.0)
            try send("EHLO \(domain)")
            _ = try recv()
        }

        // 5. AUTH LOGIN
        try send("AUTH LOGIN")
        _ = try expect("334")
        try send(Data(config.username.utf8).base64EncodedString())
        _ = try expect("334")
        try send(Data(config.password.utf8).base64EncodedString())
        _ = try expect("235")

        // 6. Envelope
        try send("MAIL FROM:<\(config.username)>")
        _ = try expect("250")
        try send("RCPT TO:<\(recipient)>")
        _ = try expect("250")

        // 7. Message
        try send("DATA")
        _ = try expect("354")

        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .medium
        let ts = df.string(from: date)

        try send(buildMessage(from: config.username,
                              to: recipient,
                              timestamp: ts,
                              videoURL: videoURL))
        _ = try expect("250")

        try send("QUIT")
        _ = try recv()
    }

    // MARK: - MIME message builder

    private func buildMessage(from sender: String,
                              to recipient: String,
                              timestamp: String,
                              videoURL: URL?) -> String {

        let subject = "VigilCam: Motion detected – \(timestamp)"

        // ── Load video data if within the size limit ─────────────────────────
        var videoData: Data?
        var videoFileName = ""
        var videoTooLarge = false

        if let url = videoURL {
            videoFileName = url.lastPathComponent
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
            if fileSize <= maxAttachmentBytes {
                videoData = try? Data(contentsOf: url)
            } else {
                videoTooLarge = true
            }
        }

        // ── Plain-text body ──────────────────────────────────────────────────
        var bodyLines: [String] = [
            "VigilCam motion alert — \(timestamp)",
            ""
        ]
        if videoData != nil {
            bodyLines.append("The motion clip is attached.")
        } else if videoTooLarge {
            bodyLines += [
                "The video clip exceeded 20 MB and could not be attached.",
                "You can find it in the VigilCam folder on your device."
            ]
        } else {
            bodyLines.append("The recording is saved in the VigilCam folder on your device.")
        }

        // ── Plain text only (no attachment) ──────────────────────────────────
        guard let vd = videoData else {
            let lines: [String] = [
                "From: VigilCam <\(sender)>",
                "To: \(recipient)",
                "Subject: \(subject)",
                "MIME-Version: 1.0",
                "Content-Type: text/plain; charset=utf-8",
                ""
            ] + bodyLines + ["."]
            return lines.joined(separator: "\r\n")
        }

        // ── Multipart/mixed with video attachment ─────────────────────────────
        let boundary = "VigilCam\(Int(Date().timeIntervalSince1970))"

        let lines: [String] = [
            "From: VigilCam <\(sender)>",
            "To: \(recipient)",
            "Subject: \(subject)",
            "MIME-Version: 1.0",
            "Content-Type: multipart/mixed; boundary=\"\(boundary)\"",
            "",
            "--\(boundary)",
            "Content-Type: text/plain; charset=utf-8",
            ""
        ] + bodyLines + [
            "",
            "--\(boundary)",
            "Content-Type: video/mp4; name=\"\(videoFileName)\"",
            "Content-Transfer-Encoding: base64",
            "Content-Disposition: attachment; filename=\"\(videoFileName)\"",
            "",
            mimeBase64(vd),
            "",
            "--\(boundary)--",
            "."
        ]
        return lines.joined(separator: "\r\n")
    }

    // MARK: - Helpers

    /// Encode data as base64 with MIME-standard 76-character line wrapping.
    private func mimeBase64(_ data: Data) -> String {
        let raw = data.base64EncodedString()
        var lines = [String]()
        var index = raw.startIndex
        while index < raw.endIndex {
            let end = raw.index(index, offsetBy: 76, limitedBy: raw.endIndex) ?? raw.endIndex
            lines.append(String(raw[index..<end]))
            index = end
        }
        return lines.joined(separator: "\r\n")
    }

    private func applySsl(_ read: CFReadStream, _ write: CFWriteStream, host: String) {
        let settings: [CFString: Any] = [
            kCFStreamSSLValidatesCertificateChain: kCFBooleanTrue as Any,
            kCFStreamSSLPeerName: host as Any
        ]
        let sslKey = CFStreamPropertyKey(kCFStreamPropertySSLSettings)
        CFReadStreamSetProperty(read,  sslKey, settings as CFDictionary)
        CFWriteStreamSetProperty(write, sslKey, settings as CFDictionary)
    }

    private func waitOpen(input: InputStream, output: OutputStream,
                          timeout: TimeInterval = 10) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch (input.streamStatus, output.streamStatus) {
            case (.open, .open):   return
            case (.error, _), (_, .error): throw SmtpError.cannotConnect
            default: Thread.sleep(forTimeInterval: 0.05)
            }
        }
        throw SmtpError.timeout
    }

    private func isComplete(_ text: String) -> Bool {
        guard text.hasSuffix("\r\n") else { return false }
        let lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard let last = lines.last, last.count >= 4 else { return !text.isEmpty }
        return last[last.index(last.startIndex, offsetBy: 3)] == " "
    }
}
