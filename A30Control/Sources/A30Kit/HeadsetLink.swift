// RFCOMM channel 26 to the A30 + IAP2Session + a one-in-flight CPP request queue.
// IOBluetooth delivers delegate callbacks on the main thread's run loop, so the class is
// MainActor-isolated and the nonisolated delegate methods hop in with assumeIsolated.
import Foundation
import IOBluetooth

@MainActor
public final class HeadsetLink: NSObject, IOBluetoothRFCOMMChannelDelegate {
    public static let channelID: BluetoothRFCOMMChannelID = 26

    public var onClose: (@MainActor () -> Void)?
    /// Unsolicited reports the headset pushes with swID 0 (e.g. volume wheel, EQ change): (index, function, args).
    public var onNotification: (@MainActor (UInt8, UInt8, [UInt8]) -> Void)?
    public var log: (String) -> Void = { print("[A30]", $0) }
    public private(set) var isReady = false

    private var channel: IOBluetoothRFCOMMChannel?
    private var session = IAP2Session()
    private var spp = SPPParser()
    private var cpl = CPLReassembler()
    private var openWaiter: CheckedContinuation<Void, Error>?
    private var openGen = 0

    private struct Pending {
        let id: Int
        let index: UInt8
        let function: UInt8
        let args: [UInt8]
        var swID: UInt8 = 0
        let cont: CheckedContinuation<[UInt8], Error>
    }
    private var queue: [Pending] = []
    private var current: Pending?
    private var nextID = 0
    private var sw: UInt8 = 0
    private var consecutiveTimeouts = 0

    public override init() { super.init() }

