import AppKit
import AVFoundation

private final class PlayerSlider: NSSlider {
    var dragging = false
    override func mouseDown(with event: NSEvent) {
        dragging = true
        defer { dragging = false }
        super.mouseDown(with:event)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
private final class Grip: NSView {
    var didPlace: (() -> Void)?
    private var startFrame = NSRect.zero, startPoint = NSPoint.zero
    override func resetCursorRects() { addCursorRect(bounds,cursor:.crosshair) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        startFrame = window?.frame ?? .zero; startPoint = NSEvent.mouseLocation
    }
    override func mouseDragged(with event: NSEvent) {
        guard let w=window else { return }
        let aspect = startFrame.width/max(1,startFrame.height)
        let p = NSEvent.mouseLocation
        let dx=p.x-startPoint.x, dy=(startPoint.y-p.y)*aspect
        let proposed=startFrame.width + (abs(dx) >= abs(dy) ? dx : dy)
        let limit = w.screen?.visibleFrame.size ?? NSSize(width:1600,height:1000)
        let width=min(max(w.minSize.width,proposed), min(limit.width,limit.height*aspect))
        let height=width/aspect
        w.setFrame(NSRect(x:startFrame.minX,y:startFrame.maxY-height,width:width,height:height),display:true)
    }
    override func mouseUp(with event:NSEvent) { didPlace?() }
    override func draw(_ rect:NSRect) {
        NSColor.white.withAlphaComponent(0.72).setStroke()
        let lines=NSBezierPath(); lines.lineWidth=1.5; lines.lineCapStyle = .round
        lines.move(to:NSPoint(x:5,y:6));lines.line(to:NSPoint(x:12,y:13))
        lines.move(to:NSPoint(x:10,y:6));lines.line(to:NSPoint(x:12,y:8));lines.stroke()
    }
}
final class VideoView: NSView {
    let video = AVSampleBufferDisplayLayer()
    private let shade = CAGradientLayer()
    private let hud = NSView()
    private let closeButton = NSButton(), playButton = NSButton(), muteButton = NSButton()
    private let previous = NSButton(), next = NSButton(), backToTab = NSButton(), more = NSButton()
    private let backward = NSButton(), forward = NSButton()
    private let subtitle = NSTextField(wrappingLabelWithString:"")
    var compact = false
    private(set) var menuOpen = false
    private let seek = PlayerSlider(), volume = PlayerSlider()
    private let stamp = NSTextField(labelWithString:"")
    private let grip = Grip()
    var didPlace: (() -> Void)?
    var command: ((String, Double?) -> Void)?
    private var media: MediaState?
    private var tracking: NSTrackingArea?
    private var pointerInside = false
    override init(frame: CGRect) {
        super.init(frame:frame)
        wantsLayer=true; layer?.backgroundColor=NSColor.black.cgColor
        layer?.cornerRadius=11; layer?.masksToBounds=true
        video.videoGravity = .resizeAspect; layer?.addSublayer(video)
        subtitle.textColor = .white
        subtitle.alignment = .center
        subtitle.font = .systemFont(ofSize:15,weight:.semibold)
        subtitle.maximumNumberOfLines = 3
        subtitle.drawsBackground = true
        subtitle.backgroundColor = .black.withAlphaComponent(0.78)
        subtitle.isHidden = true
        addSubview(subtitle)
        addSubview(hud); hud.wantsLayer=true
        shade.colors=[NSColor.black.withAlphaComponent(0.88).cgColor,NSColor.black.withAlphaComponent(0.67).cgColor,NSColor.clear.cgColor]
        shade.locations=[0,0.50,1];shade.startPoint=CGPoint(x:0.5,y:0);shade.endPoint=CGPoint(x:0.5,y:1)
        hud.layer?.addSublayer(shade)
        let buttons: [(NSButton, String, String, Selector)] = [
            (closeButton,"xmark","PIP 닫기",#selector(closePip)),
            (backToTab,"pip.exit","원래 탭으로 돌아가기",#selector(returnToTab)),
            (previous,"backward.end.fill","이전 영상",#selector(previousTrack)),
            (playButton,"play.fill","재생",#selector(playPause)),
            (next,"forward.end.fill","다음 영상",#selector(nextTrack)),
            (backward,"gobackward.10","10초 뒤로",#selector(skipBack)),
            (forward,"goforward.10","10초 앞으로",#selector(skipForward)),
            (muteButton,"speaker.wave.2.fill","음소거",#selector(mute)),
            (more,"ellipsis","재생 옵션",#selector(showOptions))
        ]
        for (b,icon,title,action) in buttons {
            b.isBordered=false; b.imagePosition = .imageOnly; b.setButtonType(.momentaryChange)
            b.contentTintColor = .white; b.bezelStyle = .regularSquare
            b.image=NSImage(systemSymbolName:icon,accessibilityDescription:nil)
            b.toolTip=title;b.setAccessibilityLabel(title);b.target=self;b.action=action
            hud.addSubview(b)
        }
        for button in [closeButton,backToTab,more,backward,forward] {
            button.wantsLayer = true
            button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
            button.layer?.cornerRadius = 12
        }
        for (s,title,action) in [(seek,"재생 위치",#selector(scrub)),(volume,"음량",#selector(adjustVolume))] {
            s.minValue=0;s.maxValue=1;s.isContinuous=true;s.controlSize = .small;s.target=self;s.action=action
            s.setAccessibilityLabel(title);s.toolTip=title;s.trackFillColor = .white;hud.addSubview(s)
        }
        stamp.font = .monospacedDigitSystemFont(ofSize:10,weight:.medium)
        stamp.textColor = .white;hud.addSubview(stamp)
        grip.didPlace = { [weak self] in self?.didPlace?() }
        grip.toolTip="드래그하여 크기 조절";hud.addSubview(grip)
        hud.isHidden=true
    }
    required init?(coder:NSCoder) { nil }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let w=bounds.width, h=bounds.height
        CATransaction.begin();CATransaction.setDisableActions(true)
        if let window { video.contentsScale = window.backingScaleFactor }
        video.frame=bounds;hud.frame=bounds;shade.frame=CGRect(x:0,y:0,width:w,height:min(h,68))
        CATransaction.commit()
        closeButton.frame=CGRect(x:9,y:h-34,width:25,height:25)
        backToTab.frame = CGRect(x:38,y:h-34,width:27,height:25)
        more.frame = CGRect(x:w-36,y:h-34,width:27,height:25)
        backward.frame = CGRect(x:w/2-33,y:h-34,width:30,height:25)
        forward.frame = CGRect(x:w/2+3,y:h-34,width:30,height:25)
        previous.frame = CGRect(x:6,y:3,width:25,height:25)
        playButton.frame = CGRect(x:32,y:3,width:29,height:25)
        next.frame = CGRect(x:62,y:3,width:25,height:25)
        stamp.frame = CGRect(x:91,y:8,width:max(0,w-219),height:15)
        stamp.lineBreakMode = .byTruncatingTail
        grip.isHidden = compact
        subtitle.preferredMaxLayoutWidth = max(80,w-36)
        let subSize = subtitle.fittingSize
        subtitle.frame = CGRect(x:(w-min(w-32,subSize.width+12))/2,y:hud.isHidden ? 10:48,
                                width:min(w-32,subSize.width+12), height:min(h/3,subSize.height+2))
        muteButton.frame=CGRect(x:w-123,y:3,width:27,height:25)
        volume.frame=CGRect(x:w-94,y:6,width:68,height:17)
        seek.frame=CGRect(x:10,y:28,width:w-20,height:17)
        grip.frame=CGRect(x:w-21,y:1,width:20,height:21)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking=NSTrackingArea(rect:.zero,options:[.inVisibleRect,.activeAlways,.mouseEnteredAndExited,.mouseMoved],owner:self,userInfo:nil)
        addTrackingArea(tracking!)
        refreshHover()
    }
    func refreshHover() {
        if compact { hud.isHidden=false; return }
        guard let window,window.isVisible else {hud.isHidden=true;return}
        pointerInside=bounds.contains(convert(window.mouseLocationOutsideOfEventStream,from:nil))
        hud.isHidden = !pointerInside && !menuOpen
        needsLayout = true
    }
    override func mouseEntered(with event:NSEvent) { pointerInside=true;hud.isHidden=false; needsLayout=true }
    override func mouseMoved(with event:NSEvent) { pointerInside=true;hud.isHidden=false; needsLayout=true }
    override func mouseExited(with event:NSEvent) { pointerInside=false;hud.isHidden = !compact && !menuOpen; needsLayout=true }
    override func hitTest(_ point:NSPoint) -> NSView? {
        let hit=super.hitTest(point)
        if hit === hud || hit === stamp || hit === subtitle { return self }
        return hit
    }
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
    override func mouseDown(with event:NSEvent) { if !compact { window?.performDrag(with:event);didPlace?() } }
    private func symbol(_ b:NSButton,_ name:String,_ label:String) {
        guard b.toolTip != label else { return }
        b.image=NSImage(systemSymbolName:name,accessibilityDescription:nil); b.toolTip=label;b.setAccessibilityLabel(label)
    }
    private func clock(_ t:Double) -> String {
        let s=Int(min(1e8,max(0,t)));return s>=3600 ? String(format:"%d:%02d:%02d",s/3600,s/60%60,s%60):String(format:"%d:%02d",s/60,s%60)
    }
    private var playbackControls:[NSView] {
        [previous,playButton,next,backward,forward,muteButton,volume,seek,stamp,more]
    }
    func showWindowControls() {
        media=nil
        playbackControls.forEach { $0.isHidden=true }
        subtitle.isHidden=true
        symbol(closeButton,"xmark","보조 영상 창 닫기")
        symbol(backToTab,"pip.exit","Edge로 돌아가기")
    }
    func update(_ state:MediaState) {
        if media == nil {
            playbackControls.forEach { $0.isHidden=false }
            symbol(closeButton,"xmark","PIP 닫기")
            symbol(backToTab,"pip.exit","원래 탭으로 돌아가기")
        }
        media=state
        previous.isEnabled=state.previous
        next.isEnabled=state.next
        backward.isEnabled=state.range != nil
        forward.isEnabled=state.range != nil
        let text=state.captions && !compact ? state.captionText:""
        if subtitle.stringValue != text {
            subtitle.stringValue=text
            subtitle.isHidden=text.isEmpty
            needsLayout=true
        }
        symbol(playButton,state.paused ? "play.fill":"pause.fill",state.paused ? "재생":"일시정지")
        symbol(muteButton,state.muted || state.volume==0 ? "speaker.slash.fill":"speaker.wave.2.fill",state.muted ? "음소거 해제":"음소거")
        if !volume.dragging { volume.doubleValue=state.muted ? 0:state.volume }
        seek.isEnabled=state.range != nil
        if let span=state.range {
            if !seek.dragging { seek.minValue=span.lowerBound;seek.maxValue=span.upperBound;seek.doubleValue=state.time }
            stamp.stringValue=clock(seek.dragging ? seek.doubleValue:state.time)+" / "+clock(span.upperBound)
        } else { stamp.stringValue=clock(state.time) }
    }
    @objc private func previousTrack() { command?("previous",nil) }
    @objc private func nextTrack() { command?("next",nil) }
    @objc private func returnToTab() { command?("return",nil) }
    @objc private func skipBack() { command?("skip",-10) }
    @objc private func skipForward() { command?("skip",10) }
    @objc private func setRate(_ item:NSMenuItem) { command?("rate",Double(item.tag)/100) }
    @objc private func captions() { command?("captions",nil) }
    @objc private func goLive() { command?("live",nil) }
    @objc private func showOptions() {
        guard let media else { return }
        let menu=NSMenu()
        menu.autoenablesItems=false
        func add(_ title:String,_ action:Selector,enabled:Bool=true) -> NSMenuItem {
            let item=menu.addItem(withTitle:title,action:action,keyEquivalent:"")
            item.target=self
            item.isEnabled=enabled
            return item
        }
        let speed=NSMenuItem(title:"재생 속도",action:nil,keyEquivalent:"")
        let rates=NSMenu()
        for percent in [25,50,75,100,125,150,175,200] {
            let rate=Double(percent)/100
            let item=rates.addItem(withTitle:String(format:"%g×",rate),action:#selector(setRate(_:)),keyEquivalent:"")
            item.tag=percent
            item.target=self
            item.state=abs(media.rate-rate)<0.001 ? .on:.off
        }
        speed.submenu=rates
        menu.addItem(speed)
        add("자막",#selector(captions),enabled:media.hasCaptions).state=media.captions ? .on:.off
        if media.live { _ = add("실시간 위치로 이동",#selector(goLive),enabled:media.range != nil) }
        menuOpen=true
        menu.popUp(positioning:nil,at:NSPoint(x:0,y:more.bounds.minY),in:more)
        menuOpen=false
        refreshHover()
    }
    @objc private func closePip() { command?("close",nil) }
    @objc private func playPause() { command?(media?.paused == true ? "play":"pause",nil) }
    @objc private func mute() { command?("mute",nil) }
    @objc private func scrub() { command?("seek",seek.doubleValue) }
    @objc private func adjustVolume() { command?("volume",volume.doubleValue) }
}
