import AppKit
import MetalKit

@main
struct RenderIntegration {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            do {
                let renderer = try PlaneRenderer(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
                // Match the production lifecycle: zero-sized window, then screen-sized resize.
                let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
                window.isOpaque = true
                window.backgroundColor = .black
                window.contentView = renderer.view
                window.orderOut(nil)
                window.alphaValue = 0
                renderer.clear()
                window.setFrame(CGRect(x: 40, y: 40, width: 640, height: 400), display: false)
                renderer.view.framebufferOnly = false
                let space = CGColorSpace(name: CGColorSpace.sRGB)!
                let context = CGContext(data: nil, width: 640, height: 400, bitsPerComponent: 8,
                    bytesPerRow: 640 * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.setFillColor(CGColor(red: 0.85, green: 0.40, blue: 0.20, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
                let image = context.makeImage()!
                var evidence = Evidence()
                renderer.frameProbe = { texture, command in
                    let stride = ((texture.width * 4 + 255) / 256) * 256
                    let buffer = texture.device.makeBuffer(length: stride * texture.height, options: .storageModeShared)!
                    let blit = command.makeBlitCommandEncoder()!
                    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0,y: 0,z: 0),
                              sourceSize: MTLSize(width: texture.width,height: texture.height,depth: 1),
                              to: buffer, destinationOffset: 0, destinationBytesPerRow: stride,
                              destinationBytesPerImage: stride * texture.height)
                    blit.endEncoding()
                    let frameEvidence = evidence
                    command.addCompletedHandler { command in
                        let bytes = buffer.contents().assumingMemoryBound(to: UInt8.self)
                        var samples = [UInt8]()
                        for row in 1...3 {
                            for column in 1...3 {
                                let offset = (texture.height * row / 4) * stride + (texture.width * column / 4) * 4
                                samples += [bytes[offset], bytes[offset + 1], bytes[offset + 2]]
                            }
                        }
                        frameEvidence.record(pixels: samples, error: command.error)
                    }
                }
                var passed = true
                for delta in [0.0, 5, -5, 30, -30] {
                    evidence = Evidence()
                    try renderer.install(image, delta: delta, fps: 60)
                    window.alphaValue = 1
                    window.orderFrontRegardless()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                    window.orderOut(nil)
                    renderer.clear()
                    print("delta=\(delta), view=\(renderer.view.frame), drawable=\(renderer.view.drawableSize)")
                    passed = evidence.report() && passed
                }
                exit(passed ? 0 : 1)
            } catch {
                print("FAIL: \(error)")
                exit(1)
            }
        }
    }
}

final class Evidence: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var colorFrames = 0
    private var firstPixel: [UInt8] = []
    private var errors: [String] = []
    func record(pixels: [UInt8], error: Error?) {
        lock.lock(); defer { lock.unlock() }
        frames += 1
        if firstPixel.isEmpty { firstPixel = Array(pixels.prefix(3)) }
        if pixels.max()! > 40 { colorFrames += 1 }
        if let error { errors.append(error.localizedDescription) }
    }
    func report() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let pass = frames > 0 && colorFrames == frames && errors.isEmpty
        print("\(pass ? "PASS" : "FAIL"): frames=\(frames), nonblack=\(colorFrames), first BGR=\(firstPixel), errors=\(errors)")
        return pass
    }
}
