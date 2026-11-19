import AppKit
import Darwin

struct MediaState {
    let time: Double
    let range: ClosedRange<Double>?
    let paused: Bool
    let volume: Double
    let muted: Bool
    let useNativePiP: Bool
    let previous, next, hasCaptions, captions, live: Bool
    let rate: Double
    let captionText: String

    init?(_ row: [String: Any]) {
        guard let time = row["time"] as? Double, time.isFinite,
              let paused = row["paused"] as? Bool, let muted = row["muted"] as? Bool,
              let volume = row["volume"] as? Double, volume.isFinite else { return nil }
        self.time = time; self.paused = paused; self.volume = volume; self.muted = muted
        useNativePiP = row["ordinaryPiP"] as? Bool != true
        previous = row["previous"] as? Bool ?? false
        next = row["next"] as? Bool ?? false
        hasCaptions = row["hasCaptions"] as? Bool ?? false
        captions = row["captions"] as? Bool ?? false
        live = row["live"] as? Bool ?? false
        rate = row["rate"] as? Double ?? 1
        captionText = row["captionText"] as? String ?? ""
        let spans = row["spans"] as? [[Double]] ?? []
        if let start = spans.first?.first, let end = spans.last?.last, start.isFinite, end.isFinite, start < end {
            range = start...end
        } else { range = nil }
    }
}

// Local native-messaging relay. The browser owns the connection for precisely the
// lifetime of document.pictureInPictureElement, including while its Space is hidden.
final class MediaLink {
    var onState: ((MediaState) -> Void)?
    var onDisconnect: (() -> Void)?
    private var listener: DispatchSourceRead?
    private var reader: DispatchSourceRead?
    private var pending = Data()
    private var socketPath: String?
    private(set) var browserPID: pid_t?
    private(set) var state: MediaState?

    func start() -> Bool {
        var tmp = [CChar](repeating: 0, count: 1024)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &tmp, tmp.count) > 0 else { return false }
        let path = String(cString: tmp) + "edgepip-control.sock"
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes.map { UInt8(bitPattern: $0) })
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address -> Bool in
                if bind(fd,address,length) != 0 {
                    guard errno == EADDRINUSE else { return false }
                    let probe = socket(AF_UNIX, SOCK_STREAM, 0)
                    guard probe >= 0 else { return false }
                    let stale = connect(probe,address,length) < 0 && errno == ECONNREFUSED
                    close(probe)
                    guard stale, unlink(path) == 0, bind(fd,address,length) == 0 else { return false }
                }
                return true
            }
        }
        guard ok else { close(fd); return false }
        socketPath = path
        guard chmod(path,0o600) == 0, listen(fd,4) == 0 else { close(fd); unlink(path); return false }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.acceptClient(fd) }
        source.setCancelHandler { close(fd) }
        listener = source; source.resume()
        return true
    }
    private func acceptClient(_ fd: Int32) {
        let client = accept(fd,nil,nil)
        guard client >= 0 else { return }
        var owner: uid_t = 0, group: gid_t = 0
        guard getpeereid(client,&owner,&group) == 0, owner == getuid() else { close(client); return }
        disconnect()
        _ = fcntl(client,F_SETFL,O_NONBLOCK)
        var yes: Int32 = 1
        setsockopt(client,SOL_SOCKET,SO_NOSIGPIPE,&yes,socklen_t(MemoryLayout.size(ofValue:yes)))
        let source = DispatchSource.makeReadSource(fileDescriptor:client,queue:.main)
        source.setEventHandler { [weak self] in self?.receive(client) }
        source.setCancelHandler { close(client) }
        reader = source; source.resume()
    }
    private func receive(_ fd: Int32) {
        guard reader?.handle == UInt(fd) else { return }
        var buf = [UInt8](repeating:0,count:8192)
        let count = read(fd,&buf,buf.count)
        if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
        guard count > 0 else { disconnect(); return }
        pending.append(contentsOf: buf.prefix(count))
        while pending.count >= 4 {
            let size = Int(pending.prefix(4).enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << (8 * $1.offset)) })
            guard size > 0, size <= 65536 else { disconnect(); return }
            if pending.count < size + 4 { return }
            let data = Data(pending.dropFirst(4).prefix(size))
            pending = Data(pending.dropFirst(size + 4))
            guard let msg = try? JSONSerialization.jsonObject(with:data) as? [String: Any] else { disconnect(); return }
            if msg["type"] as? String == "browser" {
                browserPID = (msg["pids"] as? [Int32])?.first { NSRunningApplication(processIdentifier:$0)?.bundleIdentifier == "com.microsoft.edgemac" }
            } else if msg["type"] as? String == "state", let new = MediaState(msg) {
                state = new; onState?(new)
            }
        }
    }
    func send(_ action: String, _ value: Double? = nil) {
        guard let fd = reader?.handle, state != nil else { return }
        var json: [String: Any] = ["type":"control","action":action]
        if let value, value.isFinite { json["value"] = value }
        guard let data = try? JSONSerialization.data(withJSONObject:json) else { return }
        var count = UInt32(data.count).littleEndian
        var packet = Data(bytes:&count,count:4)
        packet.append(data)
        let sent = packet.withUnsafeBytes { write(Int32(fd),$0.baseAddress,packet.count) }
        if sent != packet.count { disconnect() }
    }
    private func disconnect() {
        reader?.cancel(); reader = nil; pending.removeAll(); browserPID = nil
        let wasPlaying = state != nil
        state = nil
        if wasPlaying { onDisconnect?() }
    }
    func stop() {
        disconnect(); listener?.cancel(); listener = nil
        if let path = socketPath { unlink(path); socketPath = nil }
    }
}
