import Foundation
import Network
import ImageIO

/// Listens on a TCP port. The PC reaches it through the USB cable (usbmuxd), so nothing here touches Wi-Fi.
/// App -> PC (text lines, '\n' terminated):
///   "S" + 34 chars of 0/1 (touch sensors), "B" + 5 chars (select,test,service,coin,card),
///   "V<size>,<quality>" asks for the game video (JPEG, size x size), "V0" turns it off.
/// PC -> app: video frames, each [UInt32 little-endian length][JPEG bytes].
final class PadServer {
    static let port: UInt16 = 24870
    static let videoSize = 1080
    static let videoQuality = 75

    var onStatus: ((Bool) -> Void)?
    var onFrame: ((CGImage) -> Void)?   // called on a background queue

    private let queue = DispatchQueue(label: "maipad.server")
    private let decodeQueue = DispatchQueue(label: "maipad.decode")
    private var listener: NWListener?
    private var conn: NWConnection?
    private var lastS = String(repeating: "0", count: 34)
    private var lastB = "00000"
    private var videoWanted = true
    private var inbox = Data()
    private var decoding = false
    private var pendingJpeg: Data?

    func start() {
        queue.async { self.startListener() }
    }

    func setSensors(_ s: String) {
        queue.async {
            self.lastS = s
            self.sendLine("S" + s)
        }
    }

    func setButtons(_ s: String) {
        queue.async {
            self.lastB = s
            self.sendLine("B" + s)
        }
    }

    func setVideo(_ on: Bool) {
        queue.async {
            self.videoWanted = on
            self.sendVideoRequest()
        }
    }

    private func sendVideoRequest() {
        sendLine(videoWanted ? "V\(PadServer.videoSize),\(PadServer.videoQuality)" : "V0")
    }

    private func startListener() {
        listener?.cancel()
        listener = nil
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: PadServer.port),
              let l = try? NWListener(using: params, on: port) else {
            queue.asyncAfter(deadline: .now() + 2) { self.startListener() }
            return
        }
        l.newConnectionHandler = { [weak self] c in
            self?.accept(c)
        }
        l.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.queue.asyncAfter(deadline: .now() + 2) { self?.startListener() }
            }
        }
        listener = l
        l.start(queue: queue)
    }

    private func accept(_ c: NWConnection) {
        conn?.cancel()
        conn = c
        inbox = Data()
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self = self, let c = c, c === self.conn else { return }
            switch state {
            case .ready:
                self.report(true)
                self.sendLine("S" + self.lastS)
                self.sendLine("B" + self.lastB)
                self.sendVideoRequest()
            case .failed, .cancelled:
                self.conn = nil
                self.report(false)
            default:
                break
            }
        }
        c.start(queue: queue)
        receive(c)
    }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak c] data, _, isComplete, error in
            guard let self = self, let c = c else { return }
            if let data = data, !data.isEmpty, c === self.conn {
                self.inbox.append(data)
                self.drainFrames()
            }
            if isComplete || error != nil {
                if c === self.conn {
                    self.conn = nil
                    self.report(false)
                }
                c.cancel()
            } else {
                self.receive(c)
            }
        }
    }

    /// Splits the incoming bytes into frames; only the newest complete frame is decoded (older ones are dropped).
    private func drainFrames() {
        var newest: Data?
        while inbox.count >= 4 {
            let len = Int(UInt32(inbox[0]) | (UInt32(inbox[1]) << 8) | (UInt32(inbox[2]) << 16) | (UInt32(inbox[3]) << 24))
            if len <= 0 || len > 4_000_000 {
                inbox = Data()   // out of sync, wait for the next connection / frame boundary
                return
            }
            if inbox.count < 4 + len { break }
            newest = inbox.subdata(in: 4..<(4 + len))
            inbox = inbox.subdata(in: (4 + len)..<inbox.count)
        }
        if let jpeg = newest { decode(jpeg) }
    }

    private func decode(_ jpeg: Data) {
        pendingJpeg = jpeg
        if decoding { return }
        decoding = true
        decodeQueue.async {
            while true {
                var next: Data?
                self.queue.sync {
                    next = self.pendingJpeg
                    self.pendingJpeg = nil
                    if next == nil { self.decoding = false }
                }
                guard let jpg = next else { return }
                let opts = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
                if let src = CGImageSourceCreateWithData(jpg as CFData, nil),
                   let img = CGImageSourceCreateImageAtIndex(src, 0, opts) {
                    self.onFrame?(img)
                }
            }
        }
    }

    private func sendLine(_ line: String) {
        guard let c = conn, let data = (line + "\n").data(using: .utf8) else { return }
        c.send(content: data, completion: .contentProcessed({ _ in }))
    }

    private func report(_ connected: Bool) {
        DispatchQueue.main.async { self.onStatus?(connected) }
    }
}
