import AppKit
import AVFoundation
import ScreenCaptureKit

private let edgeIdentifier = "com.microsoft.edgemac"
let pipTitles: Set<String> = {
    let url = Bundle.main.url(forResource: "PiPTitles", withExtension: "txt")
    let strings = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    return Set(strings.components(separatedBy: .newlines).filter { !$0.isEmpty })
        .union(["Picture in Picture", "Picture-in-Picture", "화면 속 화면"])
}()

struct WindowInfo {
    let id: CGWindowID
    let pid: pid_t
    let layer: Int
    let title: String
    let frame: CGRect
    init?(_ row: [String: Any]) {
        guard let id = row[kCGWindowNumber as String] as? UInt32,
              let pid = row[kCGWindowOwnerPID as String] as? Int32,
              let layer = row[kCGWindowLayer as String] as? Int,
              let bounds = row[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              (row[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
        self.id = id; self.pid = pid; self.layer = layer; self.frame = frame
        title = row[kCGWindowName as String] as? String ?? ""
    }
    var display: NSScreen? {
        NSScreen.screens.max { intersectionArea($0) < intersectionArea($1) }
    }
    private func intersectionArea(_ display: NSScreen) -> CGFloat {
        let part = frame.intersection(display.quartzBounds)
        return part.isNull ? 0 : part.width * part.height
    }
}
extension NSScreen {
    var quartzBounds: CGRect {
        let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber
        return CGDisplayBounds(number.uint32Value)
    }
}

final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    let view: VideoView
    private var configuredPixels = CGSize.zero
    private var wantedPixels = CGSize.zero
    private var resizeTask: Task<Void, Never>?
    private(set) var lastFrameAt: TimeInterval = 0

    init(view: VideoView, hasDisplayedFrame: Bool = false) {
        self.view = view
        self.hasFrame = hasDisplayedFrame
        super.init()
    }
    var stream: SCStream?
    var onFrame: (() -> Void)?
    var onStop: (() -> Void)?
    var cancelled = false
    var starting = false
    private(set) var hasFrame = false

    @MainActor func start(source: WindowInfo, protection: CaptureGuard) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard !cancelled, !protection.isBlockingCapture, let window = content.windows.first(where: {
            $0.windowID == source.id && $0.owningApplication?.bundleIdentifier == edgeIdentifier
                && $0.owningApplication?.processID == source.pid && pipTitles.contains($0.title ?? "")
        }) else { throw CancellationError() }
        try await start(filter: SCContentFilter(desktopIndependentWindow: window))
    }

    @MainActor func start(filter: SCContentFilter) async throws {
        configuredPixels = pixelSize(filter.contentRect.size, scale: CGFloat(filter.pointPixelScale))
        wantedPixels = configuredPixels
        let stream = SCStream(filter: filter, configuration: configuration(for: configuredPixels), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
        self.stream = stream
        starting = true
        do {
            try await stream.startCapture()
        } catch {
            starting = false
            throw error
        }
        starting = false
        if cancelled { try? await stream.stopCapture() }
    }

    private func pixelSize(_ points: CGSize, scale: CGFloat) -> CGSize {
        CGSize(width: max(2, (points.width * scale).rounded()),
               height: max(2, (points.height * scale).rounded()))
    }

    private func configuration(for pixels: CGSize) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = Int(pixels.width)
        config.height = Int(pixels.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 3
        config.showsCursor = false
        config.capturesAudio = false
        config.ignoreShadowsSingleWindow = true
        config.ignoreGlobalClipSingleWindow = true
        config.captureResolution = .best
        return config
    }

    private func followSourceResolution(_ info: [SCStreamFrameInfo: Any], stream: SCStream) {
        // screenRect is the original window in points, even when the current buffer is downscaled.
        guard let raw = info[.screenRect] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: raw as CFDictionary),
              !rect.isEmpty, !rect.isInfinite, let scale = info[.scaleFactor] as? CGFloat,
              scale > 0, scale.isFinite else { return }
        wantedPixels = pixelSize(rect.size, scale: scale)
        guard wantedPixels != configuredPixels, resizeTask == nil else { return }
        resizeTask = Task { @MainActor in
            defer { resizeTask = nil }
            do {
                while !cancelled && wantedPixels != configuredPixels {
                    // Coalesce live resize frames and apply only one configuration at a time.
                    try await Task.sleep(for: .milliseconds(120))
                    let target = wantedPixels
                    guard !cancelled, target != configuredPixels else { return }
                    if starting { continue }
                    try await stream.updateConfiguration(configuration(for: target))
                    configuredPixels = target
                }
            } catch {
                if !cancelled { onStop?() }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !cancelled, type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
              let info = (attachments as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        // Keep the last ordinary frame during a Space transition. Ending the session
        // or switching to protected playback detaches and clears the display layer.
        guard status == .complete, sample.imageBuffer != nil else { return }
        followSourceResolution(info, stream: stream)
        let renderer = view.video.sampleBufferRenderer
        if renderer.requiresFlushToResumeDecoding { renderer.flush() }
        guard renderer.isReadyForMoreMediaData else { return }
        let metadata = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(metadata, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        renderer.enqueue(sample)
        lastFrameAt = ProcessInfo.processInfo.systemUptime
        if !hasFrame { hasFrame = true; onFrame?() }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.cancelled else { return }
            self.onStop?()
        }
    }
    func stop() {
        cancelled = true
        resizeTask?.cancel()
        onFrame = nil; onStop = nil
        if let stream, !starting { Task { try? await stream.stopCapture() } }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let menuItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let state = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var panel: NSPanel!
    private var parked: ParkedPiP?
    private var parkAgainAfter: TimeInterval = 0
    private var toolbar: NSPanel!
    private let toolbarControls = VideoView(frame:.zero)
    var capture: Capture?
    var source: WindowInfo?
    let link = MediaLink()
    var listening = false
    var savedFrame: NSRect?
    var lastRepaired: TimeInterval = 0
    var offDisplaySince: TimeInterval?
    var nativeVisibleSince: TimeInterval?
    var presentMirror = false
    var retryAfter: TimeInterval = 0
    var timer: Timer?
    var spaceObserver: NSObjectProtocol?
    var settle: DispatchWorkItem?
    let captureGuard = CaptureGuard()
    var resumeAfter: TimeInterval = 0
    var allowed = false
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func makeVideoPanel(frame: NSRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Edge PiP Mirror"
        panel.isFloatingPanel = true
        panel.level = .statusBar
        // Mission Control already shows Edge's source window in its overview.
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width:270,height:105)
        panel.delegate = self
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        return panel
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = makeVideoPanel(frame: .zero)
        toolbar = NSPanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        toolbar.title = "Edge PiP Controls"
        toolbar.level = .statusBar
        toolbar.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.transient,.ignoresCycle]
        toolbar.hidesOnDeactivate = false
        toolbar.isOpaque = false
        toolbar.backgroundColor = .clear
        toolbar.hasShadow = true
        toolbar.isReleasedWhenClosed = false
        toolbar.becomesKeyOnlyIfNeeded = true
        toolbarControls.compact = true
        toolbarControls.command = { [weak self] action,value in self?.link.send(action,value) }
        toolbar.contentView = toolbarControls
        listening = link.start()
        link.onState = { [weak self] state in
            guard let self else { return }
            self.capture?.view.update(state)
            if self.source == nil || state.useNativePiP { self.tick() }
        }
        link.onDisconnect = { [weak self] in
            self?.toolbar.orderOut(nil)
            self?.capture?.view.showWindowControls()
            self?.tick()
        }
        let menuIcon = NSImage(named: "MenuBarTemplate") ?? NSImage(systemSymbolName: "pip", accessibilityDescription: "Edge PiP")
        menuIcon?.isTemplate = true
        menuItem.button?.image = menuIcon
        menuItem.button?.setAccessibilityLabel("Edge PiP")
        let menu = NSMenu()
        menu.addItem(state)
        menu.addItem(.separator())
        menu.addItem(withTitle: "손쉬운 사용 권한 설정…", action: #selector(accessibilitySettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "화면 기록 권한 설정…", action: #selector(settings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Edge PiP 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menuItem.menu = menu
        if !AXIsProcessTrusted(), !UserDefaults.standard.bool(forKey: "askedToMovePiP") {
            UserDefaults.standard.set(true, forKey: "askedToMovePiP")
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        allowed = CGPreflightScreenCaptureAccess()
        if !allowed { allowed = CGRequestScreenCaptureAccess() }
        captureGuard.observe { [weak self] in self?.tick() }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.offDisplaySince != nil { self.offDisplaySince = self.now }
            self.tick()
            self.settle?.cancel()
            let settled = DispatchWorkItem { [weak self] in
                guard let self, self.presentMirror, let capture=self.capture,
                      let pip=self.source, let screen=pip.display,
                      self.link.state?.paused != true, self.now-capture.lastFrameAt>0.55 else { return }
                // Restart only a stalled stream. Both streams use the same surface,
                // so the last frame remains on screen until the new stream delivers.
                capture.stop()
                self.beginCapture(pip,screen:screen,reusing:capture)

            }
            self.settle = settled
            DispatchQueue.main.asyncAfter(deadline:.now()+0.55, execute:settled)
        }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.06
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        tick()
    }
    @objc func accessibilitySettings() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc func settings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
    func message(_ text: String) {
        if state.title != text { state.title = text; menuItem.button?.toolTip = text }
    }
    func tick() {
        if captureGuard.isBlockingCapture || link.state?.useNativePiP == true {
            resumeAfter = now + 0.55
            settle?.cancel()
            toolbar.orderOut(nil)
            stopCapture()
            source = nil
            presentMirror = false
            nativeVisibleSince = nil
            message("보호 영상 · 화면 캡처 일시 중지")
            return
        }
        guard now >= resumeAfter else { return }
        if !allowed {
            allowed = CGPreflightScreenCaptureAccess()
            if !allowed { message("화면 기록 권한이 필요합니다"); return }
        }
        // The extension identifies the active video. Until it does, leave Edge's own window alone.
        guard let media = link.state, let browserPID = link.browserPID else { reset(); return }
        if let held = parked {
            if !held.running {
                held.restore()
                parked = nil
                parkAgainAfter = now + 1
            } else if held.ready {
                presentMirror = true
                toolbar.orderOut(nil)
                let visible = presentIfReady()
                if !visible {
                    if offDisplaySince == nil { offDisplaySince = now }
                    if now - (offDisplaySince ?? now) >= 2 {
                        held.restore()
                        parked = nil
                        parkAgainAfter = now + 1.2
                        message("Edge 원래 PiP로 복귀 중")
                    }
                    return
                }
                if let size = savedFrame?.size { held.resize(to: size) }
                capture?.view.update(media)
                return
            }
        }
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0) as? [[String: Any]] ?? []
        let visible = raw.compactMap(WindowInfo.init)
        func matches(_ w: WindowInfo) -> Bool {
            w.pid == browserPID &&
                w.layer == CGWindowLevelForKey(.floatingWindow) && pipTitles.contains(w.title)
                && w.frame.width > 32 && w.frame.height > 24
        }
        let native = visible.first { matches($0) && source?.id == $0.id } ?? visible.first(where:matches)
        if let native, let previous=source, native.id != previous.id {
            stopCapture()
            source = native
        }
        if source == nil {
            let all = CGWindowListCopyWindowInfo([.optionAll,.excludeDesktopElements],0) as? [[String:Any]] ?? []
            let hidden = all.compactMap(WindowInfo.init).filter(matches)
            guard let candidate = native ?? (hidden.count == 1 ? hidden.first : nil) else {
                message("Edge 영상 창을 찾는 중"); return
            }
            source = candidate
        }
        guard let pip = source, let screen = pip.display else { return }
        let display = screen.quartzBounds
        let active = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let foreignFullscreen = visible.contains {
            $0.pid == active && $0.pid != pip.pid && $0.layer == 0 &&
                $0.frame.contains(display.insetBy(dx:4,dy:4))
        }
        // WindowServer can report a window as on-screen while sliding it past
        // the display edge. Never place the mirror at those transient coordinates.
        let nativeOnDisplay = native.map { display.insetBy(dx:-2,dy:-2).contains($0.frame) } ?? false
        let obscured = visible.prefix(while: { $0.id != pip.id }).contains {
            $0.pid != pip.pid && $0.layer == 0 && $0.frame.contains(display.insetBy(dx:4,dy:4))
        }
        let needsMirror = !nativeOnDisplay || foreignFullscreen || obscured
        if needsMirror { nativeVisibleSince=nil }
        else if nativeVisibleSince==nil { nativeVisibleSince=now }
        let handingBack = presentMirror && now-(nativeVisibleSince ?? now)<0.35
        let canTakeOver = AXIsProcessTrusted() && now >= parkAgainAfter
        presentMirror = needsMirror || handingBack || parked != nil || canTakeOver
        // Prime the first frame while Edge is still on screen. A Space handoff
        // can then display an existing frame without waiting for capture setup.
        if capture == nil && now>=retryAfter { beginCapture(pip,screen:screen) }
        if presentMirror {
            if toolbar.isVisible { toolbar.orderOut(nil) }
            if presentIfReady(), parked == nil, canTakeOver {
                // Keep Edge visible until the compositor has actually presented its replacement.
                parked = ParkedPiP(source: pip)
                if parked == nil { parkAgainAfter = now + 1 }
            }
        } else {
            offDisplaySince=nil
            if panel.isVisible {panel.orderOut(nil)}
            panel.alphaValue = 0
            panel.ignoresMouseEvents = true
            message("Edge에서 PIP 재생 중")
            if let native {
                if parked == nil { source = native }
                updateToolbar(for:native,on:screen,media:media)
            }
        }
        if capture?.view.window != nil { capture?.view.update(media) }
    }
    // Keep the original window's own drag and resize handles accessible. The
    // extra controls sit against its nearest free edge and appear on hover.
    private func updateToolbar(for native:WindowInfo,on screen:NSScreen,media:MediaState) {
        let q=screen.quartzBounds, safe=screen.visibleFrame
        let video=NSRect(x:screen.frame.minX+native.frame.minX-q.minX,
                         y:screen.frame.maxY-(native.frame.maxY-q.minY),
                         width:native.frame.width,height:native.frame.height)
        let width=min(safe.width,max(270,video.width)), height:CGFloat=84
        let x=min(max(video.midX-width/2,safe.minX),safe.maxX-width)
        let below=video.minY-height
        let y=below>=safe.minY ? below:min(video.maxY,safe.maxY-height)
        let frame=NSRect(x:x,y:y,width:width,height:height)
        let mouse=NSEvent.mouseLocation
        guard video.contains(mouse) || toolbarControls.menuOpen ||
            (toolbar.isVisible && frame.insetBy(dx:-2,dy:-3).contains(mouse)) else {
            if toolbar.isVisible { toolbar.orderOut(nil) }
            return
        }
        if toolbar.frame != frame { toolbar.setFrame(frame,display:true) }
        toolbarControls.update(media)
        if !toolbar.isVisible {
            toolbar.orderFrontRegardless()
            toolbarControls.refreshHover()
        }
    }
    func beginCapture(_ pip:WindowInfo, screen:NSScreen, reusing previous:Capture?=nil) {
        guard !captureGuard.isBlockingCapture else { tick(); return }
        let capture=Capture(view:previous?.view ?? VideoView(frame:.zero), hasDisplayedFrame:previous?.hasFrame == true)
        self.capture=capture
        if savedFrame == nil {
            let safe=screen.visibleFrame.insetBy(dx:12,dy:12)
            let ratio=pip.frame.width/max(1,pip.frame.height)
            let width=min(max(270,pip.frame.width),min(safe.width,safe.height*ratio))
            let size=NSSize(width:width,height:width/ratio)
            let quartz=screen.quartzBounds
            let wantedX=screen.frame.minX+pip.frame.minX-quartz.minX
            let wantedY=screen.frame.maxY-(pip.frame.maxY-quartz.minY)
            let x=(wantedX >= safe.minX && wantedX+width<=safe.maxX) ? wantedX:safe.maxX-width
            let y=min(max(wantedY,safe.minY),safe.maxY-size.height)
            panel.setFrame(NSRect(origin:NSPoint(x:x,y:y),size:size),display:false)
            panel.contentAspectRatio=size
            panel.minSize=NSSize(width:270,height:270/ratio)
            savedFrame=panel.frame
        }
        if panel.contentView !== capture.view { panel.contentView=capture.view }
        capture.view.didPlace = { [weak self] in self?.rememberUserFrame() }
        capture.view.command = { [weak self] action, value in self?.link.send(action, value) }
        if let state=link.state {capture.view.update(state)} else {capture.view.showWindowControls()}
        capture.view.layoutSubtreeIfNeeded()
        capture.onFrame={ [weak self] in self?.presentIfReady() }
        capture.onStop={ [weak self] in self?.failed() }
        Task { @MainActor in
            do { try await capture.start(source:pip,protection:self.captureGuard) }
            catch { if self.capture === capture { self.failed() } }
        }
    }
    @discardableResult
    func presentIfReady() -> Bool {
        guard presentMirror, let capture, capture.hasFrame, let requested = savedFrame else { return false }
        let screen = NSScreen.screens.max { lhs, rhs in
            let a = lhs.frame.intersection(requested), b = rhs.frame.intersection(requested)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        }
        guard let screen else { return false }
        let target = fitted(requested, to: screen.visibleFrame)
        savedFrame = target
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        if !panel.isVisible || panel.alphaValue == 0 {
            panel.setFrame(target, display: true)
            panel.alphaValue = 1
            panel.ignoresMouseEvents = false
            panel.orderFrontRegardless()
            capture.view.refreshHover()
        }
        if !isPresented(panel, on: screen) {
            let missingSince = offDisplaySince ?? now
            offDisplaySince = missingSince
            guard now - missingSince >= 0.9, now - lastRepaired >= 1 else {
                message("현재 데스크톱에 PiP 연결 중")
                return false
            }
            lastRepaired = now
            // Reuse the decoded video and controls in a new all-Spaces window.
            // Reordering the stranded window can bind it back to its original Space.
            let previous = panel!
            let replacement = makeVideoPanel(frame: target)
            replacement.contentAspectRatio = previous.contentAspectRatio
            replacement.minSize = previous.minSize
            replacement.contentView = capture.view
            panel = replacement
            replacement.orderFrontRegardless()
            previous.close()
            capture.view.refreshHover()
            guard isPresented(replacement, on: screen) else {
                message("현재 데스크톱에 PiP 연결 중")
                return false
            }
        }
        offDisplaySince = nil
        message(parked?.ready == true ? "모든 데스크톱에 Edge PiP 표시 중" : "현재 데스크톱에 PiP 표시 중")
        return true
    }

    private func isPresented(_ window: NSWindow, on screen: NSScreen) -> Bool {
        let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]]
        guard let row = rows?.first, row[kCGWindowIsOnscreen as String] as? Bool == true,
              let info = WindowInfo(row) else { return false }
        return screen.quartzBounds.insetBy(dx: -4, dy: -4).contains(info.frame)
    }
    private func fitted(_ frame: NSRect, to bounds: NSRect) -> NSRect {
        let factor = min(1, bounds.width / frame.width, bounds.height / frame.height)
        let width = frame.width * factor, height = frame.height * factor
        return NSRect(x:min(max(frame.minX,bounds.minX),bounds.maxX-width),
                      y:min(max(frame.minY,bounds.minY),bounds.maxY-height),width:width,height:height)
    }
    func rememberUserFrame() {
        guard let screen=panel.screen else { return }
        // Size is valid even if a concurrent Space animation offsets the origin.
        if screen.visibleFrame.insetBy(dx:-2,dy:-2).contains(panel.frame) {
            savedFrame=panel.frame
        } else if let previous=savedFrame {
            savedFrame=fitted(NSRect(origin:previous.origin,size:panel.frame.size),to:screen.visibleFrame)
        }
    }
    func windowDidEndLiveResize(_ notification:Notification) { rememberUserFrame() }
    func failed() {
        stopCapture()
        retryAfter = now + 2
        message("영상 창을 다시 연결하는 중")
    }
    func stopCapture() {
        parked?.restore()
        parked = nil
        guard let capture else { return }
        self.capture = nil
        panel.orderOut(nil)
        capture.stop()
        capture.view.video.sampleBufferRenderer.flush(removingDisplayedImage:true, completionHandler:nil)
        panel.contentView = nil
    }
    func reset() {
        toolbar?.orderOut(nil)
        nativeVisibleSince=nil; offDisplaySince=nil
        stopCapture()
        source = nil; savedFrame = nil; presentMirror = false; retryAfter = 0
        message("Edge PIP 대기 중")
    }
    func applicationWillTerminate(_ notification: Notification) {
        settle?.cancel()
        link.stop()
        timer?.invalidate()
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        stopCapture()
    }
}
if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--hold-pip",
   let pid = Int32(CommandLine.arguments[2]), let id = UInt32(CommandLine.arguments[3]) {
    _ = fcntl(STDOUT_FILENO, F_SETNOSIGPIPE, 1)
    exit(ParkedPiP.hold(pid: pid, id: id))
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
#if CAPTURE_RESOLUTION_TEST
Task { @MainActor in
    do { try await testCaptureResolution(); exit(0) }
    catch { print(error); exit(1) }
}
#else
let delegate = AppDelegate()
app.delegate = delegate
#endif
app.run()