    /// Opens the channel and completes the iAP2 handshake. Returns once CPP requests may be sent.
    public func open(address: String, timeout: Duration = .seconds(8)) async throws {
        close()
        guard let dev = IOBluetoothDevice(addressString: address) else { throw A30Error.notFound }
        // Opening RFCOMM on a disconnected device makes macOS page it and bring the link up,
        // which would override a manual disconnect. Only attach to an already-connected headset.
        guard dev.isConnected() else { throw A30Error.notConnectedToMac }
        session = IAP2Session(); spp = SPPParser(); cpl = CPLReassembler(); consecutiveTimeouts = 0
        openGen += 1
        let gen = openGen
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            openWaiter = c
            var ch: IOBluetoothRFCOMMChannel?
            let r = dev.openRFCOMMChannelAsync(&ch, withChannelID: Self.channelID, delegate: self)
            channel = ch
            if r != kIOReturnSuccess { failOpen(A30Error.openFailed(r)); return }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, self.openGen == gen, self.openWaiter != nil else { return }
                self.log("open timed out (stale channel or another host holds it)")
                self.failOpen(A30Error.timeout)
            }
        }
    }

    public func close() {
        let ch = channel
        channel = nil
        _ = ch?.close()
        teardown(A30Error.disconnected, notify: false)
    }

    func request(_ index: UInt8, _ function: UInt8, _ args: [UInt8] = []) async throws -> [UInt8] {
        guard isReady else { throw A30Error.disconnected }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<[UInt8], Error>) in
            nextID += 1
            queue.append(Pending(id: nextID, index: index, function: function, args: args, cont: c))
            pump()
        }
    }

    // MARK: IOBluetoothRFCOMMChannelDelegate

    nonisolated public func rfcommChannelOpenComplete(_ c: IOBluetoothRFCOMMChannel!, status: IOReturn) {
        MainActor.assumeIsolated {
            guard c === channel else { return }
            if status != kIOReturnSuccess { failOpen(A30Error.openFailed(status)) }
        }
    }

    nonisolated public func rfcommChannelData(_ c: IOBluetoothRFCOMMChannel!, data p: UnsafeMutableRawPointer!, length n: Int) {
        let bytes = Array(UnsafeRawBufferPointer(start: p, count: n))
        MainActor.assumeIsolated {
            guard c === channel else { return }
            handle(session.receive(bytes))
        }
    }

    nonisolated public func rfcommChannelClosed(_ c: IOBluetoothRFCOMMChannel!) {
        MainActor.assumeIsolated {
            guard c === channel else { return }
            channel = nil
            log("channel closed")
            teardown(A30Error.disconnected, notify: true)
        }
    }

    // MARK: internals

    private func handle(_ events: [IAP2Event]) {
        for e in events {
            switch e {
            case .send(let b):
                write(b)
            case .log(let s):
                log(s)
            case .reset:
                log("iAP2 reset by accessory")
                let ch = channel; channel = nil; _ = ch?.close()
                teardown(A30Error.disconnected, notify: true)
                return
            case .ready:
                let gen = openGen
                Task { [weak self] in   // the accessory needs a moment after EA00 before CPP traffic
                    try? await Task.sleep(for: .milliseconds(300))
                    guard let self, self.openGen == gen, self.channel != nil else { return }
                    self.isReady = true
                    if let w = self.openWaiter { self.openWaiter = nil; w.resume() }
                }
            case .eaData(let d):
                for payload in spp.feed(d) {
                    if let m = cpl.feed(payload), let r = CPPReply(m) { deliver(r) }
                }
            }
        }
    }

    private func write(_ bytes: [UInt8]) {
        guard let ch = channel else { return }
        var b = bytes
        // writeAsync copies the buffer (proven by a30b.swift), so a temporary pointer is fine.
        let r = b.withUnsafeMutableBytes { ch.writeAsync($0.baseAddress, length: UInt16($0.count), refcon: nil) }
        if r != kIOReturnSuccess { log(String(format: "write failed 0x%08x", r)) }
    }

    private func pump() {
        guard current == nil, isReady, !queue.isEmpty else { return }
        var p = queue.removeFirst()
        sw = sw % 15 + 1      // swId 1…15, never 0
        p.swID = sw
        current = p
        write(session.eaPacket(sppWrap(cppRequest(index: p.index, function: p.function, swID: p.swID, args: p.args))))
        let id = p.id
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            self?.timeout(id)
        }
    }

    private func timeout(_ id: Int) {
        guard let p = current, p.id == id else { return }
        consecutiveTimeouts += 1
        log("timeout idx=\(p.index) fn=\(p.function)")
        if consecutiveTimeouts >= 3 {
            consecutiveTimeouts = 0
            let ch = channel; channel = nil; _ = ch?.close()
            teardown(A30Error.disconnected, notify: true)
            return
        }
        current = nil
        p.cont.resume(throwing: A30Error.timeout)
        pump()
    }

    private func deliver(_ r: CPPReply) {
        // swID 0 is never used for requests, so these are always device-initiated notifications.
        if case let .ok(index, function, 0, args) = r { onNotification?(index, function, args); return }
        guard let p = current else { log("unsolicited \(r)"); return }
        switch r {
        case let .ok(index, _, swID, args) where index == p.index && swID == p.swID:
            finish(.success(args))
        case let .error(index, _, swID, code) where index == p.index && swID == p.swID:
            finish(.failure(A30Error.device(CenturionError(rawValue: code) ?? .failed)))
        default:
            log("unmatched reply \(r)")
        }
    }

    private func finish(_ r: Result<[UInt8], Error>) {
        guard let p = current else { return }
        current = nil
        consecutiveTimeouts = 0
        p.cont.resume(with: r)
        pump()
    }

    private func failOpen(_ e: Error) {
        let ch = channel; channel = nil; _ = ch?.close()
        teardown(e, notify: false)
    }

    /// Fails everything in flight. `notify` reports a drop of an established link to onClose.
    private func teardown(_ error: Error, notify: Bool) {
        let wasReady = isReady
        isReady = false
        if let w = openWaiter { openWaiter = nil; w.resume(throwing: error) }
        let pending = (current.map { [$0] } ?? []) + queue
        current = nil
        queue = []
        for p in pending { p.cont.resume(throwing: A30Error.disconnected) }
        if notify && wasReady { onClose?() }
    }
}
