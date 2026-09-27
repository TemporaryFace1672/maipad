import Foundation
import Network

/// Listens on a TCP port. The PC reaches it through the USB cable (usbmuxd), so nothing here touches Wi-Fi.
/// Protocol (text lines, '\n' terminated): "S" + 34 chars of 0/1 (touch sensors), "B" + 5 chars (select,test,service,coin,card).
final class PadServer {
    static let port: UInt16 = 24870

    var onStatus: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "maipad.server")
    private var listener: NWListener?
    private var conn: NWConnection?
    private var lastS = String(repeating: "0", count: 34)
    private var lastB = "00000"

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
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self = self, let c = c, c === self.conn else { return }
            switch state {
            case .ready:
                self.report(true)
                self.sendLine("S" + self.lastS)
                self.sendLine("B" + self.lastB)
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

    /// The PC never sends anything; reading only tells us when it goes away.
    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 256) { [weak self, weak c] _, _, isComplete, error in
            guard let self = self, let c = c else { return }
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

    private func sendLine(_ line: String) {
        guard let c = conn, let data = (line + "\n").data(using: .utf8) else { return }
        c.send(content: data, completion: .contentProcessed({ _ in }))
    }

    private func report(_ connected: Bool) {
        DispatchQueue.main.async { self.onStatus?(connected) }
    }
}
