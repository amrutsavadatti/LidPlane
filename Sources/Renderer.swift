import AppKit
import MetalKit

enum PlaneError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let text): return text }
    }
}

final class PlaneRenderer: NSObject, MTKViewDelegate {
    struct Parameters {
        var delta: Float
        var aspect: Float
        var blur: Float
        var padding: Float = 0
    }
    let view: MTKView
    private let pipeline: MTLRenderPipelineState
    private let queue: MTLCommandQueue
    private var texture: MTLTexture?
    var targetDelta: Double = 0
    var blur: Float = 6
    private var visibleDelta: Double = 0
    private var lastFrame: CFTimeInterval = 0
    private let inFlight = DispatchSemaphore(value: 2)
    #if RENDER_TEST
    var frameProbe: ((MTLTexture, MTLCommandBuffer) -> Void)?
    #endif

    init(frame: CGRect) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw PlaneError.unavailable("Metal is unavailable on this Mac.")
        }
        guard let url = Bundle.main.url(forResource: "Plane", withExtension: "metal") else {
            throw PlaneError.unavailable("The perspective shader is missing.")
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "planeVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "planeFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        self.queue = queue
        view = MTKView(frame: frame, device: device)
        super.init()
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.autoresizingMask = [.width, .height]
        view.delegate = self
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    }

    func install(_ image: CGImage, delta: Double, fps: Int) throws {
        guard let device = view.device else { return }
        texture = try MTKTextureLoader(device: device).newTexture(cgImage: image, options: [
            .SRGB: true, .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.private.rawValue
        ])
        targetDelta = delta
        visibleDelta = delta
        lastFrame = 0
        view.preferredFramesPerSecond = max(30, min(120, fps))
        view.isPaused = false
    }

    func clear() {
        view.isPaused = true
        texture = nil
        lastFrame = 0
        targetDelta = 0
        visibleDelta = 0
        view.releaseDrawables()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard inFlight.wait(timeout: .now()) == .success else { return }
        guard let texture, let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let command = queue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            inFlight.signal()
            return
        }
        let now = CACurrentMediaTime()
        let dt = lastFrame == 0 ? 1.0 / 60.0 : min(now - lastFrame, 0.05)
        lastFrame = now
        visibleDelta += (targetDelta - visibleDelta) * (1 - exp(-dt / 0.025))
        var params = Parameters(delta: Float(visibleDelta),
            aspect: Float(view.drawableSize.width / max(1, view.drawableSize.height)), blur: blur)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<Parameters>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        #if RENDER_TEST
        frameProbe?(drawable.texture, command)
        #endif
        let semaphore = inFlight
        command.addCompletedHandler { _ in semaphore.signal() }
        command.present(drawable)
        command.commit()
    }
}
