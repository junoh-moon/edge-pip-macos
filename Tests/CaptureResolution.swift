import AppKit
import ScreenCaptureKit

private struct CheckFailed: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

// Observe the exact sample handed to the production renderer through one stream output.
private final class ObservedOutput: NSObject, SCStreamOutput {
    let capture: Capture
    var pixels = CGSize.zero
    var contentScale: CGFloat = 0
    init(_ capture: Capture) { self.capture = capture }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        capture.stream(stream, didOutputSampleBuffer: sample, of: type)
        guard let image = sample.imageBuffer,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                          as? [[SCStreamFrameInfo: Any]])?.first,
              info[.status] as? Int == SCFrameStatus.complete.rawValue else { return }
        pixels = CGSize(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))
        contentScale = info[.contentScale] as? CGFloat ?? 0
    }
}

@MainActor func testCaptureResolution() async throws {
    let source = NSPanel(contentRect: CGRect(x: 80, y: 100, width: 200, height: 112),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    source.hasShadow = false
    source.backgroundColor = .systemBlue
    source.orderBack(nil)
    defer { source.orderOut(nil) }
    let preview = NSPanel(contentRect: source.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    let view = VideoView(frame: source.frame)
    preview.contentView = view
    preview.setFrameOrigin(CGPoint(x: 90, y: 100))
    preview.orderBack(nil)
    defer { preview.orderOut(nil) }
    view.layoutSubtreeIfNeeded()
    guard view.video.contentsScale == preview.backingScaleFactor else {
        throw CheckFailed("Preview layer has the wrong pixel density")
    }

    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
    guard let window = content.windows.first(where: { $0.windowID == source.windowNumber }) else {
        throw CheckFailed("Missing test window")
    }
    let capture = Capture(view: view)
    try await capture.start(filter: SCContentFilter(desktopIndependentWindow: window))
    defer { capture.stop() }
    guard let stream = capture.stream else { throw CheckFailed("Missing test stream") }
    let output = ObservedOutput(capture)
    try stream.removeStreamOutput(capture, type: .screen)
    try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .main)

    func expectNativePixels(_ points: CGSize) async throws {
        let scale = source.backingScaleFactor
        let expected = CGSize(width: (points.width * scale).rounded(), height: (points.height * scale).rounded())
        let deadline = ContinuousClock.now + .seconds(4)
        var alternate = false
        repeat {
            source.backgroundColor = alternate ? .systemBlue : .systemGreen
            alternate.toggle()
            try await Task.sleep(for: .milliseconds(80))
            if output.pixels == expected && abs(output.contentScale - 1) < 0.002 {
                print("PASS", Int(expected.width), "×", Int(expected.height), "native pixels")
                return
            }
        } while ContinuousClock.now < deadline
        throw CheckFailed("Expected \(expected), received \(output.pixels) at content scale \(output.contentScale)")
    }
    try await expectNativePixels(source.frame.size)
    // Several changes in quick succession must converge on the last size without restarting capture.
    for width in [310, 410, 480] {
        source.setContentSize(CGSize(width: width, height: width * 9 / 16))
        try await Task.sleep(for: .milliseconds(40))
    }
    try await expectNativePixels(source.frame.size)
    source.setContentSize(CGSize(width: 300, height: 170))
    try await expectNativePixels(source.frame.size)

    // Simulate an ordered panel stranded outside the current desktop. The
    // WindowServer check must recover the very same live video surface.
    guard let screen = NSScreen.main else { throw CheckFailed("Missing display") }
    let player = AppDelegate()
    player.panel = preview
    player.capture = capture
    player.presentMirror = true
    player.savedFrame = CGRect(x: screen.visibleFrame.midX - 160, y: screen.visibleFrame.midY - 90,
                               width: 320, height: 180)
    let rightEdge = NSScreen.screens.map { $0.frame.maxX }.max()!
    preview.setFrameOrigin(CGPoint(x: rightEdge + 1024, y: screen.frame.midY))
    defer { player.panel.orderOut(nil) }
    let deadline = ContinuousClock.now + .seconds(4)
    while ContinuousClock.now < deadline {
        if player.presentIfReady(), player.panel !== preview, !preview.isVisible,
           player.panel.contentView === view, player.capture?.stream === stream {
            guard player.panel.collectionBehavior.contains(.transient) else {
                throw CheckFailed("Recovered PiP would overlay Edge's Mission Control preview")
            }
            print("PASS recovered a stranded window with the original video surface")
            return
        }
        try await Task.sleep(for: .milliseconds(80))
    }
    throw CheckFailed("Could not recover the off-display video panel")
}
