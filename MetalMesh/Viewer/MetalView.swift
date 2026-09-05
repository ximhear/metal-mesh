import SwiftUI
import MetalKit

/// 마우스/터치 제스처를 카메라 조작 콜백으로 바꾸는 MTKView
final class InteractiveMTKView: MTKView {
    var onRotate: ((Float, Float) -> Void)?       // deltaYaw, deltaPitch (라디안)
    var onZoom: ((Float) -> Void)?                // factor
    var onPan: ((Float, Float) -> Void)?          // 픽셀

    private let rotateSpeed: Float = 0.008

    #if os(macOS)
    override var acceptsFirstResponder: Bool { true }

    override func mouseDragged(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            onPan?(Float(event.deltaX), Float(event.deltaY))
        } else {
            onRotate?(Float(event.deltaX) * rotateSpeed, Float(event.deltaY) * rotateSpeed)
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        onPan?(Float(event.deltaX), Float(event.deltaY))
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = Float(event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.1)
        onZoom?(exp(delta))
    }

    override func magnify(with event: NSEvent) {
        onZoom?(1 + Float(event.magnification))
    }
    #else
    private var lastPinchScale: CGFloat = 1

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        installGestures()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        installGestures()
    }

    private func installGestures() {
        let rotate = UIPanGestureRecognizer(target: self, action: #selector(handleRotate(_:)))
        rotate.maximumNumberOfTouches = 1
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        [rotate, pan, pinch].forEach(addGestureRecognizer)
    }

    @objc private func handleRotate(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        onRotate?(Float(t.x) * rotateSpeed, Float(t.y) * rotateSpeed)
        g.setTranslation(.zero, in: self)
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        onPan?(Float(t.x), Float(t.y))
        g.setTranslation(.zero, in: self)
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        if g.state == .began { lastPinchScale = 1 }
        onZoom?(Float(g.scale / lastPinchScale))
        lastPinchScale = g.scale
    }
    #endif
}

#if os(macOS)
private typealias PlatformViewRepresentable = NSViewRepresentable
#else
private typealias PlatformViewRepresentable = UIViewRepresentable
#endif

/// Renderer를 MTKView에 연결하는 SwiftUI 브리지
struct MetalView: PlatformViewRepresentable {
    let renderer: Renderer
    let settings: RenderSettings

    private func makeView() -> InteractiveMTKView {
        let view = InteractiveMTKView(frame: .zero, device: renderer.device)
        view.colorPixelFormat = Renderer.colorPixelFormat
        view.depthStencilPixelFormat = Renderer.depthPixelFormat
        view.clearColor = Renderer.clearColor
        view.clearDepth = 1
        view.preferredFramesPerSecond = 60
        view.delegate = renderer
        let camera = renderer.camera
        view.onRotate = { dx, dy in camera.rotate(deltaYaw: -dx, deltaPitch: dy) }
        view.onZoom = { factor in camera.zoom(factor: factor) }
        view.onPan = { [weak view] dx, dy in
            let scale = Float(view?.drawableSize.height ?? 1) / Float(max(view?.bounds.height ?? 1, 1))
            camera.pan(deltaX: dx * scale, deltaY: dy * scale, viewportHeight: Float(view?.drawableSize.height ?? 1))
        }
        renderer.settings = settings
        return view
    }

    private func update(_ view: InteractiveMTKView) {
        renderer.settings = settings
    }

    #if os(macOS)
    func makeNSView(context: Context) -> InteractiveMTKView { makeView() }
    func updateNSView(_ nsView: InteractiveMTKView, context: Context) { update(nsView) }
    #else
    func makeUIView(context: Context) -> InteractiveMTKView { makeView() }
    func updateUIView(_ uiView: InteractiveMTKView, context: Context) { update(uiView) }
    #endif
}
