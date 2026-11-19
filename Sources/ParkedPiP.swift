import AppKit
import ApplicationServices

// The matching signed executable owns the move. EOF restores Edge's window even
// if the UI process crashes or is force-quit.
final class ParkedPiP {
    private let commands = Pipe()
    private let response = Pipe()
    private let worker = Process()
    private(set) var ready = false
    private var lastSize = CGSize.zero
    var running: Bool { worker.isRunning }

    init?(source: WindowInfo) {
        guard let executable = Bundle.main.executableURL else { return nil }
        _ = fcntl(commands.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        lastSize = CGSize(width: source.frame.width.rounded(), height: source.frame.height.rounded())
        worker.executableURL = executable
        worker.arguments = ["--hold-pip", String(source.pid), String(source.id)]
        worker.standardInput = commands
        worker.standardOutput = response
        do { try worker.run() } catch { return nil }
        response.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            handle.readabilityHandler = nil
            DispatchQueue.main.async { self?.ready = data.first == 1 }
        }
    }

    func resize(to size: CGSize) {
        let target = CGSize(width: size.width.rounded(), height: size.height.rounded())
        guard ready, running, target != lastSize else { return }
        lastSize = target
        try? commands.fileHandleForWriting.write(contentsOf: Data("\(Int(target.width)) \(Int(target.height))\n".utf8))
    }

    func restore() {
        response.fileHandleForReading.readabilityHandler = nil
        try? commands.fileHandleForWriting.close()
    }

    static func hold(pid: pid_t, id: CGWindowID) -> Int32 {
        guard AXIsProcessTrusted(),
              NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.microsoft.edgemac" else { return 1 }
        func source() -> WindowInfo? {
            let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String:Any]] ?? []
            return rows.compactMap(WindowInfo.init).first {
                $0.id == id && $0.pid == pid && $0.layer == CGWindowLevelForKey(.floatingWindow) && pipTitles.contains($0.title)
            }
        }
        func attribute(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success else { return nil }
            return value
        }
        func frame(_ element: AXUIElement) -> CGRect? {
            guard let pos = attribute(element, kAXPositionAttribute), CFGetTypeID(pos) == AXValueGetTypeID(),
                  let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero, extent = CGSize.zero
            guard AXValueGetValue(pos as! AXValue, .cgPoint, &point),
                  AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
            return CGRect(origin: point, size: extent)
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let original = source(), let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return 2 }
        let matches = windows.filter { window in
            guard attribute(window, kAXTitleAttribute) as? String == original.title, let f = frame(window) else { return false }
            return abs(f.minX - original.frame.minX) <= 2 && abs(f.minY - original.frame.minY) <= 2 &&
                   abs(f.width - original.frame.width) <= 2 && abs(f.height - original.frame.height) <= 2
        }
        guard matches.count == 1, let window = matches.first else { return 2 }
        AXUIElementSetMessagingTimeout(window, 0.5)
        func move(_ point: CGPoint) -> Bool {
            var p = point
            return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &p)!) == .success
        }
        func resize(_ size: CGSize) {
            var s = size
            _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &s)!)
        }
        func screens() -> [CGRect] { NSScreen.screens.map(\.quartzBounds) }
        // Always use an on-display restore position, including if the display layout changes.
        func restoreFrame() -> CGRect {
            let displays = screens()
            let display = displays.max { lhs, rhs in
                let l = lhs.intersection(original.frame), r = rhs.intersection(original.frame)
                return (l.isNull ? 0 : l.width*l.height) < (r.isNull ? 0 : r.width*r.height)
            } ?? CGDisplayBounds(CGMainDisplayID())
            let size = CGSize(width: min(original.frame.width, display.width), height: min(original.frame.height, display.height))
            return CGRect(x: min(max(original.frame.minX,display.minX),display.maxX-size.width),
                          y: min(max(original.frame.minY,display.minY),display.maxY-size.height),width:size.width,height:size.height)
        }
        let guardState = CaptureGuard()
        guard !guardState.isBlockingCapture else { return 3 }
        func parkingPoint() -> CGPoint {
            CGPoint(x:(screens().map(\.maxX).max() ?? 0) + 4096, y:original.frame.minY)
        }
        guard move(parkingPoint()) else { return 3 }
        defer {
            if source() != nil {
                let f = restoreFrame()
                resize(f.size)
                _ = move(f.origin)
            }
        }
        guard let moved = frame(window), !screens().contains(where: { $0.intersects(moved) }) else { return 3 }
        var ack: UInt8 = 1
        guard write(STDOUT_FILENO, &ack, 1) == 1 else { return 3 }
        var input = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        var pending = Data()
        var lastCheck = 0.0
        while true {
            let n = poll(&input, 1, 300)
            if n < 0 { if errno == EINTR { continue }; return 4 }
            if guardState.isBlockingCapture { return 0 }
            if n > 0 {
                var bytes = [UInt8](repeating: 0, count: 512)
                let count = read(STDIN_FILENO, &bytes, bytes.count)
                guard count > 0 else { return 0 }
                pending.append(contentsOf: bytes.prefix(count))
                while let newline = pending.firstIndex(of: 10) {
                    let fields = String(decoding: pending[..<newline], as: UTF8.self).split(separator: " ").compactMap { Int($0) }
                    pending.removeSubrange(...newline)
                    if fields.count == 2, fields.allSatisfy({ (32...16384).contains($0) }) {
                        resize(CGSize(width: fields[0], height: fields[1]))
                    }
                }
                guard pending.count <= 64 else { return 4 }
            }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastCheck > 0.4 {
                lastCheck = now
                guard let actual = source() else { return 0 }
                let displays = screens()
                // During a swipe the compositor translates the source even when
                // Edge has not moved it. Avoid moving Edge back to its own Space.
                if displays.contains(where: { $0.intersects(actual.frame) }),
                   let position = frame(window), displays.contains(where: { $0.intersects(position) }),
                   !move(parkingPoint()) { return 4 }
            }
        }
    }
}
