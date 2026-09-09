import AppKit
import MetalKit
import IOSurface

final class SimulatorView: MTKView, MTKViewDelegate {
    var onFocus: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onGeometryChange: (() -> Void)?
    var aspectRatio: CGFloat { (orientation == 3 || orientation == 4) ? surfaceSize.height / surfaceSize.width : surfaceSize.width / surfaceSize.height }
    var session: SXSimulatorSession? { didSet { displayedGeneration = .max; needsDisplay = true } }
    var interactive = false { didSet { if !interactive { cancelInput() } } }
    var framesPerSecond = 5 { didSet { updateTimer() } }
    private var timer: Timer?
    private var displayedGeneration: UInt64 = .max
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var inFlight = false
    private var touchPoint: CGPoint?
    private var keys = Set<UInt32>()
    private var orientation = 1
    private var surfaceSize = CGSize(width: 402, height: 874)
    private var drawRect = CGRect.zero
    private var lastScrollPoint: CGPoint?
    private var scrollEnd: DispatchWorkItem?

    init() {
        let gpu = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: gpu)
        setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel("Simulator screen")
        colorPixelFormat = .bgra8Unorm; framebufferOnly = true
        clearColor = MTLClearColorMake(0.035, 0.035, 0.045, 1)
        isPaused = true; enableSetNeedsDisplay = true; delegate = self
        queue = gpu?.makeCommandQueue()
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 position [[position]]; float2 uv; };
        vertex V vertex_main(uint id [[vertex_id]], constant uint &orientation [[buffer(0)]]) {
          float2 p[4]={float2(-1,-1),float2(1,-1),float2(-1,1),float2(1,1)};
          float2 u[4]={float2(0,1),float2(1,1),float2(0,0),float2(1,0)};
          float2 uv=u[id];
          if(orientation==2)uv=1-uv;
          else if(orientation==3)uv=float2(1-uv.y,uv.x);
          else if(orientation==4)uv=float2(uv.y,1-uv.x);
          return {float4(p[id],0,1),uv};
        }
        fragment float4 fragment_main(V in [[stage_in]], texture2d<float> image [[texture(0)]]) {
          constexpr sampler s(filter::linear, address::clamp_to_edge);
          return image.sample(s,in.uv);
        }
        """
        do {
            if let gpu {
                let library = try gpu.makeLibrary(source: source, options: nil)
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "vertex_main")
                descriptor.fragmentFunction = library.makeFunction(name: "fragment_main")
                descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
                pipeline = try gpu.makeRenderPipelineState(descriptor: descriptor)
            }
        } catch { DispatchQueue.main.async { [weak self] in self?.onFailure?(error.localizedDescription) } }
        for notification in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged), name: notification, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(cancelInput), name: NSApplication.didResignActiveNotification, object: nil)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { timer?.invalidate(); NotificationCenter.default.removeObserver(self) }
    override var acceptsFirstResponder: Bool { interactive }
    override func resignFirstResponder() -> Bool { cancelInput(); return super.resignFirstResponder() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateTimer() }
    override func viewDidHide() { super.viewDidHide(); timer?.invalidate(); timer = nil; cancelInput() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateTimer() }
    @objc private func visibilityChanged() { updateTimer() }
    func updateTimer() {
        timer?.invalidate(); timer = nil
        guard let window, window.isVisible && !window.isMiniaturized, !isHiddenOrHasHiddenAncestor else { return }
        let timer = Timer(timeInterval: 1.0 / Double(framesPerSecond), repeats: true) { [weak self] _ in
            guard let self else { return }
            guard let window = self.window, window.isVisible && !window.isMiniaturized, !self.visibleRect.isEmpty else { return }
            if let error = self.session?.inputError { self.interactive = false; self.onFailure?(error) }
            if self.session?.generation != self.displayedGeneration { self.needsDisplay = true }
        }
        timer.tolerance = 0.002; RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { displayedGeneration = .max; needsDisplay = true }
    func draw(in view: MTKView) {
        guard !inFlight, let session, let surface = session.copySurface(), let gpu = device,
              let queue, let pipeline, let pass = currentRenderPassDescriptor, let drawable = currentDrawable else { return }
        let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
        guard width > 0, height > 0 else { return }
        let changed = orientation != session.orientation || surfaceSize != CGSize(width: width, height: height)
        orientation = session.orientation
        surfaceSize = CGSize(width: width, height: height)
        if changed { DispatchQueue.main.async { [weak self] in self?.onGeometryChange?() } }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead; descriptor.storageMode = .shared
        guard let texture = gpu.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0),
              let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        let renderSize = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        let landscape = orientation == 3 || orientation == 4
        let size = landscape ? CGSize(width: height, height: width) : surfaceSize
        let scale = min(renderSize.width / size.width, renderSize.height / size.height)
        let w = size.width * scale, h = size.height * scale
        let x = (renderSize.width - w) / 2, y = (renderSize.height - h) / 2
        drawRect = CGRect(x: x / renderSize.width * bounds.width, y: y / renderSize.height * bounds.height, width: w / renderSize.width * bounds.width, height: h / renderSize.height * bounds.height)
        encoder.setViewport(MTLViewport(originX: x, originY: y, width: w, height: h, znear: 0, zfar: 1))
        encoder.setRenderPipelineState(pipeline)
        var rotation = UInt32(orientation); encoder.setVertexBytes(&rotation, length: MemoryLayout<UInt32>.size, index: 0)
        encoder.setFragmentTexture(texture, index: 0); encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4); encoder.endEncoding()
        displayedGeneration = session.generation; inFlight = true
        command.addCompletedHandler { [weak self] _ in
            _ = surface // Retain the shared surface until the GPU finishes.
            DispatchQueue.main.async { self?.inFlight = false }
        }
        command.present(drawable); command.commit()
    }
    private func point(_ event: NSEvent, clamp: Bool = false) -> CGPoint? {
        let p = convert(event.locationInWindow, from: nil)
        guard drawRect.width > 0, drawRect.height > 0, clamp || drawRect.contains(p) else { return nil }
        let x = max(0, min(1, (p.x - drawRect.minX) / drawRect.width))
        let y = max(0, min(1, 1 - (p.y - drawRect.minY) / drawRect.height))
        switch orientation {
        case 2: return CGPoint(x: 1-x, y: 1-y)
        case 3: return CGPoint(x: 1-y, y: x)
        case 4: return CGPoint(x: y, y: 1-x)
        default: return CGPoint(x: x, y: y)
        }
    }
    override func mouseDown(with event: NSEvent) {
        onFocus?()
        guard interactive, let p = point(event) else { return }
        window?.makeFirstResponder(self); touchPoint = p; session?.touchX(p.x, y: p.y, phase: 0)
    }
    override func mouseDragged(with event: NSEvent) { guard interactive, touchPoint != nil, let p = point(event, clamp: true) else { return }; touchPoint = p; session?.touchX(p.x, y: p.y, phase: 1) }
    override func mouseUp(with event: NSEvent) { if let p = touchPoint { session?.touchX(p.x, y: p.y, phase: 2); touchPoint = nil } }
    override func scrollWheel(with event: NSEvent) {
        guard interactive, let p = point(event) else { return }
        onFocus?(); window?.makeFirstResponder(self)
        scrollEnd?.cancel()
        if lastScrollPoint == nil { lastScrollPoint = p; session?.touchX(p.x, y: p.y, phase: 0) }
        var next = lastScrollPoint!
        next.y = max(0.03, min(0.97, next.y + event.scrollingDeltaY / 900))
        next.x = max(0.03, min(0.97, next.x - event.scrollingDeltaX / 900))
        session?.touchX(next.x, y: next.y, phase: 1); lastScrollPoint = next
        let work = DispatchWorkItem { [weak self] in guard let self, let p = self.lastScrollPoint else { return }; self.session?.touchX(p.x, y: p.y, phase: 2); self.lastScrollPoint = nil }
        scrollEnd = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
    // Physical macOS key codes mapped to USB HID keyboard usages.
    static let keyMap: [UInt16: UInt32] = [0:4,1:22,2:7,3:9,4:11,5:10,6:29,7:27,8:6,9:25,11:5,12:20,13:26,14:8,15:21,16:28,17:23,18:30,19:31,20:32,21:33,22:35,23:34,24:46,25:38,26:36,27:45,28:37,29:39,30:48,31:18,32:24,33:47,34:12,35:19,36:40,37:15,38:13,39:52,40:14,41:51,42:49,43:54,44:56,45:17,46:16,47:55,48:43,49:44,50:53,51:42,53:41,117:76,123:80,124:79,125:81,126:82]
    override func keyDown(with event: NSEvent) { guard interactive, let usage = Self.keyMap[event.keyCode] else { return }; keys.insert(usage); session?.keyUsage(usage, down: true) }
    override func keyUp(with event: NSEvent) { guard let usage = Self.keyMap[event.keyCode] else { return }; keys.remove(usage); session?.keyUsage(usage, down: false) }
    override func flagsChanged(with event: NSEvent) {
        guard interactive else { return }
        for (flag, code) in [(NSEvent.ModifierFlags.shift, UInt32(225)), (.control,224),(.option,226),(.command,227)] {
            let down = event.modifierFlags.contains(flag)
            if down != keys.contains(code) { session?.keyUsage(code, down: down); if down { keys.insert(code) } else { keys.remove(code) } }
        }
    }
    @objc func cancelInput() {
        scrollEnd?.cancel()
        if let p = touchPoint ?? lastScrollPoint { session?.touchX(p.x, y: p.y, phase: 2) }
        touchPoint = nil; lastScrollPoint = nil
        for code in keys { session?.keyUsage(code, down: false) }; keys.removeAll()
    }
}
